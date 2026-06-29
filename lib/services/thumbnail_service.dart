import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
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
    } catch (_) {
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
    } catch (_) {
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
    } catch (_) {
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
    } catch (_) {
      return false;
    }
  }
}
