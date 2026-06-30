import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/video_item.dart';
import '../config/crypto.dart';

/// 安全删除工具类
///
/// 实现零覆写 + 指数退避重试的安全删除机制
/// 防止文件数据被恢复工具还原
class SafeDeleteHelper {
  /// 安全删除单个文件
  ///
  /// 1. 用零块逐段覆写整个文件内容
  /// 2. SetLength(0) + Flush() 确保写入磁盘
  /// 3. 删除文件
  /// 4. 失败时指数退避重试
  static Future<bool> safeDelete(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      return true; // 文件已不存在，视为成功
    }

    for (int attempt = 0; attempt < safeDeleteRetryDelays.length; attempt++) {
      try {
        // 1. 零覆写
        await _zeroOverwrite(file);

        // 2. 删除
        await file.delete();

        // 3. 验证已删除
        if (!await file.exists()) {
          return true;
        }
      } catch (e) {
        debugPrint('[SnPlayer] SafeDeleteHelper.safeDelete 尝试 $attempt 失败: $e');
        // 删除失败，等待后重试
      }

      // 非最后一次尝试时等待
      if (attempt < safeDeleteRetryDelays.length - 1) {
        await Future.delayed(Duration(milliseconds: safeDeleteRetryDelays[attempt]));
      }
    }

    return false;
  }

  /// 零覆写文件内容
  static Future<void> _zeroOverwrite(File file) async {
    final raf = await file.open(mode: FileMode.write);
    try {
      final zeros = Uint8List(safeDeleteBlockSize);
      final fileLength = await raf.length();
      int remaining = fileLength;

      while (remaining > 0) {
        final toWrite =
            remaining > safeDeleteBlockSize ? safeDeleteBlockSize : remaining;
        await raf.writeFrom(zeros, 0, toWrite);
        remaining -= toWrite;
      }

      await raf.truncate(0);
      await raf.flush();
    } finally {
      await raf.close();
    }
  }

  /// 安全删除视频及其关联缩略图
  static Future<bool> safeDeleteVideo(VideoItem video) async {
    // 先删除加密视频，再删除缩略图
    final encDeleted = await safeDelete(video.encPath);
    final thumbDeleted = await safeDelete(video.thumbPath);
    return encDeleted && thumbDeleted;
  }

  /// 快速删除文件（无零覆写，用于非敏感的播放临时文件）
  ///
  /// 与 [safeDelete] 不同，此方法跳过零覆写阶段，直接删除文件。
  /// 适用于播放缓存临时文件、并行解密块临时文件等非敏感数据。
  /// 失败时简单重试 3 次，不复写内容。
  static Future<bool> fastDelete(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      return true;
    }

    const retryDelays = [100, 500, 1000]; // ms

    for (int attempt = 0; attempt < retryDelays.length; attempt++) {
      try {
        await file.delete();

        if (!await file.exists()) {
          return true;
        }
      } catch (e) {
        debugPrint('[SnPlayer] SafeDeleteHelper.fastDelete 尝试 $attempt 失败: $e');
      }

      if (attempt < retryDelays.length - 1) {
        await Future.delayed(Duration(milliseconds: retryDelays[attempt]));
      }
    }

    return false;
  }

  /// 清理播放缓存目录中超过 maxAge 的临时文件
  static Future<int> cleanupCacheFiles(String cacheDir, Duration maxAge) async {
    final dir = Directory(cacheDir);
    if (!await dir.exists()) {
      return 0;
    }

    int deletedCount = 0;
    final now = DateTime.now();

    await for (final entity in dir.list()) {
      if (entity is File) {
        final stat = await entity.stat();
        final age = now.difference(stat.modified);
        if (age > maxAge) {
          if (await safeDelete(entity.path)) {
            deletedCount++;
          }
        }
      }
    }

    return deletedCount;
  }
}
