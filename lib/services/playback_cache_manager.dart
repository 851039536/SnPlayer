// lib/services/playback_cache_manager.dart — 播放磁盘缓存管理（完整性校验/路径生成/过期与 LRU 清理）

import 'dart:io';

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
  /// 任何有效视频文件的前 64 字节必然包含非零数据（文件签名 + 元数据）。
  /// 全零头校验是防御性措施：拦截文件系统稀疏分配等异常产物
  /// （历史上流式代理曾预分配磁盘文件，现已是纯内存实现，不再落盘）。
  static const int _headerCheckSize = 64;

  /// 孤儿临时文件回收阈值（1 小时）
  ///
  /// .decrypting.tmp / .chunk_N.tmp / thumbgen_ / thumb_partial_ 正常流程由
  /// 创建方 finally 自删；进程被杀时会遗留，超过此时长仍存在即视为孤儿。
  static const Duration _orphanTempMaxAge = Duration(hours: 1);

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

      // 文件头内容校验：拦截全零脏缓存（防御性措施，见 _headerCheckSize 说明）
      if (!await _isValidCacheContent(cacheFilePath)) {
        debugPrint('[SnPlayer] PlaybackCacheManager: 缓存内容无效（全零文件），删除缓存');
        await SafeDeleteHelper.fastDelete(cacheFilePath);
        return null;
      }

      // LRU touch：命中即刷新 mtime，使过期/淘汰基于"最近使用"而非"写入时间"，
      // 否则天天播放的热门缓存也会在 3 天后被删、超量时被优先淘汰（LRU 变 FIFO）
      try {
        await cacheFile.setLastModified(DateTime.now());
      } catch (_) {
        // 忽略：touch 失败不影响缓存命中
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

  /// 判断是否为正式播放缓存文件（play_*.mp4）
  ///
  /// 必须对 basename 做前缀 + 后缀双条件判断：缓存目录名就叫 play_cache，
  /// 对全路径 contains('play_') 恒为真；仅前缀则 play_x.mp4.decrypting.tmp 也会误判。
  static bool _isPlayCacheFile(String path) {
    final name = p.basename(path);
    return name.startsWith('play_') && name.endsWith('.mp4');
  }

  /// 判断是否为可回收的临时文件（超龄即孤儿）
  static bool _isTempFile(String path) {
    final name = p.basename(path);
    return name.endsWith('.decrypting.tmp') ||
        RegExp(r'\.chunk_\d+\.tmp$').hasMatch(name) ||
        name.startsWith('thumbgen_') ||
        name.startsWith('thumb_partial_');
  }

  /// 单次遍历缓存目录：收集正式缓存文件信息，可选同步回收孤儿临时文件
  static Future<List<_CacheFileInfo>> _listPlayCacheFiles(
    String cacheDir, {
    bool reapOrphans = false,
  }) async {
    final dir = Directory(cacheDir);
    final files = <_CacheFileInfo>[];
    if (!await dir.exists()) {
      return files;
    }

    final now = DateTime.now();
    await for (final entity in dir.list()) {
      if (entity is! File) {
        continue;
      }
      try {
        if (_isPlayCacheFile(entity.path)) {
          final stat = await entity.stat();
          files.add(_CacheFileInfo(
            path: entity.path,
            size: stat.size,
            modified: stat.modified,
          ));
        } else if (reapOrphans && _isTempFile(entity.path)) {
          final stat = await entity.stat();
          if (now.difference(stat.modified) > _orphanTempMaxAge) {
            await SafeDeleteHelper.fastDelete(entity.path);
          }
        }
      } catch (e) {
        // 单文件异常（如被并发删除）不中断整个扫描
        debugPrint('[SnPlayer] PlaybackCacheManager._listPlayCacheFiles: $e');
      }
    }
    return files;
  }

  /// 清理过期缓存文件
  ///
  /// 删除 [playCacheExpireDays] 天前的缓存文件。
  /// 返回删除的文件数量。
  static Future<int> cleanupExpiredCache(String cacheDir) async {
    final files = await _listPlayCacheFiles(cacheDir);
    return _deleteExpired(files);
  }

  /// 删除列表中已过期的缓存文件，并从列表移除（供后续 LRU 阶段复用列表）
  static Future<int> _deleteExpired(List<_CacheFileInfo> files) async {
    int deleted = 0;
    final now = DateTime.now();
    const maxAge = Duration(days: playCacheExpireDays);

    final remaining = <_CacheFileInfo>[];
    for (final file in files) {
      if (now.difference(file.modified) > maxAge &&
          await SafeDeleteHelper.fastDelete(file.path)) {
        deleted++;
      } else {
        remaining.add(file);
      }
    }
    files
      ..clear()
      ..addAll(remaining);

    if (deleted > 0) {
      debugPrint('[SnPlayer] PlaybackCacheManager: 清理过期缓存 $deleted 个文件');
    }
    return deleted;
  }

  /// 清理超量缓存文件（LRU 策略）
  ///
  /// 当缓存目录总大小超过 [playCacheMaxSize] 时，
  /// 按最久未使用优先策略删除文件直到总量低于上限。
  /// [exemptPath] 淘汰时跳过的文件（写后清理时豁免刚产出的缓存，防自删）。
  /// 返回删除的文件数量。
  static Future<int> cleanupOversizedCache(
    String cacheDir, {
    String? exemptPath,
  }) async {
    final files = await _listPlayCacheFiles(cacheDir);
    return _evictOversized(files, exemptPath: exemptPath);
  }

  /// LRU 淘汰实现：对已收集的文件列表按总量上限淘汰
  static Future<int> _evictOversized(
    List<_CacheFileInfo> files, {
    String? exemptPath,
  }) async {
    int totalSize = files.fold(0, (sum, f) => sum + f.size);
    if (totalSize <= playCacheMaxSize) {
      return 0;
    }

    // 按修改时间升序排序（最旧在前）；getCachedFile 命中会 touch mtime，
    // 故"最旧"即"最久未使用"（真 LRU）
    files.sort((a, b) => a.modified.compareTo(b.modified));

    int deleted = 0;
    for (final file in files) {
      if (totalSize <= playCacheMaxSize) {
        break;
      }
      if (exemptPath != null && p.equals(file.path, exemptPath)) {
        continue;
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

  /// 执行完整的缓存清理（孤儿临时文件回收 + 过期 + 超量），单次目录遍历
  static Future<void> performCleanup(String cacheDir) async {
    final files = await _listPlayCacheFiles(cacheDir, reapOrphans: true);
    await _deleteExpired(files);
    await _evictOversized(files);
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
