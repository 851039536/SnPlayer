// lib/services/crypto_isolate.dart — Isolate 后台加解密 Worker（全量/部分解密、加密、并行分块处理）

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:pointycastle/api.dart';

import '../config/crypto.dart';
import '../utils/crypto_utils.dart';

// ═══════════════════════════════════════════════════════════
// Isolate 后台加解密 Worker
// ═══════════════════════════════════════════════════════════
//
// 将文件加解密移至独立 Isolate，避免阻塞主线程 UI。
// 通过 SendPort 双向通信：主线程发送命令参数，worker 回传进度和结果。

/// Worker 入口函数（顶层函数，Isolate.spawn 要求）
void cryptoWorker(SendPort sendPort) {
  final receivePort = ReceivePort();
  sendPort.send(receivePort.sendPort); // 回传自己的 SendPort 给主线程

  // 注意：async 回调意味着多条命令会交错执行。当前设计为"一命令一 Isolate"，
  // 若复用长驻 worker 需先串行化消息队列，否则文件 I/O 会互相干扰。
  receivePort.listen((message) async {
    if (message is! Map) { return; }

    final command = message['command'] as String?;
    final inputPath = message['inputPath'] as String?;
    final outputPath = message['outputPath'] as String?;
    final progressPort = message['progressPort'] as SendPort?;
    final password = message['password'] as String? ?? defaultPassword;

    if (command == null || inputPath == null || outputPath == null) {
      progressPort?.send({'type': 'error', 'message': 'Missing required parameters'});
      return;
    }

    try {
      if (command == 'encrypt') {
        await _encryptFileInIsolate(inputPath, outputPath, password, progressPort);
      } else if (command == 'decrypt') {
        await _decryptFileInIsolate(inputPath, outputPath, password, progressPort);
      } else if (command == 'decrypt_partial') {
        final maxBytes = message['maxBytes'] as int? ?? partialDecryptMaxBytes;
        await _decryptFileInIsolate(inputPath, outputPath, password, progressPort, maxBytes: maxBytes);
      } else if (command == 'decrypt_chunk' || command == 'encrypt_chunk') {
        await _processChunkInIsolate(
          inputPath: inputPath,
          outputPath: outputPath,
          startOffset: (message['startOffset'] as int?) ?? 0,
          chunkLength: (message['chunkLength'] as int?) ?? 0,
          keyBase64: message['keyBase64'] as String? ?? '',
          ivBase64: message['ivBase64'] as String? ?? '',
          chunkIndex: (message['chunkIndex'] as int?) ?? 0,
          totalChunks: (message['totalChunks'] as int?) ?? 1,
          isDecrypt: command == 'decrypt_chunk',
          progressPort: progressPort,
        );
      } else {
        progressPort?.send({'type': 'error', 'message': 'Unknown command: $command'});
        return;
      }
      progressPort?.send({'type': 'done'});
    } catch (e) {
      // ignore: avoid_print (Isolate 环境下无法访问 flutter/foundation)
      print('[SnPlayer] CryptoIsolate error: $e');
      progressPort?.send({'type': 'error', 'message': e.toString()});
    }
  });
}

// ═══════════════════════════════════════════════════════════
// Isolate 内部加解密实现
// ═══════════════════════════════════════════════════════════

Future<void> _encryptFileInIsolate(
  String inputPath,
  String outputPath,
  String password,
  SendPort? progressPort,
) async {
  final passwordBytes = Uint8List.fromList(utf8.encode(password));
  final iv = CryptoUtils.generateRandomBytes(ivLength);
  final salt = CryptoUtils.generateRandomBytes(saltLength);
  final key = CryptoUtils.deriveKeyFromPassword(passwordBytes, salt);
  final cipher = CryptoUtils.createCtrCipher(key, iv);

  await _processFile(inputPath, outputPath, cipher,
    headerBuilder: () => CryptoUtils.buildEncHeader(iv, salt),
    startOffset: 0,
    progressPort: progressPort,
  );
}

/// 解密文件；[maxBytes] 非空时仅解密前 maxBytes 字节（用于快速提取缩略图）
Future<void> _decryptFileInIsolate(
  String inputPath,
  String outputPath,
  String password,
  SendPort? progressPort, {
  int? maxBytes,
}) async {
  final passwordBytes = Uint8List.fromList(utf8.encode(password));

  // 读取文件头（读取完毕立即关闭，避免与 _processFile 内部打开的 handle 冲突）
  final raf = File(inputPath).openSync(mode: FileMode.read);
  final header = Uint8List(headerSize);
  final headerBytesRead = raf.readIntoSync(header, 0, headerSize);
  raf.closeSync();

  // 解析并校验文件头（长度 + 版本），获取 IV/Salt
  final headerInfo = CryptoUtils.parseEncHeader(header, headerBytesRead);

  final key = CryptoUtils.deriveKeyFromPassword(passwordBytes, headerInfo.salt);
  final cipher = CryptoUtils.createCtrCipher(key, headerInfo.iv);

  await _processFile(inputPath, outputPath, cipher,
    headerBuilder: null,
    startOffset: headerSize,
    progressPort: progressPort,
    maxBytes: maxBytes,
  );
}

/// 双缓冲 I/O + CTR 流式处理核心
///
/// [maxBytes] 可选，限制解密的最大字节数。用于部分解密提取缩略图场景：
/// 达到上限后立即停止读取并 flush 输出，不处理剩余数据。
Future<void> _processFile(
  String inputPath,
  String outputPath,
  StreamCipher cipher, {
  Uint8List? Function()? headerBuilder,
  int startOffset = 0,
  SendPort? progressPort,
  int? maxBytes,
}) async {
  if (maxBytes != null && maxBytes <= 0) {
    throw ArgumentError.value(maxBytes, 'maxBytes', '必须为正数');
  }

  final inputFile = File(inputPath);
  final raf = inputFile.openSync(mode: FileMode.read);
  final output = File(outputPath).openWrite(mode: FileMode.writeOnly);

  try {
    final fileSize = raf.lengthSync();

    // 写入文件头（仅加密时）
    final hdr = headerBuilder?.call();
    if (hdr != null) {
      output.add(hdr);
    }

    // 跳过已读取的文件头（解密时）
    if (startOffset > 0) {
      raf.setPositionSync(startOffset);
    }

    // 双缓冲流水线
    final bufA = Uint8List(bufferSize);
    final bufB = Uint8List(bufferSize);
    final procBuf = Uint8List(bufferSize);

    bool useA = true;
    int totalDecrypted = 0; // 已解密字节数（用于 maxBytes 控制）
    int unflushedBytes = 0; // 自上次 flush 后累计写入字节数（背压控制）

    int bytesRead = raf.readIntoSync(bufA);

    while (bytesRead > 0) {
      final readBuf = useA ? bufA : bufB;
      final nextBuf = useA ? bufB : bufA;

      // 截断：达到 maxBytes 上限的一轮只需要处理部分缓冲区
      int processLen = bytesRead;
      bool reachLimit = false;
      if (maxBytes != null) {
        final remaining = maxBytes - totalDecrypted;
        if (processLen >= remaining) {
          processLen = remaining;
          reachLimit = true;
        }
      }

      // 启动下一块的异步预读。本轮达到上限时不预读：
      // 挂起的异步读会导致 finally 中 raf.closeSync() 抛异常
      Future<int>? pendingRead;
      if (!reachLimit) {
        pendingRead = raf.readInto(nextBuf);
      }

      // 处理当前块：CTR 批量加解密
      cipher.processBytes(readBuf, 0, processLen, procBuf, 0);
      output.add(procBuf.sublist(0, processLen));
      totalDecrypted += processLen;

      // 背压控制：IOSink.add 不阻塞，定期 flush 防止写盘慢于解密时内存积压
      unflushedBytes += processLen;
      if (unflushedBytes >= isolateFlushIntervalBytes) {
        await output.flush();
        unflushedBytes = 0;
      }

      // 进度回传
      if (progressPort != null) {
        final effectiveSize = maxBytes ?? (fileSize - startOffset);
        if (effectiveSize > 0) {
          progressPort.send({
            'type': 'progress',
            'value': totalDecrypted / effectiveSize,
          });
        }
      }

      // 达到上限后立即停止（此时无挂起的预读）
      if (reachLimit) { break; }

      // 等待预读
      bytesRead = await pendingRead!;
      useA = !useA;
    }

    // 正常路径在 try 内 flush，失败会作为错误上报（finally 中的失败会被吞掉）
    await output.flush();
  } finally {
    // 各自独立关闭：任一失败不屏蔽 try 中的原始异常，也不阻断另一方释放
    try {
      raf.closeSync();
    } catch (_) {
      // 忽略：释放阶段的失败不应覆盖 try 中的原始异常
    }
    try {
      await output.close();
    } catch (_) {
      // 忽略：同上
    }
  }
}

/// 并行加/解密块 Worker（通用）：处理原始/加密视频的一个指定区间，写入临时块文件
///
/// [isDecrypt] true=解密块（从加密文件读取，跳过 headerSize），
///              false=加密块（从原始文件读取）
///
/// 读取 [inputPath] 的 [startOffset] 起 [chunkLength] 字节，
/// 使用已调整的 AES-CTR cipher 加/解密后写入临时文件。
Future<void> _processChunkInIsolate({
  required String inputPath,
  required String outputPath,
  required int startOffset,
  required int chunkLength,
  required String keyBase64,
  required String ivBase64,
  required int chunkIndex,
  required int totalChunks,
  required bool isDecrypt,
  SendPort? progressPort,
}) async {
  // base64.decode 已返回 Uint8List，无需再拷贝
  final key = base64.decode(keyBase64);
  final iv = base64.decode(ivBase64);
  final cipher = CryptoUtils.createCtrCipher(key, iv);

  // 解密时需跳过文件头（startOffset 是相对于密文数据的）
  final fileStartOffset = isDecrypt ? headerSize + startOffset : startOffset;

  final inputFile = File(inputPath);
  final raf = inputFile.openSync(mode: FileMode.read);

  // 写入临时块文件
  final output = File(outputPath).openWrite(mode: FileMode.writeOnly);

  try {
    raf.setPositionSync(fileStartOffset);

    final bufA = Uint8List(bufferSize);
    final bufB = Uint8List(bufferSize);
    final procBuf = Uint8List(bufferSize);

    bool useA = true;
    int totalProcessed = 0;
    int unflushedBytes = 0; // 自上次 flush 后累计写入字节数（背压控制）

    final firstReadSize =
        (chunkLength < bufferSize) ? chunkLength : bufferSize;
    int bytesRead = raf.readIntoSync(bufA, 0, firstReadSize);

    while (bytesRead > 0) {
      final readBuf = useA ? bufA : bufB;
      final nextBuf = useA ? bufB : bufA;

      int processLen = bytesRead;
      final chunkRemaining = chunkLength - totalProcessed;
      if (processLen > chunkRemaining) {
        processLen = chunkRemaining;
      }

      final nextReadSize =
          ((chunkRemaining - processLen) < bufferSize)
              ? (chunkRemaining - processLen)
              : bufferSize;
      Future<int>? pendingRead;
      if (nextReadSize > 0) {
        pendingRead = raf.readInto(nextBuf, 0, nextReadSize);
      }

      // CTR 批量加/解密
      cipher.processBytes(readBuf, 0, processLen, procBuf, 0);
      output.add(procBuf.sublist(0, processLen));
      totalProcessed += processLen;

      // 背压控制：IOSink.add 不阻塞，定期 flush 防止写盘慢于加解密时内存积压
      unflushedBytes += processLen;
      if (unflushedBytes >= isolateFlushIntervalBytes) {
        await output.flush();
        unflushedBytes = 0;
      }

      if (progressPort != null && chunkLength > 0) {
        progressPort.send({
          'type': 'progress',
          'value': totalProcessed / chunkLength,
          'chunkIndex': chunkIndex,
          'totalChunks': totalChunks,
        });
      }

      if (totalProcessed >= chunkLength) { break; }

      if (pendingRead != null) {
        bytesRead = await pendingRead;
      } else {
        bytesRead = 0;
      }

      useA = !useA;
    }

    // 校验块完整性：输入文件被截断/修改时 EOF 会提前到来，
    // 不校验会静默产出短块，合并后得到损坏的输出文件
    if (totalProcessed < chunkLength) {
      throw StateError(
        '数据块不完整：期望 $chunkLength 字节，实际 $totalProcessed 字节（输入文件可能已损坏）',
      );
    }

    // 正常路径在 try 内 flush，失败会作为错误上报
    await output.flush();
  } finally {
    // 各自独立关闭：任一失败不屏蔽 try 中的原始异常，也不阻断另一方释放
    try {
      raf.closeSync();
    } catch (_) {
      // 忽略：释放阶段的失败不应覆盖 try 中的原始异常
    }
    try {
      await output.close();
    } catch (_) {
      // 忽略：同上
    }
  }
}
