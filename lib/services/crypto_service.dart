import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:pointycastle/api.dart';

import '../config/crypto.dart';
import '../utils/crypto_utils.dart';
import 'crypto_isolate.dart';

/// AES-256-CTR 加密/解密核心服务
///
/// 兼容 MewTool .enc 文件格式（64 字节文件头：IV + Salt + 保留字段）
/// 采用 PBKDF2-HMAC-SHA256 密钥派生 + AES-256-CTR 流式加密
/// 4MB 双缓冲流水线，I/O 与 CPU 计算重叠
/// 大文件（≥64MB）自动启用 2-4 路并行分块解密
class CryptoService {
  /// 从固定密码和指定盐值派生 32 字节 AES 密钥
  /// 密码固定，以 salt 的 base64 编码作为缓存 key，避免重复的 100K 迭代开销
  static Uint8List deriveKey(Uint8List passwordBytes, Uint8List salt) {
    final cacheKey = base64.encode(salt);
    final cached = _keyCache[cacheKey];
    if (cached != null) {
      return cached;
    }

    final key = CryptoUtils.deriveKeyFromPassword(passwordBytes, salt);
    _addToCache(cacheKey, key);
    return key;
  }

  /// 加密文件（在后台 Isolate 中执行，不阻塞 UI）
  ///
  /// [inputPath] 原始视频文件路径
  /// [outputPath] 加密输出路径（.enc）
  /// [onProgress] 进度回调，参数为 0.0 ~ 1.0
  static Future<void> encryptFile(
    String inputPath,
    String outputPath, {
    void Function(double)? onProgress,
  }) async {
    await _runInIsolate(
      command: 'encrypt',
      inputPath: inputPath,
      outputPath: outputPath,
      onProgress: onProgress,
    );
  }

  /// 解密文件（在后台 Isolate 中执行，不阻塞 UI）
  ///
  /// [inputPath] 加密文件路径（.enc）
  /// [outputPath] 解密输出路径
  /// [onProgress] 进度回调，参数为 0.0 ~ 1.0
  static Future<void> decryptFile(
    String inputPath,
    String outputPath, {
    void Function(double)? onProgress,
  }) async {
    await _runInIsolate(
      command: 'decrypt',
      inputPath: inputPath,
      outputPath: outputPath,
      onProgress: onProgress,
    );
  }

  /// Isolate 最大运行时间（5 分钟），超时后强制终止
  static const Duration _isolateTimeout = Duration(minutes: 5);

  /// 部分解密超时（30 秒），30MB 部分解密通常 1-3 秒内完成
  static const Duration _partialTimeout = Duration(seconds: 30);

  /// 在后台 Isolate 中执行加解密，通过 SendPort 接收进度事件
  static Future<void> _runInIsolate({
    required String command,
    required String inputPath,
    required String outputPath,
    void Function(double)? onProgress,
  }) async {
    await _spawnAndManageIsolate(
      message: {
        'command': command,
        'inputPath': inputPath,
        'outputPath': outputPath,
        'password': defaultPassword,
      },
      timeout: _isolateTimeout,
      onProgress: onProgress,
    );
  }

  /// 在后台 Isolate 中执行部分解密，通过 SendPort 接收进度事件
  ///
  /// 与 [_runInIsolate] 共享相同的 Isolate 生命周期管理，额外传递 [maxBytes] 参数。
  static Future<void> _runPartialInIsolate({
    required String command,
    required String inputPath,
    required String outputPath,
    required int maxBytes,
  }) async {
    await _spawnAndManageIsolate(
      message: {
        'command': command,
        'inputPath': inputPath,
        'outputPath': outputPath,
        'password': defaultPassword,
        'maxBytes': maxBytes,
      },
      timeout: _partialTimeout,
    );
  }

  /// Isolate 生命周期管理公共方法
  ///
  /// 负责 Isolate 的 spawn/通信/超时/优雅关闭，具体消息内容由调用方组装。
  static Future<void> _spawnAndManageIsolate({
    required Map<String, dynamic> message,
    required Duration timeout,
    void Function(double)? onProgress,
  }) async {
    final completer = Completer<void>();

    // 启动 worker
    final receivePort = ReceivePort();
    final isolate = await Isolate.spawn(cryptoWorker, receivePort.sendPort);

    // 等待 worker 回传它的 SendPort
    final workerSendPort = await receivePort.first as SendPort;

    // 创建进度监听端口
    final progressPort = ReceivePort();
    progressPort.listen((event) {
      if (event is Map) {
        final type = event['type'] as String?;
        if (type == 'progress') {
          final value = (event['value'] as num?)?.toDouble();
          if (value != null) {
            onProgress?.call(value);
          }
        } else if (type == 'done') {
          if (!completer.isCompleted) {
            completer.complete();
          }
        } else if (type == 'error') {
          final msg = event['message'] as String? ?? 'Unknown error';
          if (!completer.isCompleted) {
            completer.completeError(Exception(msg));
          }
        }
      }
    });

    try {
      message['progressPort'] = progressPort.sendPort;
      workerSendPort.send(message);

      await completer.future.timeout(timeout, onTimeout: () {
        throw TimeoutException(
            'Isolate ${message['command']} 操作超时 (${timeout.inSeconds}s): ${message['inputPath']}');
      });
    } catch (e) {
      debugPrint('[SnPlayer] CryptoService._spawnAndManageIsolate: $e');
      rethrow;
    } finally {
      progressPort.close();
      receivePort.close();
      // 优雅关闭：先尝试 beforeNextEvent，失败后再 immediate
      try {
        isolate.kill(priority: Isolate.beforeNextEvent);
      } catch (e) {
        debugPrint(
            '[SnPlayer] CryptoService._spawnAndManageIsolate: Isolate.kill failed $e');
        isolate.kill(priority: Isolate.immediate);
      }
    }
  }

  /// 解密到临时缓存文件，返回临时文件路径
  ///
  /// 自动根据文件大小选择解密策略：
  /// - < 64MB：单 Isolate 串行解密
  /// - 64MB~256MB：2 Isolate 并行分块解密
  /// - > 256MB：4 Isolate 并行分块解密
  static Future<String> decryptToTemp(
    String encPath,
    String cacheDir, {
    void Function(double)? onProgress,
  }) async {
    final fileName = p.basenameWithoutExtension(encPath);
    final tempPath = p.join(cacheDir, 'play_$fileName.mp4');

    // 确保缓存目录存在
    await Directory(cacheDir).create(recursive: true);

    // 检测文件大小，自动选择串行或并行解密
    final fileSize = await File(encPath).length();
    if (fileSize >= parallelDecryptMinFileSize) {
      await decryptFileParallel(encPath, tempPath, onProgress: onProgress);
    } else {
      await decryptFile(encPath, tempPath, onProgress: onProgress);
    }

    return tempPath;
  }

  /// 并行分块解密文件
  ///
  /// 利用 AES-CTR 的随机访问特性，将密文数据切分为 2~8 块，
  /// 各块在独立 Isolate 中并行解密，直接写入输出文件对应偏移位置。
  ///
  /// 文件大小 < 64MB 不触发并行（由 [decryptToTemp] 控制）。
  static Future<void> decryptFileParallel(
    String inputPath,
    String outputPath, {
    void Function(double)? onProgress,
  }) async {
    await _runParallelDecrypt(
      inputPath: inputPath,
      outputPath: outputPath,
      onProgress: onProgress,
    );
  }

  /// 部分解密到临时文件（仅解密用于缩略图提取的前 N MB）
  ///
  /// 临时文件命名 `thumb_partial_{videoId}.mp4`，与播放缓存 `play_*.mp4` 隔离。
  /// [videoId] 用于生成唯一临时文件名。
  /// [maxBytes] 最大解密字节数，默认 [partialDecryptMaxBytes]（30MB）。
  static Future<String> decryptToTempPartial(
    String encPath,
    String cacheDir,
    String videoId, {
    int maxBytes = partialDecryptMaxBytes,
  }) async {
    final tempPath = p.join(cacheDir, 'thumb_partial_$videoId.mp4');

    // 确保缓存目录存在
    await Directory(cacheDir).create(recursive: true);

    await _runPartialInIsolate(
      command: 'decrypt_partial',
      inputPath: encPath,
      outputPath: tempPath,
      maxBytes: maxBytes,
    );
    return tempPath;
  }


  /// 加密数据块（用于缩略图等内存数据）
  static Future<Uint8List> encryptBytes(Uint8List data) async {
    final passwordBytes = Uint8List.fromList(utf8.encode(defaultPassword));
    final iv = _generateRandomBytes(ivLength);
    final salt = _generateRandomBytes(saltLength);

    final key = deriveKey(passwordBytes, salt);
    final cipher = _createCipher(key, iv);

    final encrypted = Uint8List(headerSize + data.length);
    encrypted.setAll(0, iv);
    encrypted.setAll(ivLength, salt);
    encrypted[versionOffset] = versionByte; // v2 格式版本号

    _processCtrBlock(cipher, data, encrypted, data.length,
        dstOffset: headerSize);

    return encrypted;
  }

  /// 解密数据块（用于缩略图等内存数据）
  static Uint8List decryptBytes(Uint8List encrypted) {
    final passwordBytes = Uint8List.fromList(utf8.encode(defaultPassword));

    final iv = encrypted.sublist(0, ivLength);
    final salt = encrypted.sublist(saltOffset, saltOffset + saltLength);

    // 校验格式版本号
    final ver = encrypted[versionOffset];
    if (ver != versionByte) {
      throw FormatException(
        '不支持的加密格式版本: 0x${ver.toRadixString(16).padLeft(2, '0')}，'
        '当前仅支持 v2 (0x02)。请使用最新版 MewTool 重新加密该文件。',
      );
    }

    final key = deriveKey(passwordBytes, salt);
    final cipher = _createCipher(key, iv);

    final data = encrypted.sublist(headerSize);
    final decrypted = Uint8List(data.length);

    _processCtrBlock(cipher, data, decrypted, data.length);

    return decrypted;
  }

  // --- 并行解密 ---

  /// 并行分块解密核心调度
  ///
  /// 1. 读取文件头获取 IV + Salt
  /// 2. 派生密钥
  /// 3. 计算分块数和边界（16 字节对齐）
  /// 4. 预分配输出文件
  /// 5. 分批 spawn Isolate 到临时文件，主线程按偏移复制到输出
  static Future<void> _runParallelDecrypt({
    required String inputPath,
    required String outputPath,
    void Function(double)? onProgress,
  }) async {
    // 1. 读取文件头获取 IV 和 Salt
    final inputFile = File(inputPath);
    final raf = await inputFile.open(mode: FileMode.read);
    final header = Uint8List(headerSize);
    await raf.readInto(header, 0, headerSize);
    final fileSize = await raf.length();
    await raf.close();

    final iv = Uint8List.sublistView(header, 0, ivLength);
    final salt = Uint8List.sublistView(header, saltOffset, saltOffset + saltLength);

    // 校验格式版本号
    final ver = header[versionOffset];
    if (ver != versionByte) {
      throw FormatException(
        '不支持的加密格式版本: 0x${ver.toRadixString(16).padLeft(2, '0')}，'
        '当前仅支持 v2 (0x02)。请使用最新版 MewTool 重新加密该文件。',
      );
    }

    // 2. 派生密钥
    final passwordBytes = Uint8List.fromList(utf8.encode(defaultPassword));
    final key = deriveKey(passwordBytes, salt);
    final keyBase64 = base64.encode(key);

    // 3. 计算分块数和每块边界（chunkSize 必须 16 字节对齐）
    final cipherDataSize = fileSize - headerSize;
    final isolateCount = _getChunkCount(cipherDataSize);
    final rawChunkSize = cipherDataSize ~/ isolateCount;
    final chunkSize = (rawChunkSize ~/ aesBlockSize) * aesBlockSize;

    debugPrint('[SnPlayer] 并行解密: 文件=${fileSize}B, 密文=${cipherDataSize}B, '
        '分$isolateCount块, 每块≈${(chunkSize / 1024 / 1024).toStringAsFixed(1)}MB');

    // 4. 预分配输出文件
    final outputFile = File(outputPath);
    final outputRaf = outputFile.openSync(mode: FileMode.write);
    outputRaf.setPositionSync(cipherDataSize - 1);
    outputRaf.writeByteSync(0);
    outputRaf.closeSync();

    // 5. 分批启动 Isolate
    final pendingFutures = <Future<void>>[];
    final chunkTempPaths = <String>[];
    final chunkWriteOffsets = <int>[];

    for (int i = 0; i < isolateCount; i++) {
      final startOffset = i * chunkSize;
      final length = (i == isolateCount - 1)
          ? cipherDataSize - startOffset
          : chunkSize;

      // 计算调整后的 IV：counter += startOffset / 16
      final adjustedIv = CryptoUtils.incrementCounter(iv, startOffset ~/ aesBlockSize);
      final ivBase64 = base64.encode(adjustedIv);

      // 临时块文件路径
      final tempPath = '$outputPath.chunk_$i.tmp';
      chunkTempPaths.add(tempPath);
      chunkWriteOffsets.add(startOffset);

      final future = _spawnChunkIsolate(
        inputPath: inputPath,
        outputPath: tempPath,
        startOffset: startOffset,
        chunkLength: length,
        writeOffset: startOffset,
        keyBase64: keyBase64,
        ivBase64: ivBase64,
        chunkIndex: i,
        totalChunks: isolateCount,
        onProgress: onProgress,
      );

      pendingFutures.add(future);

      // 每批 parallelDecryptMaxConcurrency 个，完成后复制到输出文件
      if (pendingFutures.length >= parallelDecryptMaxConcurrency) {
        await Future.wait(pendingFutures);
        // 主线程将本批临时文件复制到输出文件对应偏移
        await _writeBatchToOutput(chunkTempPaths, chunkWriteOffsets, outputPath);
        // 清理临时文件
        for (final p in chunkTempPaths) {
          try { await File(p).delete(); } catch (_) {}
        }
        pendingFutures.clear();
        chunkTempPaths.clear();
        chunkWriteOffsets.clear();
        // 让出事件循环，防止 UI 线程饥饿
        await Future.delayed(Duration.zero);
      }
    }

    // 6. 处理剩余的块
    if (pendingFutures.isNotEmpty) {
      await Future.wait(pendingFutures);
      await _writeBatchToOutput(chunkTempPaths, chunkWriteOffsets, outputPath);
      for (final p in chunkTempPaths) {
        try { await File(p).delete(); } catch (_) {}
      }
    }

    onProgress?.call(1.0);
  }

  /// 将一批临时块文件按各自偏移写入输出文件
  static Future<void> _writeBatchToOutput(
    List<String> tempPaths,
    List<int> writeOffsets,
    String outputPath,
  ) async {
    final outputRaf = File(outputPath).openSync(mode: FileMode.writeOnlyAppend);
    try {
      final copyBuf = Uint8List(bufferSize);
      for (int i = 0; i < tempPaths.length; i++) {
        final chunkFile = File(tempPaths[i]);
        final raf = chunkFile.openSync(mode: FileMode.read);
        try {
          outputRaf.setPositionSync(writeOffsets[i]);
          int bytesRead;
          do {
            bytesRead = raf.readIntoSync(copyBuf);
            if (bytesRead > 0) {
              outputRaf.writeFromSync(copyBuf, 0, bytesRead);
            }
          } while (bytesRead == bufferSize);
        } finally {
          raf.closeSync();
        }
      }
    } finally {
      outputRaf.closeSync();
    }
  }

  /// 确定分块数
  static int _getChunkCount(int cipherDataSize) {
    if (cipherDataSize >= parallelDecryptLargeFileSize) {
      return parallelDecryptLargeIsolates; // >512MB: 8 路
    }
    if (cipherDataSize >= parallelDecryptMidFileSize) {
      return parallelDecryptMaxIsolates;  // 256-512MB: 4 路
    }
    return parallelDecryptMidIsolates;    // 64-256MB: 2 路
  }

  /// 启动单个块解密 Isolate
  static Future<void> _spawnChunkIsolate({
    required String inputPath,
    required String outputPath,
    required int startOffset,
    required int chunkLength,
    required int writeOffset,
    required String keyBase64,
    required String ivBase64,
    required int chunkIndex,
    required int totalChunks,
    void Function(double)? onProgress,
  }) async {
    final completer = Completer<void>();

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
            final globalProgress =
                (chunkIndex + value) / totalChunks;
            onProgress(globalProgress);
          }
        } else if (type == 'done') {
          if (!completer.isCompleted) {
            completer.complete();
          }
        } else if (type == 'error') {
          final message = event['message'] as String? ?? 'Unknown error';
          if (!completer.isCompleted) {
            completer.completeError(Exception(
                'Chunk $chunkIndex/$totalChunks 解密失败: $message'));
          }
        }
      }
    });

    try {
      workerSendPort.send({
        'command': 'decrypt_chunk',
        'inputPath': inputPath,
        'outputPath': outputPath,
        'startOffset': startOffset,
        'chunkLength': chunkLength,
        'writeOffset': writeOffset,
        'keyBase64': keyBase64,
        'ivBase64': ivBase64,
        'chunkIndex': chunkIndex,
        'totalChunks': totalChunks,
        'progressPort': progressPort.sendPort,
      });

      await completer.future.timeout(_isolateTimeout, onTimeout: () {
        throw TimeoutException(
            '块 $chunkIndex/$totalChunks 解密超时 (${_isolateTimeout.inSeconds}s)');
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

  /// 创建 AES-256-CTR cipher 并初始化
  static StreamCipher _createCipher(Uint8List key, Uint8List iv) {
    return CryptoUtils.createCtrCipher(key, iv);
  }

  /// 处理一个 CTR 块（原地加解密，因为 CTR 是异或流）
  static void _processCtrBlock(
    StreamCipher cipher,
    Uint8List input,
    Uint8List output,
    int length, {
    int dstOffset = 0,
  }) {
    // 使用 PointyCastle 原生批量 API，一次性处理整个缓冲区
    // 相比逐字节调用 returnByte()，吞吐量提升 100-1000 倍
    cipher.processBytes(input, 0, length, output, dstOffset);
  }

  /// 生成加密安全的随机字节
  static Uint8List _generateRandomBytes(int length) {
    return CryptoUtils.generateRandomBytes(length);
  }

  // --- 密钥缓存 ---

  /// PBKDF2 派生密钥缓存，以 salt 的 base64 编码为 key
  /// 密码固定，相同 salt 的密钥可复用，避免重复的 100K 迭代开销
  /// LRU 上限 100 条（32B × 100 = 3.2KB，可忽略不计）
  static final Map<String, Uint8List> _keyCache = {};
  static const int _maxKeyCacheSize = 100;

  static void _addToCache(String key, Uint8List value) {
    if (_keyCache.length >= _maxKeyCacheSize) {
      // 删除最早插入的条目（Dart Map 保持插入顺序）
      _keyCache.remove(_keyCache.keys.first);
    }
    _keyCache[key] = value;
  }
}
