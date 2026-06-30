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

/// 加密工具函数（纯 Dart，无 Flutter/Isolate 依赖，可安全被 Isolate 和主线程共用）
class CryptoUtils {
  /// 生成加密安全的随机字节
  static Uint8List generateRandomBytes(int length) {
    final random = Random.secure();
    final bytes = Uint8List(length);
    for (int i = 0; i < length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes;
  }

  /// 从密码和盐值派生 32 字节 AES 密钥（PBKDF2-HMAC-SHA256）
  static Uint8List deriveKeyFromPassword(Uint8List passwordBytes, Uint8List salt) {
    final hmac = HMac(SHA256Digest(), 64);
    final derivator = PBKDF2KeyDerivator(hmac);
    derivator.init(Pbkdf2Parameters(salt, pbkdf2Iterations, keyLength));

    return derivator.process(passwordBytes);
  }

  /// 创建 AES-256-CTR cipher 并初始化
  static StreamCipher createCtrCipher(Uint8List key, Uint8List iv) {
    final cipher = CTRStreamCipher(AESEngine())
      ..init(
        true, // forEncryption（CTR 模式加密解密相同）
        ParametersWithIV(KeyParameter(key), iv),
      );
    return cipher;
  }

  /// 将 16 字节 IV 视为 big-endian 无符号整数，加上 [increment] 后返回新的 IV
  ///
  /// CTR 模式下，PointyCastle 将 16 字节 IV 整体作为 big-endian counter，
  /// 每处理一个 16 字节块 counter 自增 1。
  /// 因此字节偏移为 S 的数据块，其起始 counter = original_iv + (S / 16)。
  ///
  /// [increment] 应为块序号（byteOffset / 16），而非字节偏移量。
  static Uint8List incrementCounter(Uint8List iv, int increment) {
    if (increment <= 0) {
      return Uint8List.fromList(iv);
    }

    final result = Uint8List.fromList(iv);
    int carry = increment;

    // 从最低有效字节（索引 15）向最高有效字节（索引 0）进位
    for (int i = 15; i >= 0 && carry > 0; i--) {
      final sum = result[i] + carry;
      result[i] = sum & 0xFF;
      carry = sum >> 8;
    }

    return result;
  }
}
