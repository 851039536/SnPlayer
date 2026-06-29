import 'dart:typed_data';

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

  /// 缩略图数据（解密后的 JPEG 字节，加载后缓存）
  Uint8List? coverData;

  VideoItem({
    required this.id,
    required this.encPath,
    required this.thumbPath,
    required this.displayName,
    this.folderName,
    required this.fileSize,
    required this.encryptedAt,
    this.coverData,
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
    } catch (_) {
      // 解析失败返回当前时间
    }
    return DateTime.now();
  }

  /// 格式化文件大小为人可读字符串
  String get formattedSize {
    if (fileSize < 1024) {
      return '$fileSize B';
    } else if (fileSize < 1024 * 1024) {
      return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    } else if (fileSize < 1024 * 1024 * 1024) {
      return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else {
      return '${(fileSize / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
  }
}
