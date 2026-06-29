import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/key_derivators/api.dart';
import 'package:pointycastle/key_derivators/pbkdf2.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/stream/ctr.dart';

import '../config/crypto.dart';

/// AES-256-CTR 加密/解密核心服务
///
/// 兼容 MewTool .enc 文件格式（64 字节文件头：IV + Salt + 保留字段）
/// 采用 PBKDF2-HMAC-SHA256 密钥派生 + AES-256-CTR 流式加密
/// 512KB 双缓冲流水线，I/O 与 CPU 计算重叠
class CryptoService {
  /// 从固定密码和指定盐值派生 32 字节 AES 密钥
  static Uint8List deriveKey(Uint8List passwordBytes, Uint8List salt) {
    final hmac = HMac(SHA256Digest(), 64);
    final derivator = PBKDF2KeyDerivator(hmac);
    derivator.init(Pbkdf2Parameters(salt, pbkdf2Iterations, keyLength));

    final key = derivator.process(passwordBytes);
    return key;
  }

  /// 加密文件
  ///
  /// [inputPath] 原始视频文件路径
  /// [outputPath] 加密输出路径（.enc）
  /// [onProgress] 进度回调，参数为 0.0 ~ 1.0
  static Future<void> encryptFile(
    String inputPath,
    String outputPath, {
    void Function(double)? onProgress,
  }) async {
    final passwordBytes = Uint8List.fromList(utf8.encode(defaultPassword));

    // 随机生成 IV 和 Salt
    final iv = _generateRandomBytes(ivLength);
    final salt = _generateRandomBytes(saltLength);

    // 派生密钥
    final key = deriveKey(passwordBytes, salt);

    // 初始化 AES-256-CTR 加密器
    final cipher = _createCipher(key, iv);

    final inputFile = File(inputPath);
    final fileSize = await inputFile.length();
    final raf = await inputFile.open(mode: FileMode.read);
    final output = File(outputPath).openWrite();

    try {
      // 写入 64 字节文件头：IV + Salt + 保留字段
      final header = Uint8List(headerSize);
      header.setAll(0, iv);
      header.setAll(ivLength, salt);
      // bytes 32..64 默认为 0（保留字段）
      output.add(header);

      // 双缓冲 + 异步预读流水线
      final bufA = Uint8List(bufferSize);
      final bufB = Uint8List(bufferSize);
      final encBuf = Uint8List(bufferSize);

      bool useA = true;
      int totalRead = 0;

      int bytesRead = await raf.readInto(bufA);
      totalRead += bytesRead;

      while (bytesRead > 0) {
        final readBuf = useA ? bufA : bufB;
        final nextBuf = useA ? bufB : bufA;

        // 启动下一块的异步预读（与当前块加密并行）
        final pendingRead = raf.readInto(nextBuf);

        // 处理当前块：CTR 加密
        _processCtrBlock(cipher, readBuf, encBuf, bytesRead);
        output.add(encBuf.sublist(0, bytesRead));

        // 进度回调
        if (onProgress != null) {
          onProgress(totalRead / fileSize);
        }

        // 等待预读完成
        bytesRead = await pendingRead;
        totalRead += bytesRead;
        useA = !useA;
      }
    } finally {
      await output.flush();
      await output.close();
      await raf.close();
    }
  }

  /// 解密文件
  ///
  /// [inputPath] 加密文件路径（.enc）
  /// [outputPath] 解密输出路径
  /// [onProgress] 进度回调，参数为 0.0 ~ 1.0
  static Future<void> decryptFile(
    String inputPath,
    String outputPath, {
    void Function(double)? onProgress,
  }) async {
    final passwordBytes = Uint8List.fromList(utf8.encode(defaultPassword));

    final inputFile = File(inputPath);
    final fileSize = await inputFile.length();
    final raf = await inputFile.open(mode: FileMode.read);

    // 读取 64 字节文件头
    final header = Uint8List(headerSize);
    await raf.readInto(header);

    final iv = header.sublist(0, ivLength);
    final salt = header.sublist(saltOffset, saltOffset + saltLength);

    // 派生密钥
    final key = deriveKey(passwordBytes, salt);

    // 初始化解密器（CTR 模式加解密过程相同）
    final cipher = _createCipher(key, iv);

    final output = File(outputPath).openWrite();

    try {
      // 双缓冲解密流水线
      final bufA = Uint8List(bufferSize);
      final bufB = Uint8List(bufferSize);
      final decBuf = Uint8List(bufferSize);

      bool useA = true;
      int totalRead = headerSize; // 已读取文件头

      int bytesRead = await raf.readInto(bufA);
      totalRead += bytesRead;

      while (bytesRead > 0) {
        final readBuf = useA ? bufA : bufB;
        final nextBuf = useA ? bufB : bufA;

        final pendingRead = raf.readInto(nextBuf);

        _processCtrBlock(cipher, readBuf, decBuf, bytesRead);
        output.add(decBuf.sublist(0, bytesRead));

        if (onProgress != null) {
          onProgress((totalRead - bytesRead) / (fileSize - headerSize));
        }

        bytesRead = await pendingRead;
        totalRead += bytesRead;
        useA = !useA;
      }
    } finally {
      await output.flush();
      await output.close();
      await raf.close();
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

    _processCtrBlock(cipher, data, encrypted, data.length, dstOffset: headerSize);

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
    final cipher = CTRStreamCipher(AESEngine())
      ..init(
        true, // forEncryption（CTR 模式加密解密相同）
        ParametersWithIV(KeyParameter(key), iv),
      );
    return cipher;
  }

  /// 处理一个 CTR 块（原地加解密，因为 CTR 是异或流）
  static void _processCtrBlock(
    StreamCipher cipher,
    Uint8List input,
    Uint8List output,
    int length, {
    int dstOffset = 0,
  }) {
    // CTR 模式下，密钥流只依赖计数器位置，处理过程是异或运算
    // 通过 processBytes 逐个字节处理
    for (int i = 0; i < length; i++) {
      output[dstOffset + i] = cipher.returnByte(input[i]);
    }
  }

  /// 生成加密安全的随机字节
  static Uint8List _generateRandomBytes(int length) {
    final random = Random.secure();
    final bytes = Uint8List(length);
    for (int i = 0; i < length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes;
  }
}

/// 简单的 XOR 操作（用于 CTR 模式固定块大小的批量处理）
void xorBytes(Uint8List dest, Uint8List src, int length, {int destOffset = 0, int srcOffset = 0}) {
  for (int i = 0; i < length; i++) {
    dest[destOffset + i] ^= src[srcOffset + i];
  }
}
