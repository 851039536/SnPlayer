import 'dart:io';

import 'package:path/path.dart' as p;

/// 文件工具函数
class FileUtils {
  /// 生成去重文件名
  ///
  /// video.mp4 → video(1).mp4 → video(2).mp4 ...
  static String getUniqueFileName(String directory, String fileName) {
    final ext = p.extension(fileName);
    final baseName = p.basenameWithoutExtension(fileName);

    String candidate = fileName;
    int counter = 1;

    while (File(p.join(directory, candidate)).existsSync()) {
      candidate = '$baseName($counter)$ext';
      counter++;
    }

    return candidate;
  }

  /// 格式化文件大小为可读字符串
  static String formatFileSize(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    } else if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    } else if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
  }

  /// 验证文件名是否安全（不包含非法字符）
  static bool isValidFileName(String name) {
    const invalidChars = ['/', '\\', ':', '*', '?', '"', '<', '>', '|'];
    for (final c in invalidChars) {
      if (name.contains(c)) {
        return false;
      }
    }
    return name.trim().isNotEmpty;
  }

  /// 过滤文件名中的非法字符
  static String sanitizeFileName(String name) {
    const invalidChars = ['/', '\\', ':', '*', '?', '"', '<', '>', '|'];
    String result = name;
    for (final c in invalidChars) {
      result = result.replaceAll(c, '_');
    }
    return result.trim();
  }
}
