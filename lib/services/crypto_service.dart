// lib/services/crypto_service.dart — AES-256-CTR 加解密核心服务（串行/并行分流、密钥缓存、内存数据加解密）

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
import 'parallel_crypto_scheduler.dart';
import 'playback_cache_manager.dart';

/// AES-256-CTR 加密/解密核心服务
///
/// 兼容 MewTool .enc 文件格式（64 字节文件头：IV + Salt + 保留字段）
/// 采用 PBKDF2-HMAC-SHA256 密钥派生 + AES-256-CTR 流式加密
/// 4MB 双缓冲流水线，I/O 与 CPU 计算重叠
/// 大文件（≥64MB）自动启用 2-6 路并行分块加解密（ParallelCryptoScheduler）
class CryptoService {
  /// Isolate 最大运行时间（5 分钟），超时后强制终止
  static const Duration _isolateTimeout = Duration(minutes: 5);

  /// 部分解密超时（30 秒），30MB 部分解密通常 1-3 秒内完成
  static const Duration _partialTimeout = Duration(seconds: 30);

  /// 从固定密码和指定盐值派生 32 字节 AES 密钥
  /// 密码固定，以 salt 的 base64 编码作为缓存 key，避免重复的 10 次迭代开销
  static Uint8List deriveKey(Uint8List passwordBytes, Uint8List salt) {
    final cacheKey = base64.encode(salt);
    // 命中时 remove + 重插到末尾，实现真 LRU（仅插入序淘汰是 FIFO）
    final cached = _keyCache.remove(cacheKey);
    if (cached != null) {
      _keyCache[cacheKey] = cached;
      return cached;
    }

    final key = CryptoUtils.deriveKeyFromPassword(passwordBytes, salt);
    _addToCache(cacheKey, key);
    return key;
  }

  /// 加密文件（自动根据文件大小选择串行/并行路径）
  ///
  /// - 文件 < 64MB：单 Isolate 串行加密，避免 Isolate 启动开销 > 并行收益
  /// - 文件 >= 64MB：多 Isolate 并行分块加密，2-6 路并行提速
  ///
  /// [inputPath] 原始视频文件路径
  /// [outputPath] 加密输出路径（.enc）
  /// [onProgress] 进度回调，参数为 0.0 ~ 1.0
  static Future<void> encryptFile(
    String inputPath,
    String outputPath, {
    void Function(double)? onProgress,
  }) async {
    final fileSize = await File(inputPath).length();
    if (fileSize >= parallelDecryptMinFileSize) {
      await _encryptParallel(inputPath, outputPath,
          fileSize: fileSize, onProgress: onProgress);
    } else {
      await _runInIsolate(
        command: 'encrypt',
        inputPath: inputPath,
        outputPath: outputPath,
        onProgress: onProgress,
      );
    }
  }

  /// 解密文件（自动根据文件大小选择串行/并行路径）
  ///
  /// - 文件 < 64MB：单 Isolate 串行解密
  /// - 文件 >= 64MB：多 Isolate 并行分块解密，2-6 路并行提速
  ///
  /// [inputPath] 加密文件路径（.enc）
  /// [outputPath] 解密输出路径
  /// [onProgress] 进度回调，参数为 0.0 ~ 1.0
  static Future<void> decryptFile(
    String inputPath,
    String outputPath, {
    void Function(double)? onProgress,
  }) async {
    final fileSize = await File(inputPath).length();
    if (fileSize >= parallelDecryptMinFileSize) {
      await _decryptParallel(inputPath, outputPath, onProgress: onProgress);
    } else {
      await _runInIsolate(
        command: 'decrypt',
        inputPath: inputPath,
        outputPath: outputPath,
        onProgress: onProgress,
      );
    }
  }

  /// 解密到播放缓存文件，返回缓存文件路径
  ///
  /// 命名规则由 [PlaybackCacheManager.getCacheFilePath] 统一维护，缓存可直接命中。
  static Future<String> decryptToTemp(
    String encPath,
    String cacheDir, {
    void Function(double)? onProgress,
  }) async {
    final tempPath = PlaybackCacheManager.getCacheFilePath(encPath, cacheDir);

    // 确保缓存目录存在
    await Directory(cacheDir).create(recursive: true);

    // 先解密到 .decrypting.tmp，完成后原子 rename 到最终名：
    // 直接写最终名时，预分配/半写入的文件大小和头部内容都会通过
    // PlaybackCacheManager 的缓存校验，半成品会被当作有效缓存播放（TOCTOU）。
    // tmp 名含微秒时间戳：快速退出/重进同一视频时两个解密任务并发，
    // 固定名会导致互写同一 tmp、后完成者 rename 因源文件消失而报错
    final decryptingPath =
        '$tempPath.${DateTime.now().microsecondsSinceEpoch}.decrypting.tmp';
    try {
      await decryptFile(encPath, decryptingPath, onProgress: onProgress);
      await File(decryptingPath).rename(tempPath);
    } catch (e) {
      // 并发赢家容忍：若目标缓存已存在且大小等于期望解密大小，
      // 说明并发的另一任务已产出有效缓存，删除自身 tmp 后正常返回
      if (await _isCompleteCacheFile(encPath, tempPath)) {
        try {
          await File(decryptingPath).delete();
        } catch (_) {
          // 忽略：孤儿 tmp 由启动清理回收
        }
        return tempPath;
      }
      // 失败只清理自己的 .tmp，不触碰可能存在的有效缓存
      try {
        await File(decryptingPath).delete();
      } catch (_) {
        // 忽略：临时文件可能未创建
      }
      rethrow;
    }

    // 写后容量执行：500MB 上限从"每次冷启动执行一次"变为"每次写入后执行"，
    // 豁免刚产出的文件防止自删（即将被播放）
    unawaited(PlaybackCacheManager.cleanupOversizedCache(
      cacheDir,
      exemptPath: tempPath,
    ));

    return tempPath;
  }

  /// 校验既有缓存文件大小是否等于期望解密大小（并发赢家判定）
  static Future<bool> _isCompleteCacheFile(String encPath, String cachePath) async {
    try {
      final cacheFile = File(cachePath);
      if (!await cacheFile.exists()) {
        return false;
      }
      final expected = await File(encPath).length() - headerSize;
      return await cacheFile.length() == expected;
    } catch (_) {
      return false;
    }
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

    await _spawnAndManageIsolate(
      message: {
        'command': 'decrypt_partial',
        'inputPath': encPath,
        'outputPath': tempPath,
        'password': defaultPassword,
        'maxBytes': maxBytes,
      },
      timeout: _partialTimeout,
    );
    return tempPath;
  }

  /// 读取加密文件元信息（IV + 派生密钥 + 解密后大小）
  ///
  /// 供 [StreamingDecryptProxy] 初始化使用，一次性读取文件头并派生密钥。
  /// 密钥派生走 [deriveKey] 缓存，相同 salt 的重复调用 O(1)。
  static Future<EncryptedFileInfo> getEncryptedFileInfo(String encPath) async {
    final raf = await File(encPath).open(mode: FileMode.read);
    final header = Uint8List(headerSize);
    int headerBytesRead;
    int encFileSize;
    try {
      headerBytesRead = await raf.readInto(header, 0, headerSize);
      encFileSize = await raf.length();
    } finally {
      await raf.close();
    }

    // 解析并校验文件头（长度 + 版本），获取 IV/Salt
    final headerInfo = CryptoUtils.parseEncHeader(header, headerBytesRead);

    final passwordBytes = Uint8List.fromList(utf8.encode(defaultPassword));
    final key = deriveKey(passwordBytes, headerInfo.salt);

    return EncryptedFileInfo(
      iv: Uint8List.fromList(headerInfo.iv),
      key: key,
      decryptedSize: encFileSize - headerSize,
    );
  }

  /// 加密数据块（用于缩略图等内存数据）
  static Future<Uint8List> encryptBytes(Uint8List data) async {
    final passwordBytes = Uint8List.fromList(utf8.encode(defaultPassword));
    final iv = CryptoUtils.generateRandomBytes(ivLength);
    final salt = CryptoUtils.generateRandomBytes(saltLength);

    final key = deriveKey(passwordBytes, salt);
    final cipher = CryptoUtils.createCtrCipher(key, iv);

    final encrypted = Uint8List(headerSize + data.length);
    encrypted.setAll(0, CryptoUtils.buildEncHeader(iv, salt));

    _processCtrBlock(cipher, data, encrypted, data.length,
        dstOffset: headerSize);

    return encrypted;
  }

  /// 解密数据块（用于缩略图等内存数据）
  static Uint8List decryptBytes(Uint8List encrypted) {
    if (encrypted.length < headerSize) {
      throw const FormatException('加密数据损坏或不完整：不足 64 字节文件头');
    }

    // 解析并校验文件头（版本），获取 IV/Salt
    final headerInfo = CryptoUtils.parseEncHeader(
        Uint8List.sublistView(encrypted, 0, headerSize), headerSize);

    final passwordBytes = Uint8List.fromList(utf8.encode(defaultPassword));
    final key = deriveKey(passwordBytes, headerInfo.salt);
    final cipher = CryptoUtils.createCtrCipher(key, headerInfo.iv);

    final data = encrypted.sublist(headerSize);
    final decrypted = Uint8List(data.length);

    _processCtrBlock(cipher, data, decrypted, data.length);

    return decrypted;
  }

  // --- 并行路径（委托 ParallelCryptoScheduler） ---

  /// 并行分块加密：生成 IV/Salt → 派生密钥 → 构建文件头 → 交给调度器
  static Future<void> _encryptParallel(
    String inputPath,
    String outputPath, {
    required int fileSize,
    void Function(double)? onProgress,
  }) async {
    final passwordBytes = Uint8List.fromList(utf8.encode(defaultPassword));
    final iv = CryptoUtils.generateRandomBytes(ivLength);
    final salt = CryptoUtils.generateRandomBytes(saltLength);
    final key = deriveKey(passwordBytes, salt);

    await ParallelCryptoScheduler.run(
      isEncrypt: true,
      inputPath: inputPath,
      outputPath: outputPath,
      key: key,
      iv: iv,
      header: CryptoUtils.buildEncHeader(iv, salt),
      dataSize: fileSize,
      onProgress: onProgress,
    );
  }

  /// 并行分块解密：读取文件头派生密钥 → 交给调度器
  static Future<void> _decryptParallel(
    String inputPath,
    String outputPath, {
    void Function(double)? onProgress,
  }) async {
    final info = await getEncryptedFileInfo(inputPath);

    await ParallelCryptoScheduler.run(
      isEncrypt: false,
      inputPath: inputPath,
      outputPath: outputPath,
      key: info.key,
      iv: info.iv,
      header: null,
      dataSize: info.decryptedSize,
      onProgress: onProgress,
    );
  }

  // --- 单 Isolate 串行路径 ---

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

  // --- 工具 ---

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

  // --- 密钥缓存 ---

  /// PBKDF2 派生密钥缓存，以 salt 的 base64 编码为 key
  /// 密码固定，相同 salt 的密钥可复用，避免重复的 10 次迭代开销
  /// LRU 上限 100 条（32B × 100 = 3.2KB，可忽略不计）
  static final Map<String, Uint8List> _keyCache = {};
  static const int _maxKeyCacheSize = 100;

  static void _addToCache(String key, Uint8List value) {
    if (_keyCache.length >= _maxKeyCacheSize) {
      // 删除最久未访问的条目（get 命中会重插到末尾，头部即最旧）
      _keyCache.remove(_keyCache.keys.first);
    }
    _keyCache[key] = value;
  }
}

/// 加密文件元信息（代理初始化时一次性读取）
class EncryptedFileInfo {
  final Uint8List iv;
  final Uint8List key;
  final int decryptedSize;

  const EncryptedFileInfo({
    required this.iv,
    required this.key,
    required this.decryptedSize,
  });
}
