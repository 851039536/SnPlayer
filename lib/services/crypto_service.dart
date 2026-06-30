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
/// 512KB 双缓冲流水线，I/O 与 CPU 计算重叠
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

  /// 在后台 Isolate 中执行加解密，通过 SendPort 接收进度事件
  static Future<void> _runInIsolate({
    required String command,
    required String inputPath,
    required String outputPath,
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
          final message = event['message'] as String? ?? 'Unknown error';
          if (!completer.isCompleted) {
            completer.completeError(Exception(message));
          }
        }
      }
    });

    try {
      workerSendPort.send({
        'command': command,
        'inputPath': inputPath,
        'outputPath': outputPath,
        'password': defaultPassword,
        'progressPort': progressPort.sendPort,
      });

      // 添加超时机制，防止 worker 崩溃后永久挂起
      await completer.future.timeout(_isolateTimeout, onTimeout: () {
        throw TimeoutException(
            'Isolate $command 操作超时 (${_isolateTimeout.inSeconds}s): $inputPath');
      });
    } catch (e) {
      debugPrint('[SnPlayer] CryptoService._runInIsolate: $e');
      rethrow;
    } finally {
      progressPort.close();
      receivePort.close();
      // 优雅关闭：先尝试 beforeNextEvent，失败后再 immediate
      try {
        isolate.kill(priority: Isolate.beforeNextEvent);
      } catch (e) {
        debugPrint(
            '[SnPlayer] CryptoService._runInIsolate: Isolate.kill failed $e');
        isolate.kill(priority: Isolate.immediate);
      }
    }
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
    final completer = Completer<void>();

    final receivePort = ReceivePort();
    final isolate = await Isolate.spawn(cryptoWorker, receivePort.sendPort);

    final workerSendPort = await receivePort.first as SendPort;

    final progressPort = ReceivePort();
    progressPort.listen((event) {
      if (event is Map) {
        final type = event['type'] as String?;
        if (type == 'done') {
          if (!completer.isCompleted) {
            completer.complete();
          }
        } else if (type == 'error') {
          final message = event['message'] as String? ?? 'Unknown error';
          if (!completer.isCompleted) {
            completer.completeError(Exception(message));
          }
        }
      }
    });

    try {
      workerSendPort.send({
        'command': command,
        'inputPath': inputPath,
        'outputPath': outputPath,
        'password': defaultPassword,
        'progressPort': progressPort.sendPort,
        'maxBytes': maxBytes,
      });

      // 30MB 部分解密通常在 1-3 秒内完成，30 秒超时留足余量
      await completer.future.timeout(const Duration(seconds: 30), onTimeout: () {
        throw TimeoutException(
            'Isolate $command 操作超时 (30s): $inputPath');
      });
    } catch (e) {
      debugPrint('[SnPlayer] CryptoService._runPartialInIsolate: $e');
      rethrow;
    } finally {
      progressPort.close();
      receivePort.close();
      try {
        isolate.kill(priority: Isolate.beforeNextEvent);
      } catch (e) {
        debugPrint(
            '[SnPlayer] CryptoService._runPartialInIsolate: Isolate.kill failed $e');
        isolate.kill(priority: Isolate.immediate);
      }
    }
  }

  /// 解密到临时缓存文件，返回临时文件路径
  static Future<String> decryptToTemp(String encPath, String cacheDir) async {
    final fileName = p.basenameWithoutExtension(encPath);
    final tempPath = p.join(cacheDir, 'play_$fileName.mp4');

    // 确保缓存目录存在
    await Directory(cacheDir).create(recursive: true);

    await decryptFile(encPath, tempPath);
    return tempPath;
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

    _processCtrBlock(cipher, data, encrypted, data.length,
        dstOffset: headerSize);

    return encrypted;
  }

  /// 解密数据块（用于缩略图等内存数据）
  static Uint8List decryptBytes(Uint8List encrypted) {
    final passwordBytes = Uint8List.fromList(utf8.encode(defaultPassword));

    final iv = encrypted.sublist(0, ivLength);
    final salt = encrypted.sublist(saltOffset, saltOffset + saltLength);

    final key = deriveKey(passwordBytes, salt);
    final cipher = _createCipher(key, iv);

    final data = encrypted.sublist(headerSize);
    final decrypted = Uint8List(data.length);

    _processCtrBlock(cipher, data, decrypted, data.length);

    return decrypted;
  }

  // --- 内部方法 ---

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
