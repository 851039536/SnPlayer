// lib/services/safe_delete_helper.dart — 安全删除工具（零覆写防恢复 + 指数退避重试 + 快速删除）

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
  ///
  /// 注意：必须用不截断的 FileMode.append 打开。FileMode.write 等同 O_TRUNC，
  /// 打开即清空文件、length 恒为 0，覆写循环一次都不会执行（安全功能实际失效）。
  /// Dart 的 append 模式不强制追加写，可 setPosition(0) 后随机覆写。
  static Future<void> _zeroOverwrite(File file) async {
    final raf = await file.open(mode: FileMode.append);
    try {
      final fileLength = await raf.length();
      await raf.setPosition(0);

      final zeros = Uint8List(safeDeleteOverwriteBlockSize);
      int remaining = fileLength;
      int unflushed = 0;

      while (remaining > 0) {
        final toWrite = remaining > safeDeleteOverwriteBlockSize
            ? safeDeleteOverwriteBlockSize
            : remaining;
        await raf.writeFrom(zeros, 0, toWrite);
        remaining -= toWrite;

        // 定期 flush 确保零块真正落盘，同时限制未落盘数据量
        unflushed += toWrite;
        if (unflushed >= isolateFlushIntervalBytes) {
          await raf.flush();
          unflushed = 0;
        }
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

    for (int attempt = 0; attempt < fastDeleteRetryDelays.length; attempt++) {
      try {
        await file.delete();

        if (!await file.exists()) {
          return true;
        }
      } catch (e) {
        debugPrint('[SnPlayer] SafeDeleteHelper.fastDelete 尝试 $attempt 失败: $e');
      }

      if (attempt < fastDeleteRetryDelays.length - 1) {
        await Future.delayed(Duration(milliseconds: fastDeleteRetryDelays[attempt]));
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
      if (entity is! File) {
        continue;
      }
      try {
        final stat = await entity.stat();
        final age = now.difference(stat.modified);
        if (age > maxAge) {
          // 播放临时文件非敏感数据，用快速删除（与 PlaybackCacheManager 策略一致），
          // 避免对数百 MB 缓存做无谓零覆写
          if (await fastDelete(entity.path)) {
            deletedCount++;
          }
        }
      } catch (e) {
        // 单个文件异常（如被并发删除）不中断整个清理
        debugPrint('[SnPlayer] SafeDeleteHelper.cleanupCacheFiles: $e');
      }
    }

    return deletedCount;
  }
}
