---
name: force-serial-encryption
overview: 将 CryptoService.encryptFile 强制改为始终使用串行单 Isolate 加密，跳过并行路径。
todos:
  - id: force-serial-encrypt
    content: 修改 crypto_service.dart 的 encryptFile 方法，移除文件大小判断，始终走串行 Isolate 加密路径
    status: completed
---

## 用户需求

将加密路径从"自动选择并行/串行"改为"强制串行"，跳过并行加密逻辑，解决并行加密产物的版本字节为 0x00 的问题。

## 修改内容

`lib/services/crypto_service.dart` 中 `encryptFile` 方法：移除 `fileSize >= parallelDecryptMinFileSize` 的分支判断，始终调用 `_runInIsolate(command: 'encrypt', ...)`。

## 技术方案

### 改动范围

仅修改 `lib/services/crypto_service.dart` 第 40-56 行的 `encryptFile` 方法，将：

```
static Future<void> encryptFile(...) async {
    final fileSize = await File(inputPath).length();
    if (fileSize >= parallelDecryptMinFileSize) {
      await encryptFileParallel(inputPath, outputPath, onProgress: onProgress);
    } else {
      await _runInIsolate(command: 'encrypt', inputPath: inputPath, outputPath: outputPath, onProgress: onProgress);
    }
  }
```

改为：

```
static Future<void> encryptFile(...) async {
    await _runInIsolate(
      command: 'encrypt',
      inputPath: inputPath,
      outputPath: outputPath,
      onProgress: onProgress,
    );
  }
```

### 不改动的内容

- `encryptFileParallel` 方法 — 保留
- `_runParallelEncrypt` 方法 — 保留
- `_spawnEncryptChunkIsolate` 方法 — 保留
- `encryptBytes` 方法 — 不动
- 所有解密路径（`decryptFile`、`decryptFileParallel`、`decryptToTemp`）— 不动
- 配置文件 `config/crypto.dart` — 不动