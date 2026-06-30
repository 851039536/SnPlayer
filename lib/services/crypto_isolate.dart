import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/key_derivators/api.dart';
import 'package:pointycastle/key_derivators/pbkdf2.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/stream/ctr.dart';

import '../config/crypto.dart';

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
      } else {
        progressPort?.send({'type': 'error', 'message': 'Unknown command: $command'});
        return;
      }
      progressPort?.send({'type': 'done'});
    } catch (e) {
      progressPort?.send({'type': 'error', 'message': e.toString()});
    }
  });
}

// ═══════════════════════════════════════════════════════════
// Isolate 内部加解密实现
// ═══════════════════════════════════════════════════════════

final Map<String, Uint8List> _isoKeyCache = {};

Future<void> _encryptFileInIsolate(
  String inputPath,
  String outputPath,
  String password,
  SendPort? progressPort,
) async {
  final passwordBytes = Uint8List.fromList(utf8.encode(password));
  final iv = _isoRandomBytes(ivLength);
  final salt = _isoRandomBytes(saltLength);
  final key = _isoDeriveKey(passwordBytes, salt);
  final cipher = _isoCreateCipher(key, iv);

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

  final key = _isoDeriveKey(passwordBytes, salt);
  final cipher = _isoCreateCipher(key, iv);

  await _processFile(inputPath, outputPath, cipher,
    headerBuilder: null,
    startOffset: headerSize,
    progressPort: progressPort,
  );
}

/// 双缓冲 I/O + CTR 流式处理核心
Future<void> _processFile(
  String inputPath,
  String outputPath,
  StreamCipher cipher, {
  Uint8List? Function()? headerBuilder,
  int startOffset = 0,
  SendPort? progressPort,
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
    int totalRead = startOffset;

    int bytesRead = raf.readIntoSync(bufA);
    totalRead += bytesRead;

    while (bytesRead > 0) {
      final readBuf = useA ? bufA : bufB;
      final nextBuf = useA ? bufB : bufA;

      // 启动下一块的异步预读
      final pendingRead = raf.readInto(nextBuf);

      // 处理当前块：CTR 批量加解密
      cipher.processBytes(readBuf, 0, bytesRead, procBuf, 0);
      // 必须用 sublist（复制），因为 procBuf 下一轮会被覆盖，
      // 若 IOSink 尚未 flush 则会引用到已被改写的数据
      output.add(procBuf.sublist(0, bytesRead));

      // 进度回传
      if (progressPort != null) {
        final effectiveSize = fileSize - startOffset;
        if (effectiveSize > 0) {
          progressPort.send({
            'type': 'progress',
            'value': (totalRead - bytesRead - startOffset) / effectiveSize,
          });
        }
      }

      // 等待预读
      bytesRead = await pendingRead;
      totalRead += bytesRead;
      useA = !useA;
    }
  } finally {
    raf.closeSync();
    await output.flush();
    await output.close();
  }
}

// --- Isolate 内部工具函数 ---

Uint8List _isoDeriveKey(Uint8List passwordBytes, Uint8List salt) {
  final cacheKey = base64.encode(salt);
  final cached = _isoKeyCache[cacheKey];
  if (cached != null) {
    return cached;
  }

  final hmac = HMac(SHA256Digest(), 64);
  final derivator = PBKDF2KeyDerivator(hmac);
  derivator.init(Pbkdf2Parameters(salt, pbkdf2Iterations, keyLength));

  final key = derivator.process(passwordBytes);
  _isoKeyCache[cacheKey] = key;
  return key;
}

StreamCipher _isoCreateCipher(Uint8List key, Uint8List iv) {
  final cipher = CTRStreamCipher(AESEngine())
    ..init(
      true,
      ParametersWithIV(KeyParameter(key), iv),
    );
  return cipher;
}

Uint8List _isoRandomBytes(int length) {
  final random = Random.secure();
  final bytes = Uint8List(length);
  for (int i = 0; i < length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes;
}
