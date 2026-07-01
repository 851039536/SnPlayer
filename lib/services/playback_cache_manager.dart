import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../config/crypto.dart';
import 'safe_delete_helper.dart';

/// 播放磁盘缓存管理器
///
/// 管理解密后视频文件的磁盘缓存，支持：
/// - 缓存完整性校验（文件大小比对 + 文件头内容验证）
/// - 缓存路径生成
/// - 过期清理
/// - 总量管理（LRU 淘汰）
class PlaybackCacheManager {
  /// 文件头校验读取字节数
  ///
  /// 任何有效视频文件的前 64 字节必然包含非零数据（文件签名 + 元数据），
  /// 全零文件只会来自 StreamingDecryptProxy 的预分配或文件系统稀疏分配。
  static const int _headerCheckSize = 64;

  /// 检查缓存是否命中且完整
  ///
  /// 比对缓存文件大小与期望的解密大小（= encFileSize - 64），
  /// 并通过文件头内容校验拦截全零脏缓存文件。
  /// 大小匹配且内容有效则返回缓存文件路径，否则返回 null。
  static Future<String?> getCachedFile(
    String encPath,
    String cacheDir,
  ) async {
    try {
      final cacheFilePath = getCacheFilePath(encPath, cacheDir);
      final cacheFile = File(cacheFilePath);

      if (!await cacheFile.exists()) {
        return null;
      }

      // 获取加密文件大小，计算期望的解密大小
      final encFileSize = await File(encPath).length();
      final expectedSize = encFileSize - headerSize;
      final actualSize = await cacheFile.length();

      if (actualSize != expectedSize) {
        // 缓存不完整，删除并返回 null
        debugPrint('[SnPlayer] PlaybackCacheManager: 缓存不完整 '
            '(期望 $expectedSize B, 实际 $actualSize B)，删除缓存');
        await SafeDeleteHelper.fastDelete(cacheFilePath);
        return null;
      }

      // 文件头内容校验：拦截全零脏缓存（StreamingDecryptProxy 预分配产物）
      if (!await _isValidCacheContent(cacheFilePath)) {
        debugPrint('[SnPlayer] PlaybackCacheManager: 缓存内容无效（全零文件），删除缓存');
        await SafeDeleteHelper.fastDelete(cacheFilePath);
        return null;
      }

      debugPrint('[SnPlayer] PlaybackCacheManager: 缓存命中 $cacheFilePath');
      return cacheFilePath;
    } catch (e) {
      debugPrint('[SnPlayer] PlaybackCacheManager.getCachedFile: $e');
      return null;
    }
  }

  /// 校验缓存文件头内容是否有效（非全零）
  ///
  /// 打开文件读取前 [_headerCheckSize] 字节，检查是否存在非零字节。
  /// 全零文件说明内容未被填充，是脏缓存。
  static Future<bool> _isValidCacheContent(String filePath) async {
    final raf = await File(filePath).open(mode: FileMode.read);
    try {
      final header = Uint8List(_headerCheckSize);
      final bytesRead = await raf.readInto(header, 0, _headerCheckSize);
      if (bytesRead < _headerCheckSize) {
        return false;
      }
      // 检查是否存在非零字节（有效视频文件必定有非零数据）
      return header.any((b) => b != 0);
    } finally {
      await raf.close();
    }
  }

  /// 生成缓存文件路径
  ///
  /// 命名规则与现有 [CryptoService.decryptToTemp] 保持一致：`play_{文件名}.mp4`
  static String getCacheFilePath(String encPath, String cacheDir) {
    final fileName = p.basenameWithoutExtension(encPath);
    return p.join(cacheDir, 'play_$fileName.mp4');
  }

  /// 清理过期缓存文件
  ///
  /// 删除 [playCacheExpireDays] 天前的缓存文件。
  /// 返回删除的文件数量。
  static Future<int> cleanupExpiredCache(String cacheDir) async {
    final dir = Directory(cacheDir);
    if (!await dir.exists()) {
      return 0;
    }

    int deleted = 0;
    final now = DateTime.now();
    final maxAge = const Duration(days: playCacheExpireDays);

    await for (final entity in dir.list()) {
      if (entity is! File) {
        continue;
      }
      if (!entity.path.contains('play_')) {
        continue;
      }

      try {
        final stat = await entity.stat();
        if (now.difference(stat.modified) > maxAge) {
          if (await SafeDeleteHelper.fastDelete(entity.path)) {
            deleted++;
          }
        }
      } catch (e) {
        debugPrint('[SnPlayer] PlaybackCacheManager.cleanupExpiredCache: $e');
      }
    }

    if (deleted > 0) {
      debugPrint('[SnPlayer] PlaybackCacheManager: 清理过期缓存 $deleted 个文件');
    }
    return deleted;
  }

  /// 清理超量缓存文件（LRU 策略）
  ///
  /// 当缓存目录总大小超过 [playCacheMaxSize] 时，
  /// 按最旧优先策略删除文件直到总量低于上限。
  /// 返回删除的文件数量。
  static Future<int> cleanupOversizedCache(String cacheDir) async {
    final dir = Directory(cacheDir);
    if (!await dir.exists()) {
      return 0;
    }

    // 收集所有 play_ 缓存文件及其大小和修改时间
    final files = <_CacheFileInfo>[];
    int totalSize = 0;

    await for (final entity in dir.list()) {
      if (entity is! File) {
        continue;
      }
      if (!entity.path.contains('play_')) {
        continue;
      }

      try {
        final stat = await entity.stat();
        files.add(_CacheFileInfo(
          path: entity.path,
          size: stat.size,
          modified: stat.modified,
        ));
        totalSize += stat.size;
      } catch (_) {}
    }

    if (totalSize <= playCacheMaxSize) {
      return 0;
    }

    // 按修改时间升序排序（最旧在前）
    files.sort((a, b) => a.modified.compareTo(b.modified));

    int deleted = 0;
    for (final file in files) {
      if (totalSize <= playCacheMaxSize) {
        break;
      }
      if (await SafeDeleteHelper.fastDelete(file.path)) {
        totalSize -= file.size;
        deleted++;
      }
    }

    if (deleted > 0) {
      debugPrint('[SnPlayer] PlaybackCacheManager: 清理超量缓存 $deleted 个文件，'
          '剩余 ${totalSize ~/ 1024 ~/ 1024}MB');
    }
    return deleted;
  }

  /// 执行完整的缓存清理（过期 + 超量）
  static Future<void> performCleanup(String cacheDir) async {
    await cleanupExpiredCache(cacheDir);
    await cleanupOversizedCache(cacheDir);
  }
}

/// 缓存文件信息（内部使用）
class _CacheFileInfo {
  final String path;
  final int size;
  final DateTime modified;

  const _CacheFileInfo({
    required this.path,
    required this.size,
    required this.modified,
  });
}
