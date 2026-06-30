---
name: smooth-crypto-performance
overview: 优化 AES-256-CTR 加解密性能，解决播放和导出解密卡顿问题。核心改动：批量 CTR 处理替代逐字节循环、PBKDF2 密钥缓存、Isolate 后台解密。
todos:
  - id: fix-process-ctr-block
    content: 优化 _processCtrBlock：将逐字节 returnByte() 循环改为 cipher.processBytes() 批量处理，并删除文件底部未使用的 xorBytes 函数
    status: completed
  - id: add-key-cache
    content: 在 deriveKey() 中添加基于 salt 的 PBKDF2 密钥缓存，避免相同文件的重复密钥派生
    status: completed
  - id: optimize-random-bytes
    content: 优化 _generateRandomBytes()：用更高效的字节填充方式替代逐字节循环
    status: completed
  - id: create-crypto-isolate
    content: 新建 lib/services/crypto_isolate.dart，实现 Isolate worker 顶层函数，支持通过 SendPort 报告进度的文件加解密
    status: completed
    dependencies:
      - fix-process-ctr-block
      - add-key-cache
      - optimize-random-bytes
  - id: refactor-crypto-service
    content: 重构 CryptoService.encryptFile() 和 decryptFile() 使用 Isolate.spawn 在后台执行加解密，encryptBytes/decryptBytes 保持主线程但复用已有批量优化
    status: completed
    dependencies:
      - create-crypto-isolate
  - id: cleanup-and-verify
    content: 清理 import 和删除未使用的 xorBytes 函数，运行 flutter analyze 确保无编译错误
    status: completed
    dependencies:
      - refactor-crypto-service
---

## 用户需求

SnPlayer 整体功能正常，但视频播放和导出解密操作卡顿、不丝滑。需要优化加解密性能，使播放启停流畅、导出解密响应迅速。

## 核心目标

- 播放页面进入后快速开始播放（减少等待时间）
- 导出解密过程流畅（进度条平滑更新，不卡 UI）
- 保持 .enc 文件格式完全兼容

## 技术方案

### 问题根因

项目已实现双缓冲 I/O 流水线（I/O 与 CPU 可重叠），但 CPU 侧存在严重的逐字节处理瓶颈：

- `_processCtrBlock` 对每个 512KB 块执行 524,288 次 `cipher.returnByte()` Dart 调用
- PBKDF2 100K 迭代在主线程同步执行，每次启动加解密都会冻结 UI
- 所有加解密在主线程，事件循环被长时间阻塞

### 优化策略（4 项，按优先级排列）

#### 1. CTR 批量处理（P0，最大收益）

**位置**: `lib/services/crypto_service.dart:236-248`

将 `_processCtrBlock` 中的逐字节循环：

```
for (int i = 0; i < length; i++) {
  output[dstOffset + i] = cipher.returnByte(input[i]);
}
```

改为 PointyCastle 提供的批量 API（已确认 `StreamCipher.processBytes` 存在于 pointycastle 3.9.1）：

```
cipher.processBytes(input, 0, length, output, dstOffset);
```

预期效果：每个 512KB 块从 524K 次 Dart 函数调用降为 1 次 native 调用，吞吐量提升 100-1000 倍。

#### 2. PBKDF2 密钥缓存（P1）

**位置**: `lib/services/crypto_service.dart:25-32`

密码固定（`SN-Video-Editor-2026-Default-Key!`），对相同 salt 的密钥可复用。在 `CryptoService` 中添加静态缓存 `Map<String, Uint8List> _keyCache`，以 salt 的 base64 编码为 key。`deriveKey()` 优先查缓存，miss 时才执行 100K 次 HMAC-SHA256 迭代。

#### 3. Isolate 后台加解密（P1）

**新建文件**: `lib/services/crypto_isolate.dart`

创建顶层函数 `_cryptoWorker(SendPort sendPort)` 作为 Isolate 入口。Isolate 内部执行完整的文件 I/O + 密钥派生 + CTR 处理，通过 `SendPort` 向主线程发送进度事件（`{'type': 'progress', 'value': double}`）和完成/错误事件。

`CryptoService.encryptFile()` 和 `decryptFile()` 改为使用 `Isolate.spawn()` 启动 worker，通过 `ReceivePort` 接收进度并转发给 `onProgress` 回调。公共 API 签名不变，调用方零改动。

`encryptBytes()`/`decryptBytes()`（缩略图，数据量 ~10-50KB）保持主线程执行，受益于优化 1+2 后已足够快，Isolate 开销反而更大。

#### 4. 随机数生成优化（P2）

**位置**: `lib/services/crypto_service.dart:251-257`

将 16/32 字节的逐字节 `random.nextInt(256)` 循环改为更高效的方式。影响较小但顺手优化。

### 架构不变

- `CryptoService` 公共 API 签名完全不变
- `video_player_screen.dart` / `video_list_provider.dart` / `thumbnail_service.dart` 无需任何修改
- .enc 文件格式（64B 头：16B IV + 16B Salt + 32B 保留）完全兼容