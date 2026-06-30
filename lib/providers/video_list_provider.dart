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

  /// 后台缩略图生成队列
  final List<VideoItem> _missingThumbnails = [];
  bool _isBackgroundGenRunning = false;
  int _missingThumbnailTotal = 0;
  int _missingThumbnailProcessed = 0;

  // --- 公开 getters ---

  List<VideoItem> get videos => _videos;
  Map<String, String> get processingState => _processingState;

  /// 是否正在后台生成缩略图
  bool get isGeneratingThumbnails => _isBackgroundGenRunning;

  /// 后台生成进度：当前处理数
  int get missingThumbnailProcessed => _missingThumbnailProcessed;

  /// 后台生成进度：总数
  int get missingThumbnailTotal => _missingThumbnailTotal;

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
        final thumbResult = await ThumbnailService.generateAndEncryptThumbnail(file.path!, thumbPath);
        if (thumbResult == null) {
          debugPrint('[SnPlayer] VideoListProvider.pickAndEncryptVideos: thumbnail generation failed for ${file.path}');
        }
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
      // 同步清理磁盘缓存缩略图
      if (video.thumbCachePath != null) {
        try {
          await File(video.thumbCachePath!).delete();
        } catch (_) {
          // 文件可能已被清理，忽略
        }
      }
      video.thumbCachePath = null;
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

  /// 分批加载缩略图到磁盘缓存（不阻塞 UI）
  Future<void> loadThumbnails() async {
    _thumbnailToken.reset();

    final cacheDir = await PathProviderService.getThumbCacheDir();
    final videosWithoutCache = _videos.where((v) => v.thumbCachePath == null).toList();

    for (int i = 0; i < videosWithoutCache.length; i += thumbnailBatchSize) {
      if (_thumbnailToken.isCancelled) { break; }

      final end = (i + thumbnailBatchSize).clamp(0, videosWithoutCache.length);
      final batch = videosWithoutCache.sublist(i, end);

      await Future.wait(
        batch.map((video) async {
          try {
            video.thumbCachePath = await Future.any([
              ThumbnailService.decryptThumbnailToCache(video.id, video.thumbPath, cacheDir),
              Future.delayed(const Duration(seconds: 5), () => null),
            ]);

            // 收集缺失 .tenc 的视频，稍后后台逐条生成
            if (video.thumbCachePath == null && !await File(video.thumbPath).exists()) {
              _missingThumbnails.add(video);
            }
          } catch (e) {
            debugPrint('[SnPlayer] VideoListProvider.loadThumbnails: $e');
          }
        }),
      );

      notifyListeners();

      // 让出主线程给 UI 渲染
      await Future.delayed(Duration.zero);
    }

    // 启动后台队列逐条生成缺失缩略图（不阻塞 UI）
    if (_missingThumbnails.isNotEmpty) {
      debugPrint('[SnPlayer] VideoListProvider: 发现 ${_missingThumbnails.length} 个视频缺少缩略图，启动后台生成队列');
      unawaited(_startBackgroundGeneration(cacheDir));
    } else {
      debugPrint('[SnPlayer] VideoListProvider: 所有视频缩略图已就绪');
    }
  }

  /// 取消缩略图加载（含后台生成队列）
  void cancelThumbnailLoading() {
    _thumbnailToken.cancel();
    _missingThumbnails.clear();
  }

  /// 按可见范围加载缩略图（可视区懒加载）
  ///
  /// 仅加载 [startIndex] 到 [endIndex] 范围内尚未缓存的视频缩略图，
  /// Flutter 内置 ImageCache 负责离屏缩略图的 LRU 淘汰
  Future<void> loadVisibleThumbnails(int startIndex, int endIndex) async {
    final cacheDir = await PathProviderService.getThumbCacheDir();
    final range = endIndex.clamp(0, _videos.length);

    for (int i = startIndex; i < range; i++) {
      if (_thumbnailToken.isCancelled) { break; }
      final video = _videos[i];
      if (video.thumbCachePath != null) { continue; }

      try {
        video.thumbCachePath = await Future.any([
          ThumbnailService.decryptThumbnailToCache(video.id, video.thumbPath, cacheDir),
          Future.delayed(const Duration(seconds: 5), () => null),
        ]);
      } catch (e) {
        debugPrint('[SnPlayer] VideoListProvider.loadVisibleThumbnails: $e');
      }

      if (i % thumbnailBatchSize == 0) {
        notifyListeners();
        await Future.delayed(Duration.zero);
      }
    }

    notifyListeners();
  }

  /// 后台生成缺失的缩略图（不阻塞 UI）
  ///
  /// 在 [loadThumbnails] 完成后自动调用。
  /// 逐条处理队列，每条完成后立即通知 UI 刷新。
  Future<void> _startBackgroundGeneration(String cacheDir) async {
    if (_isBackgroundGenRunning) { return; }
    _isBackgroundGenRunning = true;
    _missingThumbnailTotal = _missingThumbnails.length;
    _missingThumbnailProcessed = 0;
    debugPrint('[SnPlayer] VideoListProvider: 后台生成 $_missingThumbnailTotal 张缺失缩略图');
    notifyListeners();

    final queue = List<VideoItem>.from(_missingThumbnails);
    int completedCount = 0;

    try {
      for (final video in queue) {
        if (_thumbnailToken.isCancelled) { break; }

        final shortId = video.id.length > 8 ? video.id.substring(0, 8) : video.id;
        debugPrint('[SnPlayer] VideoListProvider: 后台缩略图 [$shortId]');

        try {
          video.thumbCachePath = await ThumbnailService.generateThumbnailFromEncryptedPartial(
            video.encPath, video.thumbPath, cacheDir, video.id,
          );
          if (video.thumbCachePath != null) {
            debugPrint('[SnPlayer] VideoListProvider: 后台缩略图 [$shortId] 生成成功');
          } else {
            debugPrint('[SnPlayer] VideoListProvider: 后台缩略图 [$shortId] 生成失败（返回null）');
          }
        } catch (e) {
          debugPrint('[SnPlayer] VideoListProvider: 后台缩略图 [$shortId] 异常: $e');
        }

        completedCount++;
        _missingThumbnailProcessed = completedCount;
        notifyListeners();

        // 让出主线程给 UI 刷新
        await Future.delayed(const Duration(milliseconds: 50));
      }
    } finally {
      _missingThumbnails.clear();
      _isBackgroundGenRunning = false;
      _missingThumbnailTotal = 0;
      _missingThumbnailProcessed = 0;
      debugPrint('[SnPlayer] VideoListProvider: 后台缩略图生成队列完成（共 $completedCount 张）');
      notifyListeners();
    }
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

  /// 清理过期的磁盘缓存缩略图
  Future<int> cleanupExpiredThumbnails() async {
    final cacheDir = await PathProviderService.getThumbCacheDir();
    return await ThumbnailService.cleanupExpiredCache(cacheDir);
  }

  /// 获取同一文件夹下的相邻视频
  ///
  /// [currentEncPath] 当前视频的加密路径。
  /// [folderName] 所属文件夹名，null 表示根目录。
  /// 返回 [prev, next]，不存在的方向为 null。
  ({VideoItem? prev, VideoItem? next}) getAdjacentVideos(
    String currentEncPath, {
    String? folderName,
  }) {
    final folderVideos = getVideosInFolder(folderName);
    final currentIndex = folderVideos.indexWhere(
      (v) => v.encPath == currentEncPath,
    );

    if (currentIndex == -1) {
      return (prev: null, next: null);
    }

    return (
      prev: currentIndex > 0 ? folderVideos[currentIndex - 1] : null,
      next: currentIndex < folderVideos.length - 1
          ? folderVideos[currentIndex + 1]
          : null,
    );
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
