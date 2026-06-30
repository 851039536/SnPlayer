import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import '../config/crypto.dart';
import 'crypto_service.dart';

/// 缩略图服务
///
/// 负责从视频中提取帧、缩放、编码为 JPEG，
/// 并对缩略图进行加密存储（.tenc 格式）
class ThumbnailService {
  /// 从视频文件中提取缩略图
  ///
  /// 返回 JPEG 格式的缩略图字节数据（280x150, 80% 质量）
  static Future<Uint8List?> extractThumbnail(String videoPath) async {
    try {
      final thumbnailBytes = await VideoThumbnail.thumbnailData(
        video: videoPath,
        imageFormat: ImageFormat.JPEG,
        maxWidth: thumbnailWidth,
        maxHeight: thumbnailHeight,
        quality: thumbnailQuality,
        timeMs: 1000, // 取视频第 1 秒的帧作为封面
      );

      return thumbnailBytes;
    } catch (e) {
      debugPrint('[SnPlayer] ThumbnailService.extractThumbnail: $e');
      return null;
    }
  }

  /// 生成并加密缩略图到指定路径
  ///
  /// 返回加密缩略图路径，失败返回 null
  static Future<String?> generateAndEncryptThumbnail(
    String videoPath,
    String thumbPath,
  ) async {
    try {
      final jpegBytes = await extractThumbnail(videoPath);
      if (jpegBytes == null) {
        return null;
      }

      // 加密缩略图数据
      final encrypted = await CryptoService.encryptBytes(jpegBytes);

      // 写入 .tenc 文件
      final thumbFile = File(thumbPath);
      await thumbFile.parent.create(recursive: true);
      await thumbFile.writeAsBytes(encrypted);

      return thumbPath;
    } catch (e) {
      debugPrint('[SnPlayer] ThumbnailService.generateAndEncryptThumbnail: $e');
      return null;
    }
  }

  /// 加载并解密缩略图
  ///
  /// 返回 JPEG 字节数据，失败返回 null
  static Future<Uint8List?> loadThumbnail(String thumbPath) async {
    try {
      final thumbFile = File(thumbPath);
      if (!await thumbFile.exists()) {
        return null;
      }

      final encrypted = await thumbFile.readAsBytes();
      final decrypted = CryptoService.decryptBytes(encrypted);

      return decrypted;
    } catch (e) {
      debugPrint('[SnPlayer] ThumbnailService.loadThumbnail: $e');
      return null;
    }
  }

  /// 检测是否为旧版 GIF 缩略图（兼容处理）
  ///
  /// 读取文件头 3 字节检测 GIF 魔术字 "GIF"
  static Future<bool> isGifThumbnail(String thumbPath) async {
    try {
      final file = File(thumbPath);
      if (!await file.exists()) {
        return false;
      }

      // 解密后检查前 3 字节
      final encrypted = await file.readAsBytes();
      final decrypted = CryptoService.decryptBytes(encrypted);

      if (decrypted.length >= 3) {
        return decrypted[0] == 0x47 &&
            decrypted[1] == 0x49 &&
            decrypted[2] == 0x46; // 'G', 'I', 'F'
      }
      return false;
    } catch (e) {
      debugPrint('[SnPlayer] ThumbnailService.isGifThumbnail: $e');
      return false;
    }
  }

  /// 解密缩略图到磁盘缓存文件
  ///
  /// 从 .tenc 解密并写入 thumb_cache/{videoId}.jpg，
  /// 返回缓存文件路径。若缓存已存在直接返回。
  static Future<String?> decryptThumbnailToCache(String videoId, String thumbPath, String cacheDir) async {
    try {
      final cacheFile = File('$cacheDir/$videoId.jpg');

      // 缓存命中直接返回
      if (await cacheFile.exists()) {
        return cacheFile.path;
      }

      final decrypted = await loadThumbnail(thumbPath);
      if (decrypted == null) {
        return null;
      }

      await cacheFile.parent.create(recursive: true);
      await cacheFile.writeAsBytes(decrypted);
      return cacheFile.path;
    } catch (e) {
      debugPrint('[SnPlayer] ThumbnailService.decryptThumbnailToCache: $e');
      return null;
    }
  }

  /// 清理过期的磁盘缓存文件
  ///
  /// 删除 thumb_cache/ 中超过 [maxAge] 天未修改的文件
  static Future<int> cleanupExpiredCache(String cacheDir, {int maxAgeDays = thumbCacheExpireDays}) async {
    final dir = Directory(cacheDir);
    if (!await dir.exists()) {
      return 0;
    }

    int deleted = 0;
    final now = DateTime.now();
    final maxAge = Duration(days: maxAgeDays);

    await for (final entity in dir.list()) {
      if (entity is File) {
        try {
          final stat = await entity.stat();
          if (now.difference(stat.modified) > maxAge) {
            await entity.delete();
            deleted++;
          }
        } catch (e) {
          debugPrint('[SnPlayer] ThumbnailService.cleanupExpiredCache: $e');
        }
      }
    }

    return deleted;
  }
}
