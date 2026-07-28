// lib/services/storage_service.dart — 文件存储管理（目录/扫描/命名/移动重命名/文件夹元数据/存储统计）

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/video_item.dart';
import '../models/video_folder.dart';
import '../config/crypto.dart';
import 'path_provider_service.dart';

/// 文件存储管理服务
///
/// 管理加密视频的目录结构、文件命名、元数据持久化
/// 负责扫描 .enc 文件并构建 VideoItem 模型
class StorageService {
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

  /// 创建文件夹（物理目录 + 元数据）
  static Future<VideoFolder?> createFolder(String displayName, String color) async {
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

      // 更新元数据
      final folders = await loadFolders();
      folders.add(folder);
      await saveFolders(folders);

      return folder;
    } catch (e) {
      debugPrint('[SnPlayer] StorageService.createFolder: $e');
      return null;
    }
  }

  /// 删除文件夹（物理目录 + 元数据）
  static Future<bool> deleteFolder(String folderName) async {
    try {
      final lockDir = await PathProviderService.getLockVideoDir();
      final folderDir = Directory(p.join(lockDir, folderName));

      if (await folderDir.exists()) {
        // 检查文件夹是否为空
        final contents = await folderDir.list().toList();
        if (contents.isNotEmpty) {
          return false; // 文件夹非空，不允许删除
        }
        await folderDir.delete();
      }

      // 更新元数据
      final folders = await loadFolders();
      folders.removeWhere((f) => f.name == folderName);
      await saveFolders(folders);

      return true;
    } catch (e) {
      debugPrint('[SnPlayer] StorageService.deleteFolder: $e');
      return false;
    }
  }

  /// 获取存储统计信息
  static Future<Map<String, dynamic>> getStorageStats() async {
    final lockDir = await PathProviderService.getLockVideoDir();
    final cacheDir = await PathProviderService.getCacheDir();
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

    // 缓存统计
    int cacheCount = 0;
    int cacheSize = 0;
    final cacheDirObj = Directory(cacheDir);
    if (await cacheDirObj.exists()) {
      await for (final entity in cacheDirObj.list()) {
        if (entity is File) {
          final stat = await entity.stat();
          cacheCount++;
          cacheSize += stat.size;
        }
      }
    }

    return {
      'encCount': encCount,
      'encSize': encSize,
      'tencCount': tencCount,
      'tencSize': tencSize,
      'cacheCount': cacheCount,
      'cacheSize': cacheSize,
    };
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
          await entity.delete();
          deleted++;
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
