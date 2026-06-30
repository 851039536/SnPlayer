

import 'package:flutter/foundation.dart';

import '../utils/file_utils.dart';

/// 视频数据模型
class VideoItem {
  /// 唯一标识（文件名时间戳前缀，如 encrypted_20260629143000123）
  final String id;

  /// 加密视频文件的完整路径
  final String encPath;

  /// 加密缩略图文件的完整路径（.tenc）
  final String thumbPath;

  /// 显示名称（原始视频文件名，不含扩展名）
  String displayName;

  /// 所属文件夹名（物理目录名），null 表示在根目录
  String? folderName;

  /// 加密文件大小（字节）
  int fileSize;

  /// 加密时间
  DateTime encryptedAt;

  /// 磁盘缓存缩略图路径（thumb_cache/ 下的 JPEG 文件路径）
  /// null 表示尚未加载
  String? thumbCachePath;

  VideoItem({
    required this.id,
    required this.encPath,
    required this.thumbPath,
    required this.displayName,
    this.folderName,
    required this.fileSize,
    required this.encryptedAt,
    this.thumbCachePath,
  });

  /// 从文件名解析加密时间
  static DateTime parseEncryptedAt(String fileName) {
    try {
      final base = fileName.replaceAll('.enc', '');
      final match = RegExp(r'_(\d{8})$').firstMatch(base);
      if (match != null) {
        final d = match.group(1)!;
        return DateTime(int.parse(d.substring(0, 4)),
            int.parse(d.substring(4, 6)), int.parse(d.substring(6, 8)));
      }
    } catch (e) {
      debugPrint('[SnPlayer] VideoItem.parseEncryptedAt: $e');
    }
    return DateTime.now();
  }

  /// 格式化文件大小为人可读字符串
  String get formattedSize => FileUtils.formatFileSize(fileSize);
}
