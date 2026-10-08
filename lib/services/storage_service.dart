// lib/services/storage_service.dart — 文件存储管理（目录/扫描/命名/移动重命名/文件夹元数据/存储统计）

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/video_item.dart';
import '../models/video_folder.dart';
import '../config/crypto.dart';
import 'path_provider_service.dart';

/// 删除文件夹的结果
///
/// 区分"非空被拒"与"元数据保存失败"两种失败原因，供 UI 给出准确提示。
enum DeleteFolderResult {
  /// 删除成功
  success,

  /// 文件夹非空，拒绝删除
  notEmpty,

  /// 文件夹不存在（元数据与磁盘均无）
  notFound,

  /// 元数据保存失败，未做任何删除
  saveFailed,
}

/// 文件存储管理服务
///
/// 管理加密视频的目录结构、文件命名、元数据持久化
/// 负责扫描 .enc 文件并构建 VideoItem 模型
class StorageService {
  /// 元数据变更串行队列（互斥锁）
  ///
  /// 文件夹元数据操作均为 load → 改 → save 的读改写序列，无锁并发时会互相
  /// 覆盖导致丢数据。所有涉及元数据写入的操作都经 [_runExclusive] 排队执行。
  static Future<void> _mutationQueue = Future<void>.value();

  /// 串行执行一个元数据变更操作
  static Future<T> _runExclusive<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _mutationQueue = _mutationQueue.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, s) {
        completer.completeError(e, s);
      }
    });
    return completer.future;
  }

  /// 初始化所有必需的目录
  static Future<void> initDirectories() async {
    final lockDir = Directory(await PathProviderService.getLockVideoDir());
    final unlockDir = Directory(await PathProviderService.getUnlockVideoDir());
    final cacheDir = Directory(await PathProviderService.getCacheDir());

    if (!await lockDir.exists()) {
      await lockDir.create(recursive: true);
    }
    if (!await unlockDir.exists()) {
      await unlockDir.create(recursive: true);
    }
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
  }

  /// 扫描 LockVideo 目录下的所有 .enc 文件
  static Future<List<VideoItem>> scanEncryptedVideos() async {
    final lockDir = await PathProviderService.getLockVideoDir();
    final dir = Directory(lockDir);
    if (!await dir.exists()) {
      return [];
    }

    final videos = <VideoItem>[];

    await for (final entity in dir.list(recursive: true)) {
      if (entity is File && entity.path.endsWith('.enc')) {
        final video = await _fileToVideoItem(entity);
        if (video != null) {
          videos.add(video);
        }
      }
    }

    // 按加密时间降序排列
    videos.sort((a, b) => b.encryptedAt.compareTo(a.encryptedAt));
    return videos;
  }

  /// 从 .enc 文件构建 VideoItem
  static Future<VideoItem?> _fileToVideoItem(File encFile) async {
    try {
      final encPath = encFile.path;
      final fileName = p.basename(encPath);
      final thumbPath = buildThumbPath(encPath);

      // 解析显示名称和时间戳
      final displayName = _parseDisplayName(fileName);
      final encryptedAt = VideoItem.parseEncryptedAt(fileName);

      // 判断所属文件夹
      final parentDir = p.basename(p.dirname(encPath));
      final lockDirName = p.basename(await PathProviderService.getLockVideoDir());
      final folderName = parentDir == lockDirName ? null : parentDir;

      // 获取文件大小
      final stat = await encFile.stat();

      return VideoItem(
        id: _replaceSuffix(fileName, '.enc', ''),
        encPath: encPath,
        thumbPath: thumbPath,
        displayName: displayName,
        folderName: folderName,
        fileSize: stat.size,
        encryptedAt: encryptedAt,
      );
    } catch (e) {
      debugPrint('[SnPlayer] StorageService._fileToVideoItem: $e');
      return null;
    }
  }

  /// 从文件名解析显示名称
  /// 格式: 原始名称_yyyyMMdd.enc → 原始名称
  static String _parseDisplayName(String fileName) {
    final baseName = _replaceSuffix(fileName, '.enc', '');
    return baseName.replaceFirst(RegExp(r'_\d{8}$'), '');
  }

  /// 仅替换路径结尾的后缀
  ///
  /// replaceAll 会误替换路径中间的同名子串
  /// （如 my.encode_x.enc 会被替换成两处），必须限定结尾匹配。
  static String _replaceSuffix(String path, String from, String to) {
    if (!path.endsWith(from)) {
      return path;
    }
    return path.substring(0, path.length - from.length) + to;
  }

  /// 生成加密文件命名
  /// 格式: 原始名称_yyyyMMdd
  static String generateEncryptedFileName(String originalName) {
    final now = DateTime.now();
    final dateStr =
        '${now.year}${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';

    // 去除原始名称中的扩展名
    final baseName = p.basenameWithoutExtension(originalName);

    return '${baseName}_$dateStr';
  }

  /// 构建加密视频的完整输出路径
  static Future<String> buildEncPath(String folderName, String encryptedFileName) async {
    final lockDir = await PathProviderService.getLockVideoDir();
    if (folderName.isNotEmpty) {
      return p.join(lockDir, folderName, '$encryptedFileName.enc');
    }
    return p.join(lockDir, '$encryptedFileName.enc');
  }

  /// 构建加密缩略图的完整路径
  static String buildThumbPath(String encPath) {
    return _replaceSuffix(encPath, '.enc', '.tenc');
  }

  /// 移动视频到目标文件夹
  static Future<bool> moveVideo(VideoItem video, String? targetFolderName) async {
    try {
      final lockDir = await PathProviderService.getLockVideoDir();
      final targetDir = targetFolderName != null
          ? p.join(lockDir, targetFolderName)
          : lockDir;

      // 确保目标目录存在
      await Directory(targetDir).create(recursive: true);

      final encFileName = p.basename(video.encPath);
      final thumbFileName = p.basename(video.thumbPath);

      final newEncPath = p.join(targetDir, encFileName);
      final newThumbPath = p.join(targetDir, thumbFileName);

      // 目标与源相同（移回原文件夹）视为成功，无需移动
      if (newEncPath == video.encPath) {
        return true;
      }
      // 目标已存在则拒绝，防止 rename 静默覆盖导致数据丢失
      if (await File(newEncPath).exists()) {
        debugPrint('[SnPlayer] StorageService.moveVideo: 目标已存在 $newEncPath');
        return false;
      }

      // 移动加密视频
      await File(video.encPath).rename(newEncPath);
      // 移动缩略图（如果存在）
      if (await File(video.thumbPath).exists()) {
        await File(video.thumbPath).rename(newThumbPath);
      }

      return true;
    } catch (e) {
      debugPrint('[SnPlayer] StorageService.moveVideo: $e');
      return false;
    }
  }

  /// 重命名视频（同时移动 .enc 和 .tenc）
  static Future<bool> renameVideo(VideoItem video, String newDisplayName) async {
    try {
      final oldEncName = p.basename(video.encPath);
      // 提取日期后缀 _yyyyMMdd
      final dateMatch = RegExp(r'_(\d{8})\.enc$').firstMatch(oldEncName);
      final dateSuffix = dateMatch != null ? '_${dateMatch.group(1)}' : '';
      final newEncName = '$newDisplayName$dateSuffix.enc';

      final dirPath = p.dirname(video.encPath);
      final newEncPath = p.join(dirPath, newEncName);
      final newThumbPath = _replaceSuffix(newEncPath, '.enc', '.tenc');

      // 名称未变化视为成功
      if (newEncPath == video.encPath) {
        return true;
      }
      // 目标已存在则拒绝，防止 rename 静默覆盖导致数据丢失
      if (await File(newEncPath).exists()) {
        debugPrint('[SnPlayer] StorageService.renameVideo: 目标已存在 $newEncPath');
        return false;
      }

      await File(video.encPath).rename(newEncPath);
      if (await File(video.thumbPath).exists()) {
        await File(video.thumbPath).rename(newThumbPath);
      }

      return true;
    } catch (e) {
      debugPrint('[SnPlayer] StorageService.renameVideo: $e');
      return false;
    }
  }

  // --- 文件夹元数据管理 ---

  /// 读取 .folders.json
  ///
  /// 文件不存在返回空列表；解析失败（损坏）时先备份为 .folders.json.bak
  /// 再返回空列表，避免后续 load-改-存流程用空数据覆盖掉可恢复的原始内容。
  static Future<List<VideoFolder>> loadFolders() async {
    final lockDir = await PathProviderService.getLockVideoDir();
    final file = File(p.join(lockDir, foldersJsonFileName));

    if (!await file.exists()) {
      return [];
    }

    try {
      final content = await file.readAsString();
      final List<dynamic> jsonList = json.decode(content);
      return jsonList.map((j) => VideoFolder.fromJson(j)).toList();
    } catch (e) {
      debugPrint('[SnPlayer] StorageService.loadFolders: 元数据损坏，备份后重置: $e');
      // 备份损坏文件供人工恢复，避免被后续保存静默覆盖
      try {
        await file.rename('${file.path}.bak');
      } catch (e2) {
        debugPrint('[SnPlayer] StorageService.loadFolders: 备份失败: $e2');
      }
      return [];
    }
  }

  /// 保存 .folders.json
  ///
  /// 写临时文件后 rename 原子替换，防写入中途崩溃损坏元数据。
  static Future<bool> saveFolders(List<VideoFolder> folders) async {
    try {
      final lockDir = await PathProviderService.getLockVideoDir();
      final file = File(p.join(lockDir, foldersJsonFileName));
      final tmpFile = File('${file.path}.tmp');
      final jsonList = folders.map((f) => f.toJson()).toList();
      await tmpFile.writeAsString(json.encode(jsonList), flush: true);
      await tmpFile.rename(file.path);
      return true;
    } catch (e) {
      debugPrint('[SnPlayer] StorageService.saveFolders: $e');
      return false;
    }
  }

  /// 在互斥队列中执行一次"读取最新元数据 → 修改 → 保存"操作
  ///
  /// [mutator] 直接修改传入的列表并返回 true 表示需要保存；返回 false 则跳过保存。
  /// 供 FolderProvider 等上层复用，保证与 createFolder/deleteFolder 之间的串行性。
  static Future<bool> mutateFolders(
    Future<bool> Function(List<VideoFolder> folders) mutator,
  ) {
    return _runExclusive(() async {
      try {
        final folders = await loadFolders();
        final shouldSave = await mutator(folders);
        if (!shouldSave) { return false; }
        return await saveFolders(folders);
      } catch (e) {
        debugPrint('[SnPlayer] StorageService.mutateFolders: $e');
        return false;
      }
    });
  }

  /// 创建文件夹（物理目录 + 元数据）
  static Future<VideoFolder?> createFolder(String displayName, String color) async {
    return _runExclusive(() async {
      try {
        final now = DateTime.now();
        final timestamp = _formatTimestamp(now);
        final uuid = _generateShortUuid();
        final folderName = 'folder_${timestamp}_$uuid';

        // 创建物理目录
        final lockDir = await PathProviderService.getLockVideoDir();
        final folderDir = Directory(p.join(lockDir, folderName));
        await folderDir.create();

        final folder = VideoFolder(
          name: folderName,
          displayName: displayName,
          color: color,
        );

        // 更新元数据；保存失败则回滚刚创建的物理目录，避免磁盘元数据与
        // 内存状态分叉（否则重启后该文件夹会"消失"但空目录残留）
        final folders = await loadFolders();
        folders.add(folder);
        final saved = await saveFolders(folders);
        if (!saved) {
          try {
            await folderDir.delete();
          } catch (_) {
            // 回滚删除失败：留下空目录，无元数据不显示为标签，不影响正确性
          }
          return null;
        }

        return folder;
      } catch (e) {
        debugPrint('[SnPlayer] StorageService.createFolder: $e');
        return null;
      }
    });
  }

  /// 删除文件夹（物理目录 + 元数据）
  ///
  /// 返回具体结果而非 bool，便于 UI 区分"非空拒删"与"保存失败"。
  static Future<DeleteFolderResult> deleteFolder(String folderName) async {
    return _runExclusive(() async {
      try {
        final lockDir = await PathProviderService.getLockVideoDir();
        final folderDir = Directory(p.join(lockDir, folderName));

        final exists = await folderDir.exists();
        if (exists) {
          // 检查文件夹是否为空（非空拒绝，防止误删其中的视频）
          final contents = await folderDir.list().toList();
          if (contents.isNotEmpty) {
            return DeleteFolderResult.notEmpty;
          }
        }

        // 先持久化元数据：保存失败则不删物理目录，保持内存与磁盘一致
        final folders = await loadFolders();
        final removed = folders.indexWhere((f) => f.name == folderName);

        // 元数据与磁盘均无此文件夹
        if (!exists && removed == -1) {
          return DeleteFolderResult.notFound;
        }

        // 保留原条目以便复检失败时原样回滚（不丢失显示名与颜色）
        final removedFolder = removed == -1 ? null : folders[removed];
        folders.removeWhere((f) => f.name == folderName);

        final saved = await saveFolders(folders);
        if (!saved) {
          return DeleteFolderResult.saveFailed;
        }

        // 元数据已落盘，再删空物理目录（失败仅残留空目录，无碍正确性）
        if (exists) {
          // 删除前复检：若期间有视频被移入，则回滚元数据并报非空，
          // 避免标签消失却留下无法访问的孤儿视频
          final recheck = await folderDir.list().toList();
          if (recheck.isNotEmpty) {
            if (removedFolder != null) {
              folders.add(removedFolder);
              await saveFolders(folders);
            }
            return DeleteFolderResult.notEmpty;
          }
          try {
            await folderDir.delete();
          } catch (e) {
            debugPrint('[SnPlayer] StorageService.deleteFolder: 删除物理目录失败: $e');
          }
        }

        return DeleteFolderResult.success;
      } catch (e) {
        debugPrint('[SnPlayer] StorageService.deleteFolder: $e');
        return DeleteFolderResult.saveFailed;
      }
    });
  }

  /// 获取存储统计信息
  ///
  /// 区分永久数据与可清理缓存：
  /// - encSize/tencSize：加密视频与加密缩略图源（LockVideo 目录，永久数据，删除需重新生成）
  /// - cacheSize：播放磁盘缓存（play_cache 目录，可清理）
  /// - thumbCacheSize：缩略图解密磁盘缓存（thumb_cache 目录，可清理）
  /// cacheSize + thumbCacheSize 与 clearAllCache 的清理口径一致。
  static Future<Map<String, dynamic>> getStorageStats() async {
    final lockDir = await PathProviderService.getLockVideoDir();
    final cacheDir = await PathProviderService.getCacheDir();
    final thumbCacheDir = await PathProviderService.getThumbCacheDir();
    final dir = Directory(lockDir);

    int encCount = 0;
    int encSize = 0;
    int tencCount = 0;
    int tencSize = 0;

    if (await dir.exists()) {
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) {
          final stat = await entity.stat();
          if (entity.path.endsWith('.enc')) {
            encCount++;
            encSize += stat.size;
          } else if (entity.path.endsWith('.tenc')) {
            tencCount++;
            tencSize += stat.size;
          }
        }
      }
    }

    // 播放缓存统计（play_cache）
    final playCache = await _dirFileStats(cacheDir);
    // 缩略图磁盘缓存统计（thumb_cache）——与 clearAllCache 清理范围一致
    final thumbCache = await _dirFileStats(thumbCacheDir);

    return {
      'encCount': encCount,
      'encSize': encSize,
      'tencCount': tencCount,
      'tencSize': tencSize,
      'cacheCount': playCache.count,
      'cacheSize': playCache.size,
      'thumbCacheCount': thumbCache.count,
      'thumbCacheSize': thumbCache.size,
    };
  }

  /// 统计目录顶层文件数量与总大小（非递归）
  static Future<({int count, int size})> _dirFileStats(String dirPath) async {
    final dir = Directory(dirPath);
    int count = 0;
    int size = 0;
    if (await dir.exists()) {
      await for (final entity in dir.list()) {
        if (entity is File) {
          final stat = await entity.stat();
          count++;
          size += stat.size;
        }
      }
    }
    return (count: count, size: size);
  }

  /// 清理孤儿缩略图（没有对应 .enc 的 .tenc 文件）
  static Future<int> cleanOrphanThumbnails() async {
    final lockDir = await PathProviderService.getLockVideoDir();
    final dir = Directory(lockDir);
    if (!await dir.exists()) {
      return 0;
    }

    int deleted = 0;
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File && entity.path.endsWith('.tenc')) {
        final encPath = _replaceSuffix(entity.path, '.tenc', '.enc');
        if (!await File(encPath).exists()) {
          try {
            await entity.delete();
            deleted++;
          } catch (e) {
            // 单文件删除失败（占用/权限）不中断整个清理
            debugPrint('[SnPlayer] StorageService.cleanOrphanThumbnails: $e');
          }
        }
      }
    }
    return deleted;
  }

  // --- 工具 ---

  static String _formatTimestamp(DateTime dt) {
    return '${dt.year}${dt.month.toString().padLeft(2, '0')}'
        '${dt.day.toString().padLeft(2, '0')}'
        '${dt.hour.toString().padLeft(2, '0')}'
        '${dt.minute.toString().padLeft(2, '0')}'
        '${dt.second.toString().padLeft(2, '0')}';
  }

  static String _generateShortUuid() {
    // 使用 uuid v4 生成真正随机的 UUID，截取前 8 位作为短 ID
    return const Uuid().v4().substring(0, 8);
  }
}
