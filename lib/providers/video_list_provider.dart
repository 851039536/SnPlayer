import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import '../models/video_item.dart';
import '../config/crypto.dart';
import '../services/crypto_service.dart';
import '../services/storage_service.dart';
import '../services/safe_delete_helper.dart';
import '../services/thumbnail_service.dart';
import '../services/path_provider_service.dart';
import '../utils/cancellable.dart';

/// 视频列表状态管理
///
/// 管理视频列表的 CRUD、缩略图分批加载、存储统计
class VideoListProvider extends ChangeNotifier {
  List<VideoItem> _videos = [];
  final Map<String, String> _processingState = {}; // id -> status text
  final CancellationToken _thumbnailToken = CancellationToken();

  List<VideoItem> get videos => _videos;
  Map<String, String> get processingState => _processingState;

  /// 加载视频列表并扫描文件
  Future<void> loadVideos() async {
    await StorageService.initDirectories();
    _videos = await StorageService.scanEncryptedVideos();
    notifyListeners();
  }

  /// 获取指定文件夹下的视频
  List<VideoItem> getVideosInFolder(String? folderName) {
    if (folderName == null) {
      return _videos;
    }
    return _videos.where((v) => v.folderName == folderName).toList();
  }

  /// 选择并加密视频
  Future<void> pickAndEncryptVideos({String? targetFolder}) async {
    final result = await FilePicker.pickFiles(
      type: FileType.video,
      allowMultiple: true,
    );

    if (result == null || result.files.isEmpty) { return; }

    for (final file in result.files) {
      if (file.path == null) { continue; }

      final videoId = p.basename(file.path!);
      _setProcessingState(videoId, '正在加密...');

      try {
        // 生成加密文件名
        final encryptedName = StorageService.generateEncryptedFileName(
          p.basename(file.path!),
        );

        final folderName = targetFolder ?? '';
        final encPath = await StorageService.buildEncPath(folderName, encryptedName);
        final thumbPath = StorageService.buildThumbPath(encPath);

        // 加密视频文件
        await CryptoService.encryptFile(
          file.path!,
          encPath,
          onProgress: (progress) {
            _setProcessingState(videoId, '加密中 ${(progress * 100).toStringAsFixed(0)}%');
          },
        );

        // 生成加密缩略图
        await ThumbnailService.generateAndEncryptThumbnail(file.path!, thumbPath);
      } catch (e) {
        debugPrint('[SnPlayer] VideoListProvider.pickAndEncryptVideos: $e');
        _setProcessingState(videoId, '加密失败');
        await Future.delayed(const Duration(seconds: 3));
      } finally {
        _removeProcessingState(videoId);
      }
    }

    // 循环结束后只扫描一次
    await loadVideos();
  }

  /// 解密视频到导出目录
  Future<bool> decryptAndExport(VideoItem video) async {
    final videoId = video.id;
    _setProcessingState(videoId, '正在解密...');

    try {
      final unlockDir = await PathProviderService.getUnlockVideoDir();
      await Directory(unlockDir).create(recursive: true);

      final exportPath = p.join(unlockDir, '${video.displayName}.mp4');

      await CryptoService.decryptFile(
        video.encPath,
        exportPath,
        onProgress: (progress) {
          _setProcessingState(videoId, '解密中 ${(progress * 100).toStringAsFixed(0)}%');
        },
      );

      return true;
    } catch (e) {
      debugPrint('[SnPlayer] VideoListProvider.decryptAndExport: $e');
      _setProcessingState(videoId, '解密失败');
      await Future.delayed(const Duration(seconds: 3));
      return false;
    } finally {
      _removeProcessingState(videoId);
    }
  }

  /// 删除视频
  Future<bool> deleteVideo(VideoItem video) async {
    final success = await SafeDeleteHelper.safeDeleteVideo(video);
    if (success) {
      _videos.removeWhere((v) => v.id == video.id);
      notifyListeners();
    }
    return success;
  }

  /// 重命名视频
  Future<bool> renameVideo(VideoItem video, String newName) async {
    final success = await StorageService.renameVideo(video, newName);
    if (success) {
      // 直接更新现有对象，避免全量重扫
      video.displayName = newName;
      notifyListeners();
    }
    return success;
  }

  /// 移动视频到文件夹
  Future<bool> moveVideo(VideoItem video, String? targetFolder) async {
    final success = await StorageService.moveVideo(video, targetFolder);
    if (success) {
      video.folderName = targetFolder;
      notifyListeners();
    }
    return success;
  }

  /// 分批加载缩略图（不阻塞 UI）
  Future<void> loadThumbnails() async {
    _thumbnailToken.reset();

    final videosWithoutCover = _videos.where((v) => v.coverData == null).toList();

    for (int i = 0; i < videosWithoutCover.length; i += thumbnailBatchSize) {
      if (_thumbnailToken.isCancelled) { break; }

      final end = (i + thumbnailBatchSize).clamp(0, videosWithoutCover.length);
      final batch = videosWithoutCover.sublist(i, end);

      await Future.wait(
        batch.map((video) async {
          try {
            // 单个缩略图加载添加 10 秒超时，防止磁盘 I/O 阻塞
            video.coverData = await Future.any([
              ThumbnailService.loadThumbnail(video.thumbPath),
              Future.delayed(const Duration(seconds: 10), () => null),
            ]);
          } catch (e) {
            debugPrint('[SnPlayer] VideoListProvider.loadThumbnails: $e');
            video.coverData = null;
          }
        }),
      );

      notifyListeners();

      // 让出主线程给 UI 渲染
      await Future.delayed(Duration.zero);
    }
  }

  /// 取消缩略图加载
  void cancelThumbnailLoading() {
    _thumbnailToken.cancel();
  }

  // --- 存储统计 ---

  /// 获取存储统计
  Future<Map<String, dynamic>> getStorageStats() async {
    return await StorageService.getStorageStats();
  }

  /// 清理缓存文件
  Future<int> cleanupCache() async {
    final cacheDir = await PathProviderService.getCacheDir();
    return await SafeDeleteHelper.cleanupCacheFiles(
      cacheDir,
      const Duration(minutes: 2),
    );
  }

  /// 清理孤儿缩略图
  Future<int> cleanOrphanThumbnails() async {
    return await StorageService.cleanOrphanThumbnails();
  }

  // --- 内部方法 ---

  void _setProcessingState(String videoId, String state) {
    _processingState[videoId] = state;
    notifyListeners();
  }

  void _removeProcessingState(String videoId) {
    _processingState.remove(videoId);
    notifyListeners();
  }
}
