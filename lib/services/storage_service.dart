import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

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
      final thumbPath = encPath.replaceAll('.enc', '.tenc');

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
        id: fileName.replaceAll('.enc', ''),
        encPath: encPath,
        thumbPath: thumbPath,
        displayName: displayName,
        folderName: folderName,
        fileSize: stat.size,
        encryptedAt: encryptedAt,
      );
    } catch (_) {
      return null;
    }
  }

  /// 从文件名解析显示名称
  static String _parseDisplayName(String fileName) {
    // 文件名格式: encrypted_yyyyMMddHHmmssfff_原始名称.enc
    final baseName = fileName.replaceAll('.enc', '');
    final parts = baseName.split('_');
    if (parts.length >= 3) {
      return parts.sublist(2).join('_');
    }
    return baseName;
  }

  /// 生成加密文件命名
  /// 格式: encrypted_yyyyMMddHHmmssfff_原始名称
  static String generateEncryptedFileName(String originalName) {
    final now = DateTime.now();
    final timestamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}'
        '${now.millisecond.toString().padLeft(3, '0')}';

    // 去除原始名称中的扩展名
    final baseName = p.basenameWithoutExtension(originalName);

    return 'encrypted_${timestamp}_$baseName';
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
    return encPath.replaceAll('.enc', '.tenc');
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

      // 移动加密视频
      await File(video.encPath).rename(newEncPath);
      // 移动缩略图（如果存在）
      if (await File(video.thumbPath).exists()) {
        await File(video.thumbPath).rename(newThumbPath);
      }

      return true;
    } catch (_) {
      return false;
    }
  }

  /// 重命名视频（同时移动 .enc 和 .tenc）
  static Future<bool> renameVideo(VideoItem video, String newDisplayName) async {
    try {
      final oldEncName = p.basename(video.encPath);
      final parts = oldEncName.split('_');
      if (parts.length < 3) {
        return false;
      }
      parts[parts.length - 1] = '${newDisplayName}.enc';
      final newEncName = parts.join('_');

      final dirPath = p.dirname(video.encPath);
      final newEncPath = p.join(dirPath, newEncName);
      final newThumbPath = newEncPath.replaceAll('.enc', '.tenc');

      await File(video.encPath).rename(newEncPath);
      if (await File(video.thumbPath).exists()) {
        await File(video.thumbPath).rename(newThumbPath);
      }

      return true;
    } catch (_) {
      return false;
    }
  }

  // --- 文件夹元数据管理 ---

  /// 读取 .folders.json
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
    } catch (_) {
      return [];
    }
  }

  /// 保存 .folders.json
  static Future<bool> saveFolders(List<VideoFolder> folders) async {
    try {
      final lockDir = await PathProviderService.getLockVideoDir();
      final file = File(p.join(lockDir, foldersJsonFileName));
      final jsonList = folders.map((f) => f.toJson()).toList();
      await file.writeAsString(json.encode(jsonList));
      return true;
    } catch (_) {
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
    } catch (_) {
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
    } catch (_) {
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
        final encPath = entity.path.replaceAll('.tenc', '.enc');
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
    // 生成 8 字符短 UUID
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final buf = StringBuffer();
    for (int i = 0; i < 8; i++) {
      buf.write(chars[DateTime.now().microsecondsSinceEpoch % chars.length]);
    }
    return buf.toString();
  }
}
