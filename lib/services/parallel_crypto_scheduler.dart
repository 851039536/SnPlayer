// lib/services/parallel_crypto_scheduler.dart — 多 Isolate 并行分块加解密调度器

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../config/crypto.dart';
import '../utils/crypto_utils.dart';
import 'crypto_isolate.dart';

/// 并行分块加解密调度器
///
/// 利用 AES-CTR 的随机访问特性，将数据切分为 2~6 块，
/// 各块在独立 Isolate 中处理为临时块文件，再按偏移合并到输出文件。
/// 文件大小 < 64MB 不应走此路径（由 CryptoService 分流控制）。
///
/// 加密与解密共用同一调度流程，差异仅三点（由参数表达）：
/// - 加密写 64 字节文件头（[header] 非空），解密不写
/// - 输出偏移基址：加密 = headerSize（密文在文件头之后），解密 = 0
/// - Isolate 命令：encrypt_chunk / decrypt_chunk（[isEncrypt]）
class ParallelCryptoScheduler {
  /// 单 chunk Isolate 最大运行时间（5 分钟），超时后强制终止
  static const Duration _chunkTimeout = Duration(minutes: 5);

  /// 并行分块加/解密调度入口
  ///
  /// [key]/[iv] 为已派生的密钥与原始 IV（各块的 counter 偏移由本函数计算）。
  /// [header] 加密时传入待写的 64 字节文件头；解密时传 null。
  /// [dataSize] 待处理数据大小：加密 = 原始文件大小，解密 = 密文大小（不含文件头）。
  static Future<void> run({
    required bool isEncrypt,
    required String inputPath,
    required String outputPath,
    required Uint8List key,
    required Uint8List iv,
    Uint8List? header,
    required int dataSize,
    void Function(double)? onProgress,
  }) async {
    final keyBase64 = base64.encode(key);

    // 计算分块数和每块边界（chunkSize 必须 16 字节对齐，末块吸收余数）
    final isolateCount = _getChunkCount(dataSize);
    final rawChunkSize = dataSize ~/ isolateCount;
    final chunkSize = (rawChunkSize ~/ aesBlockSize) * aesBlockSize;

    final opLabel = isEncrypt ? '并行加密' : '并行解密';
    debugPrint('[SnPlayer] $opLabel: 数据=${dataSize}B, 分$isolateCount块, '
        '每块≈${(chunkSize / 1024 / 1024).toStringAsFixed(1)}MB');

    // 输出偏移基址：加密时密文位于 64 字节文件头之后
    final outputBase = isEncrypt ? headerSize : 0;
    final totalSize = outputBase + dataSize;

    // 预分配输出文件，保持句柄打开直到所有批次写入完成
    //
    // 关键：不能用 FileMode.write 多次打开输出文件（会截断已写入的文件头和
    // 前序批次数据），整个并行流程复用同一句柄，由 try/finally 保证关闭。
    final outputRaf = await File(outputPath).open(mode: FileMode.write);
    bool rafClosed = false;

    final pendingFutures = <Future<void>>[];
    final chunkTempPaths = <String>[];
    final chunkWriteOffsets = <int>[];
    double maxProgress = 0.0;

    try {
      // 写文件头（仅加密）+ 预分配到最终大小
      if (header != null) {
        await outputRaf.writeFrom(header, 0, header.length);
      }
      await outputRaf.setPosition(totalSize - 1);
      await outputRaf.writeByte(0);

      // 分批启动 chunk Isolate
      for (int i = 0; i < isolateCount; i++) {
        final startOffset = i * chunkSize;
        final length =
            (i == isolateCount - 1) ? dataSize - startOffset : chunkSize;

        // 计算调整后的 IV：counter += startOffset / 16
        final adjustedIv =
            CryptoUtils.incrementCounter(iv, startOffset ~/ aesBlockSize);

        final tempPath = '$outputPath.chunk_$i.tmp';
        chunkTempPaths.add(tempPath);
        chunkWriteOffsets.add(outputBase + startOffset);

        final future = _spawnChunkIsolate(
          inputPath: inputPath,
          outputPath: tempPath,
          startOffset: startOffset,
          chunkLength: length,
          keyBase64: keyBase64,
          ivBase64: base64.encode(adjustedIv),
          chunkIndex: i,
          totalChunks: isolateCount,
          isEncrypt: isEncrypt,
          onProgress: onProgress == null
              ? null
              : (globalProgress) {
                  // 单调递增：多 chunk 并发交错时只回调最大值，避免进度来回跳
                  if (globalProgress > maxProgress) {
                    maxProgress = globalProgress;
                    onProgress(maxProgress);
                  }
                },
        );

        pendingFutures.add(future);

        // 每批 parallelDecryptMaxConcurrency 个，完成后合并到输出文件
        if (pendingFutures.length >= parallelDecryptMaxConcurrency) {
          await Future.wait(pendingFutures);
          await _writeBatchToOutput(outputRaf, chunkTempPaths, chunkWriteOffsets);
          await _deleteTempFiles(chunkTempPaths);
          pendingFutures.clear();
          chunkTempPaths.clear();
          chunkWriteOffsets.clear();
        }
      }

      // 处理剩余的块
      if (pendingFutures.isNotEmpty) {
        await Future.wait(pendingFutures);
        await _writeBatchToOutput(outputRaf, chunkTempPaths, chunkWriteOffsets);
        await _deleteTempFiles(chunkTempPaths);
      }

      onProgress?.call(1.0);
    } catch (e) {
      // 清理残留的临时 chunk 文件
      await _deleteTempFiles(chunkTempPaths);
      // 先关闭句柄再删除损坏的输出文件，避免调用方误用半成品
      try {
        await outputRaf.close();
      } catch (_) {
        // 忽略：确保能继续删除输出文件
      }
      rafClosed = true;
      try {
        await File(outputPath).delete();
      } catch (_) {
        // 忽略：输出文件可能未创建成功
      }
      rethrow;
    } finally {
      if (!rafClosed) {
        try {
          await outputRaf.close();
        } catch (_) {
          // 忽略：释放阶段的失败不应覆盖 try 中的原始异常
        }
      }
    }
  }

  /// 将一批临时块文件按各自偏移写入已打开的输出文件句柄
  ///
  /// **重要**：调用方负责打开和关闭 [outputRaf]，避免使用 `FileMode.write`
  /// 重复打开导致已写入的文件头和前序批次数据被截断清零。
  /// 全程异步 I/O：同步复制单批可达数百 MB，会冻结 UI 主线程。
  static Future<void> _writeBatchToOutput(
    RandomAccessFile outputRaf,
    List<String> tempPaths,
    List<int> writeOffsets,
  ) async {
    final copyBuf = Uint8List(bufferSize);
    for (int i = 0; i < tempPaths.length; i++) {
      final chunkFile = File(tempPaths[i]);
      final expectedLength = await chunkFile.length();
      final raf = await chunkFile.open(mode: FileMode.read);
      int copied = 0;
      try {
        await outputRaf.setPosition(writeOffsets[i]);
        // 循环条件用 bytesRead > 0（而非 == bufferSize）：
        // 短读不代表 EOF，旧条件会提前退出，静默产出缺数据的输出文件
        int bytesRead = await raf.readInto(copyBuf);
        while (bytesRead > 0) {
          await outputRaf.writeFrom(copyBuf, 0, bytesRead);
          copied += bytesRead;
          bytesRead = await raf.readInto(copyBuf);
        }
      } finally {
        try {
          await raf.close();
        } catch (_) {
          // 忽略：释放阶段的失败不应覆盖原始异常
        }
      }

      // 校验复制总量，防止静默截断
      if (copied != expectedLength) {
        throw StateError(
          '块文件复制不完整: ${tempPaths[i]} 期望 $expectedLength 字节，实际 $copied 字节',
        );
      }
    }
  }

  /// 删除临时块文件（逐个容错，不中断）
  static Future<void> _deleteTempFiles(List<String> paths) async {
    for (final path in paths) {
      try {
        await File(path).delete();
      } catch (_) {
        // 忽略：临时文件可能不存在或已被清理
      }
    }
  }

  /// 启动单个加/解密块 Isolate，等待其完成
  static Future<void> _spawnChunkIsolate({
    required String inputPath,
    required String outputPath,
    required int startOffset,
    required int chunkLength,
    required String keyBase64,
    required String ivBase64,
    required int chunkIndex,
    required int totalChunks,
    required bool isEncrypt,
    void Function(double)? onProgress,
  }) async {
    final completer = Completer<void>();
    final command = isEncrypt ? 'encrypt_chunk' : 'decrypt_chunk';
    final opLabel = isEncrypt ? 'Encrypt' : 'Decrypt';

    final receivePort = ReceivePort();
    final isolate = await Isolate.spawn(cryptoWorker, receivePort.sendPort);
    final workerSendPort = await receivePort.first as SendPort;

    final progressPort = ReceivePort();
    progressPort.listen((event) {
      if (event is Map) {
        final type = event['type'] as String?;
        if (type == 'progress') {
          final value = (event['value'] as num?)?.toDouble();
          if (value != null && onProgress != null) {
            onProgress((chunkIndex + value) / totalChunks);
          }
        } else if (type == 'done') {
          if (!completer.isCompleted) { completer.complete(); }
        } else if (type == 'error') {
          final msg = event['message'] as String? ?? 'Unknown error';
          if (!completer.isCompleted) {
            completer.completeError(Exception(
                '$opLabel chunk $chunkIndex/$totalChunks failed: $msg'));
          }
        }
      }
    });

    try {
      workerSendPort.send(<String, dynamic>{
        'command': command,
        'inputPath': inputPath,
        'outputPath': outputPath,
        'startOffset': startOffset,
        'chunkLength': chunkLength,
        'keyBase64': keyBase64,
        'ivBase64': ivBase64,
        'chunkIndex': chunkIndex,
        'totalChunks': totalChunks,
        'progressPort': progressPort.sendPort,
      });

      await completer.future.timeout(_chunkTimeout, onTimeout: () {
        throw TimeoutException(
            '$opLabel chunk $chunkIndex/$totalChunks timeout (${_chunkTimeout.inSeconds}s)');
      });
    } finally {
      progressPort.close();
      receivePort.close();
      try {
        isolate.kill(priority: Isolate.beforeNextEvent);
      } catch (e) {
        isolate.kill(priority: Isolate.immediate);
      }
    }
  }

  /// 确定分块数
  static int _getChunkCount(int cipherDataSize) {
    if (cipherDataSize >= parallelDecryptLargeFileSize) {
      return parallelDecryptLargeIsolates; // >512MB: 6 路
    }
    if (cipherDataSize >= parallelDecryptMidFileSize) {
      return parallelDecryptMaxIsolates; // 256-512MB: 4 路
    }
    return parallelDecryptMidIsolates; // 64-256MB: 2 路
  }
}
