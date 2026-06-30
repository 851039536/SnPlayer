

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
      // 文件名格式: encrypted_yyyyMMddHHmmssfff_原始名称.enc
      final base = fileName.replaceAll('.enc', '');
      final parts = base.split('_');
      if (parts.length >= 2) {
        final datePart = parts[1];
        final year = int.parse(datePart.substring(0, 4));
        final month = int.parse(datePart.substring(4, 6));
        final day = int.parse(datePart.substring(6, 8));
        final hour = int.parse(datePart.substring(8, 10));
        final minute = int.parse(datePart.substring(10, 12));
        final second = int.parse(datePart.substring(12, 14));
        return DateTime(year, month, day, hour, minute, second);
      }
    } catch (e) {
      debugPrint('[SnPlayer] VideoItem.parseEncryptedAt: $e');
      // 解析失败返回当前时间
    }
    return DateTime.now();
  }

  /// 格式化文件大小为人可读字符串
  String get formattedSize => FileUtils.formatFileSize(fileSize);
}
