// lib/providers/video_list_provider.dart — 视频列表状态管理（CRUD/批量加密/解密导出/缩略图懒加载/存储统计）

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import '../models/video_item.dart';
import '../config/crypto.dart';
import '../services/crypto_service.dart';
import '../services/playback_cache_manager.dart';
import '../services/storage_service.dart';
import '../services/safe_delete_helper.dart';
import '../services/thumbnail_service.dart';
import '../services/path_provider_service.dart';
import '../utils/cancellable.dart';
import '../widgets/crypto_progress_dialog.dart';

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

  /// 正在解密中的缩略图 id 集合（可见区加载与后台队列共享）
  ///
  /// 滚动会高频重复请求同一区间，无此去重会导致同一视频被并发重复解密。
  final Set<String> _thumbnailInFlight = {};

  /// 筛选结果缓存：folderName -> 该文件夹下的视频列表
  ///
  /// 避免每次 build 都 `.toList()` 产生新列表实例（会让 SliverGrid 每帧重建）。
  /// key 用 [String?] 表示根目录（null）。
  final Map<String?, List<VideoItem>> _folderCache = {};

  /// 缓存版本号：[_videos] 或视频的 folderName 变化时自增，用于让 [_folderCache] 失效
  int _folderCacheVersion = 0;
  int _folderCacheBuiltVersion = -1;

  // --- 公开 getters ---

  List<VideoItem> get videos => _videos;
  Map<String, String> get processingState => _processingState;

  /// 是否正在后台生成缩略图
  bool get isGeneratingThumbnails => _isBackgroundGenRunning;

  /// 后台生成进度：当前处理数
  int get missingThumbnailProcessed => _missingThumbnailProcessed;

  /// 后台生成进度：总数
  int get missingThumbnailTotal => _missingThumbnailTotal;

  /// 启动缓存清理是否已触发（仅首次 loadVideos 时执行一次）
  bool _startupCleanupDone = false;

  /// 加载视频列表并扫描文件
  Future<void> loadVideos() async {
    await StorageService.initDirectories();

    // 启动时后台清理播放缓存（过期 3 天 + LRU 超量 500MB），不阻塞首屏
    if (!_startupCleanupDone) {
      _startupCleanupDone = true;
      unawaited(_runStartupCacheCleanup());
    }

    _videos = await StorageService.scanEncryptedVideos();
    _invalidateFolderCache();
    notifyListeners();
  }

  /// 启动时的播放缓存清理（失败不影响主流程）
  ///
  /// 延迟 5 秒执行，避免与首屏扫描/缩略图批量加载竞争 IO
  Future<void> _runStartupCacheCleanup() async {
    try {
      await Future.delayed(const Duration(seconds: 5));
      final cacheDir = await PathProviderService.getCacheDir();
      await PlaybackCacheManager.performCleanup(cacheDir);
    } catch (e) {
      debugPrint('[SnPlayer] VideoListProvider: 启动缓存清理失败: $e');
    }
  }

  /// 获取指定文件夹下的视频
  ///
  /// 结果按文件夹缓存，仅在 [_videos] 或文件夹归属变化后重建，
  /// 保证同一筛选条件下返回**同一列表实例**（SliverGrid 据此避免无谓重建）。
  List<VideoItem> getVideosInFolder(String? folderName) {
    if (_folderCacheBuiltVersion != _folderCacheVersion) {
      _folderCache.clear();
      _folderCacheBuiltVersion = _folderCacheVersion;
    }

    // 根目录（null）直接复用原列表，避免无谓复制
    if (folderName == null) {
      return _videos;
    }

    final cached = _folderCache[folderName];
    if (cached != null) {
      return cached;
    }

    final filtered = _videos.where((v) => v.folderName == folderName).toList();
    _folderCache[folderName] = filtered;
    return filtered;
  }

  /// 让筛选缓存失效（列表内容或视频归属变化后必须调用）
  void _invalidateFolderCache() {
    _folderCacheVersion++;
  }

  /// 直接注入视频列表（仅供单元测试使用）
  @visibleForTesting
  void debugSetVideos(List<VideoItem> videos) {
    _videos = videos;
    _invalidateFolderCache();
  }

  /// 选择要加密的视频文件，返回路径列表（空列表 = 用户取消）
  ///
  /// 使用 FileType.custom 而非 FileType.video，
  /// 在拥有 MANAGE_EXTERNAL_STORAGE 时能直接浏览文件系统（完全访问），
  /// 而非走 SAF 媒体库选择器（安全访问）。
  Future<List<String>> pickVideoFiles() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const [
        'mp4', 'mkv', 'avi', 'mov', 'flv',
        'wmv', 'webm', 'm4v', '3gp', 'ts',
      ],
      allowMultiple: true,
    );

    if (result == null || result.files.isEmpty) { return const []; }
    return [
      for (final file in result.files)
        if (file.path != null) file.path!,
    ];
  }

  /// 批量加密视频文件，返回成功/失败计数
  ///
  /// 进度通过 [controller] 上报给模态进度对话框。
  /// 加密期间视频尚未出现在列表中，不写 processingState（卡片徽章无处渲染）。
  Future<({int success, int failed})> encryptVideos(
    List<String> paths, {
    String? targetFolder,
    CryptoProgressController? controller,
  }) async {
    int success = 0;
    int failed = 0;

    for (int i = 0; i < paths.length; i++) {
      final path = paths[i];
      final baseName = p.basename(path);
      controller?.nextFile(
        fileName: baseName, current: i + 1, total: paths.length,
      );

      try {
        // 生成加密文件名
        final encryptedName = StorageService.generateEncryptedFileName(baseName);

        final folderName = targetFolder ?? '';
        final encPath = await StorageService.buildEncPath(folderName, encryptedName);
        final thumbPath = StorageService.buildThumbPath(encPath);

        // 加密视频文件
        await CryptoService.encryptFile(
          path,
          encPath,
          onProgress: (progress) => controller?.updateProgress(progress),
        );

        // 生成加密缩略图
        final thumbResult = await ThumbnailService.generateAndEncryptThumbnail(path, thumbPath);
        if (thumbResult == null) {
          debugPrint('[SnPlayer] VideoListProvider.encryptVideos: thumbnail generation failed for $path');
        }
        success++;
      } catch (e) {
        debugPrint('[SnPlayer] VideoListProvider.encryptVideos: $e');
        failed++;
      }
    }

    // 循环结束后只扫描一次
    await loadVideos();
    // 立即加载缩略图，让新添加的视频可见时就有封面
    unawaited(loadThumbnails());

    return (success: success, failed: failed);
  }

  /// 解密视频到导出目录
  ///
  /// 进度双通道：卡片徽章（processingState 文本）+ 模态进度对话框（[controller]）
  Future<bool> decryptAndExport(
    VideoItem video, {
    CryptoProgressController? controller,
  }) async {
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
          controller?.updateProgress(progress);
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
      _thumbnailInFlight.remove(video.id);
      _videos.removeWhere((v) => v.id == video.id);
      _invalidateFolderCache();
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
      // 归属变化影响筛选结果
      _invalidateFolderCache();
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
            await _decryptThumbnailDeduped(video, cacheDir);

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

  /// 解密单个视频的缩略图到磁盘缓存（带去重与超时）
  ///
  /// 同一视频并发调用时只有第一个会真正解密，其余直接复用其结果。
  /// 返回解密后的缓存路径（失败返回 null）。
  Future<String?> _decryptThumbnailDeduped(
    VideoItem video,
    String cacheDir,
  ) {
    // 已就绪：直接返回
    if (video.thumbCachePath != null) {
      return Future.value(video.thumbCachePath);
    }
    // 已在解密中：跳过，避免重复解密同一视频
    if (!_thumbnailInFlight.add(video.id)) {
      return Future.value(null);
    }

    return Future.any([
      ThumbnailService.decryptThumbnailToCache(video.id, video.thumbPath, cacheDir),
      Future.delayed(const Duration(seconds: 5), () => null),
    ]).then((path) {
      video.thumbCachePath = path;
      return path;
    }).whenComplete(() {
      _thumbnailInFlight.remove(video.id);
    });
  }

  /// 按可见范围加载缩略图（可视区懒加载）
  ///
  /// [visibleVideos] 必须是网格**实际渲染**的那份列表（即
  /// [getVideosInFolder] 的结果），不能传入全量列表：
  /// 选中文件夹时全量列表与筛选列表索引不一致，会导致加载错位。
  /// Flutter 内置 ImageCache 负责离屏缩略图的 LRU 淘汰。
  Future<void> loadVisibleThumbnails(
    List<VideoItem> visibleVideos,
    int startIndex,
    int endIndex,
  ) async {
    final cacheDir = await PathProviderService.getThumbCacheDir();
    final start = startIndex.clamp(0, visibleVideos.length);
    final end = endIndex.clamp(0, visibleVideos.length);
    bool changed = false;

    for (int i = start; i < end; i++) {
      if (_thumbnailToken.isCancelled) { break; }
      final video = visibleVideos[i];
      if (video.thumbCachePath != null) { continue; }

      try {
        final path = await _decryptThumbnailDeduped(video, cacheDir);
        if (path != null) { changed = true; }
      } catch (e) {
        debugPrint('[SnPlayer] VideoListProvider.loadVisibleThumbnails: $e');
      }

      if (i % thumbnailBatchSize == 0) {
        if (changed) {
          notifyListeners();
          changed = false;
        }
        await Future.delayed(Duration.zero);
      }
    }

    if (changed) {
      notifyListeners();
    }
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

        // 可见区加载可能已就绪或正在解密同一视频：跳过，避免重复重解密
        if (video.thumbCachePath != null || !_thumbnailInFlight.add(video.id)) {
          completedCount++;
          _missingThumbnailProcessed = completedCount;
          continue;
        }

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
        } finally {
          _thumbnailInFlight.remove(video.id);
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

  /// 清空全部缓存（播放缓存 + 缩略图磁盘缓存）
  ///
  /// 用户主动点击"清理缓存"时调用，删除 play_cache/ 和 thumb_cache/ 下的所有文件。
  /// 同时清空视频对象的 thumbCachePath 引用，触发缩略图重新加载。
  /// 返回删除的文件总数。
  Future<int> clearAllCache() async {
    int deleted = 0;

    // 1. 清空播放缓存（play_cache/）
    final cacheDir = await PathProviderService.getCacheDir();
    deleted += await _deleteAllFilesInDir(cacheDir);

    // 2. 清空缩略图磁盘缓存（thumb_cache/）
    final thumbCacheDir = await PathProviderService.getThumbCacheDir();
    deleted += await _deleteAllFilesInDir(thumbCacheDir);

    // 3. 清空视频对象的 thumbCachePath 引用
    for (final video in _videos) {
      video.thumbCachePath = null;
    }
    _thumbnailInFlight.clear();

    // 4. 清除 Flutter 内存 ImageCache：缩略图缓存文件名固定（按 videoId），
    // 删除磁盘文件后若不清内存缓存，重新生成同名文件时 Image.file 会命中
    // 旧的解码图像，UI 显示过期/已删除的缩略图
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();

    if (deleted > 0) {
      debugPrint('[SnPlayer] VideoListProvider.clearAllCache: 清空 $deleted 个缓存文件');
      notifyListeners();
    }

    return deleted;
  }

  /// 删除目录下所有文件（非递归，仅顶层文件）
  ///
  /// 跳过近 2 分钟内修改过的文件：正在写入的 .decrypting.tmp 被 unlink
  /// 会导致后续 rename 失败、正在写的 .chunk_N.tmp 被删会使并行解密
  /// 合并阶段报错（在途写入护栏）
  Future<int> _deleteAllFilesInDir(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      return 0;
    }

    const inFlightGuard = Duration(minutes: 2);
    final now = DateTime.now();
    int count = 0;
    await for (final entity in dir.list()) {
      if (entity is! File) {
        continue;
      }
      try {
        final stat = await entity.stat();
        if (now.difference(stat.modified) < inFlightGuard) {
          continue;
        }
        if (await SafeDeleteHelper.fastDelete(entity.path)) {
          count++;
        }
      } catch (e) {
        // 单文件异常（如被并发删除）不中断整个清理
        debugPrint('[SnPlayer] VideoListProvider._deleteAllFilesInDir: $e');
      }
    }
    return count;
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
