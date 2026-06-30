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
        await _decryptFilePartialInIsolate(inputPath, outputPath, password, progressPort, maxBytes);
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
    headerBuilder: () {
      final header = Uint8List(headerSize);
      header.setAll(0, iv);
      header.setAll(ivLength, salt);
      return header;
    },
    startOffset: 0,
    progressPort: progressPort,
  );
}

Future<void> _decryptFileInIsolate(
  String inputPath,
  String outputPath,
  String password,
  SendPort? progressPort,
) async {
  final passwordBytes = Uint8List.fromList(utf8.encode(password));

  // 读取文件头
  final inputFile = File(inputPath);
  final raf = inputFile.openSync(mode: FileMode.read);
  final header = Uint8List(headerSize);
  raf.readIntoSync(header, 0, headerSize);

  // 读取完毕立即关闭，避免与 _processFile 内部打开的 handle 冲突
  raf.closeSync();

  final iv = Uint8List.sublistView(header, 0, ivLength);
  final salt = Uint8List.sublistView(header, saltOffset, saltOffset + saltLength);

  final key = CryptoUtils.deriveKeyFromPassword(passwordBytes, salt);
  final cipher = CryptoUtils.createCtrCipher(key, iv);

  await _processFile(inputPath, outputPath, cipher,
    headerBuilder: null,
    startOffset: headerSize,
    progressPort: progressPort,
  );
}

/// 部分解密文件（仅解密前 [maxBytes] 字节，用于快速提取缩略图）
Future<void> _decryptFilePartialInIsolate(
  String inputPath,
  String outputPath,
  String password,
  SendPort? progressPort,
  int maxBytes,
) async {
  final passwordBytes = Uint8List.fromList(utf8.encode(password));

  // 读取文件头获取 IV 和盐值
  final inputFile = File(inputPath);
  final raf = inputFile.openSync(mode: FileMode.read);
  final header = Uint8List(headerSize);
  raf.readIntoSync(header, 0, headerSize);
  raf.closeSync();

  final iv = Uint8List.sublistView(header, 0, ivLength);
  final salt = Uint8List.sublistView(header, saltOffset, saltOffset + saltLength);

  final key = CryptoUtils.deriveKeyFromPassword(passwordBytes, salt);
  final cipher = CryptoUtils.createCtrCipher(key, iv);

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

    int bytesRead = raf.readIntoSync(bufA);

    while (bytesRead > 0) {
      final readBuf = useA ? bufA : bufB;
      final nextBuf = useA ? bufB : bufA;

      // 截断：最后一轮可能只需要处理部分缓冲区
      int processLen = bytesRead;
      if (maxBytes != null) {
        final remaining = maxBytes - totalDecrypted;
        if (remaining <= 0) { break; }
        if (processLen > remaining) {
          processLen = remaining;
        }
      }

      // 启动下一块的异步预读
      final pendingRead = raf.readInto(nextBuf);

      // 处理当前块：CTR 批量加解密
      cipher.processBytes(readBuf, 0, processLen, procBuf, 0);
      output.add(procBuf.sublist(0, processLen));
      totalDecrypted += processLen;

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

      // 达到上限后立即停止
      if (maxBytes != null && totalDecrypted >= maxBytes) { break; }

      // 等待预读
      bytesRead = await pendingRead;
      useA = !useA;
    }
  } finally {
    raf.closeSync();
    await output.flush();
    await output.close();
  }
}


