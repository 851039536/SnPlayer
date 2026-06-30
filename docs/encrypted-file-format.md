# SN Video Editor 加密文件解密指南

> 本文档面向需要在第三方程序中解密 SN Video Editor 加密文件（`.enc`）的开发者。
>
> **当前格式版本：v2（0x02）** ，PBKDF2 迭代 10,000 次。

## 一、加密格式总览

|项|值|
| ----------------| -------------------------------------|
|加密算法|AES-256-CTR（计数器模式）|
|密钥派生|PBKDF2-HMAC-SHA256，**1 万次迭代**|
|派生密钥长度|32 字节（256 位）|
|IV 长度|16 字节（128 位），每次加密随机生成|
|Salt 长度|16 字节（128 位），每次加密随机生成|
|格式版本|`0x02`（v2）|
|文件头长度|64 字节|
|密文起始偏移|第 65 字节起（跳过头部）|
|加密文件扩展名|`.enc`|

## 二、文件头结构（64 字节）

```
偏移量    长度    内容
──────    ────    ────────────
 0        16      IV（初始化向量）
16        16      Salt（PBKDF2 盐值）
32        1       格式版本号（0x02 = v2）
33        31      保留（全 0 填充）
```

> 解密时需从头部提取 IV（偏移 0\~15）、Salt（偏移 16\~31）和版本号（偏移 32）。偏移 33\~63 的 31 字节保留区域忽略即可。版本号必须为 `0x02`，否则应拒绝解密。

## 三、密钥派生

```
PBKDF2(
  password   = "SN-Video-Editor-2026-Default-Key!",   // 默认密码
  salt       = <从文件头偏移 16 处读取的 16 字节>,
  iterations = 10000,                                   // v2: 1 万次迭代
  keyLen     = 32,                                      // 256 位
  digest     = SHA-256
)
```

输出 32 字节密钥用于 AES-256-CTR 解密。

### 默认密码

```
SN-Video-Editor-2026-Default-Key!
```

> ⚠️ 如果你自行修改了加密密码，请使用你自定义的密钥。

## 四、解密流程（伪代码）

```
1. 打开 .enc 文件
2. 读取前 64 字节头部
3. 提取 IV = header[0:16]
4. 提取 Salt = header[16:32]
5. 检查版本号 header[32] == 0x02，不匹配则拒绝
6. 使用 PBKDF2(password, Salt, 10000, SHA-256) 派生 32 字节 Key
7. 创建 AES-256-CTR 解密器（Key, IV）
8. 从文件偏移 64 处开始读取密文
9. 通过解密器解密，写入输出文件
```

## 各语言解密示例

### C# (.NET)

```csharp
using System.Security.Cryptography;

const int HeaderLength = 64;
const string DefaultPassword = "SN-Video-Editor-2026-Default-Key!";

static void DecryptFile(string inputPath, string outputPath)
{
    var fileInfo = new FileInfo(inputPath);
    if (fileInfo.Length < HeaderLength)
        throw new InvalidDataException("文件太小，不含加密头");

    // 读取头部
    byte[] header = new byte[HeaderLength];
    using (var fs = File.OpenRead(inputPath))
    {
        fs.Read(header, 0, HeaderLength);
    }

    // 提取 IV 和 Salt
    byte[] iv = header[0..16];
    byte[] salt = header[16..32];
    byte version = header[32];

    if (version != 0x02)
        throw new InvalidDataException($"不支持的格式版本: 0x{version:x2}");

    // PBKDF2 派生密钥 (v2: 1 万次迭代)
    using var pbkdf2 = new Rfc2898DeriveBytes(
        DefaultPassword,
        salt,
        10000,
        HashAlgorithmName.SHA256
    );
    byte[] key = pbkdf2.GetBytes(32);

    // 注意：.NET 的 Aes 类不直接支持 CTR 模式，需要手动实现。
    // 参见下方"CTR 模式手动实现"。
}
```

### Node.js

```javascript
const crypto = require('crypto');
const fs = require('fs');

const DEFAULT_PASSWORD = 'SN-Video-Editor-2026-Default-Key!';
const HEADER_SIZE = 64;

function decryptFile(inputPath, outputPath) {
    const fd = fs.openSync(inputPath, 'r');
    const header = Buffer.alloc(HEADER_SIZE);
    fs.readSync(fd, header, 0, HEADER_SIZE, 0);

    const iv = header.subarray(0, 16);
    const salt = header.subarray(16, 32);
    const version = header[32];

    if (version !== 0x02) {
        throw new Error(`不支持的格式版本: 0x${version.toString(16)}`);
    }

    // PBKDF2 派生密钥
    const key = crypto.pbkdf2Sync(DEFAULT_PASSWORD, salt, 10000, 32, 'sha256');

    // AES-256-CTR 解密
    const fileSize = fs.fstatSync(fd).size;
    const cipherDataSize = fileSize - HEADER_SIZE;
    const input = Buffer.alloc(cipherDataSize);
    fs.readSync(fd, input, 0, cipherDataSize, HEADER_SIZE);
    fs.closeSync(fd);

    const decipher = crypto.createDecipheriv('aes-256-ctr', key, iv);
    const output = Buffer.concat([decipher.update(input), decipher.final()]);
    fs.writeFileSync(outputPath, output);
}

decryptFile('video.mp4.enc', 'video.mp4');
```

### Python

```python
import os
import hashlib
from Crypto.Cipher import AES
from Crypto.Protocol.KDF import PBKDF2

DEFAULT_PASSWORD = b'SN-Video-Editor-2026-Default-Key!'
HEADER_SIZE = 64

def decrypt_file(input_path, output_path):
    with open(input_path, 'rb') as f:
        if os.path.getsize(input_path) < HEADER_SIZE:
            raise ValueError('文件太小，不含加密头')

        header = f.read(HEADER_SIZE)
        iv = header[0:16]
        salt = header[16:32]
        version = header[32]

        if version != 0x02:
            raise ValueError(f'不支持的格式版本: 0x{version:02x}')

        # PBKDF2 派生密钥
        key = PBKDF2(DEFAULT_PASSWORD, salt, dkLen=32, count=10000,
                     hmac_hash_module=hashlib.sha256)

        # AES-256-CTR 解密
        cipher = AES.new(key, AES.MODE_CTR, nonce=b'', initial_value=iv)
        ciphertext = f.read()
        plaintext = cipher.decrypt(ciphertext)

    with open(output_path, 'wb') as f:
        f.write(plaintext)

decrypt_file('video.mp4.enc', 'video.mp4')
```

### OpenSSL

```bash
# 1. 提取 IV（前 16 字节）
dd if=input.enc bs=16 count=1 of=iv.bin 2>/dev/null

# 2. 提取 Salt（偏移 16，16 字节）
dd if=input.enc bs=16 skip=1 count=1 of=salt.bin 2>/dev/null

# 3. 提取密文（跳过 64 字节头部）
dd if=input.enc bs=64 skip=1 of=cipher.bin 2>/dev/null

# 4. 解密（OpenSSL 不直接支持从文件头读取 salt，需手动派生密钥后传入）
# 参见代码示例中的 PBKDF2 派生，然后将 hex key + iv 传入：
openssl enc -d -aes-256-ctr -K <hex_key> -iv $(xxd -p iv.bin) -in cipher.bin -out output.mp4
```

## 五、CTR 模式手动实现要点

如果你的语言/库不原生支持 AES-256-CTR，可手动实现 CTR 模式：

```
CTR 加解密逻辑（加密和解密完全相同）：

counter = IV (16 bytes, big-endian integer)
key = PBKDF2(password, salt, 10000, SHA-256) → 32 bytes

for each 16-byte block of plaintext:
    keystream = AES_ECB_encrypt(key, counter)   // 加密 counter 生成密钥流
    ciphertext = plaintext XOR keystream[0:block_length]
    counter = counter + 1                         // 计数器递增

注意：解密时做完全相同的操作（CTR 模式下加密和解密对称）。
```

## 六、文件命名约定

|操作|输入|输出|
| ------| ------| ------|
|加密|`video.mp4`|`video.mp4.enc`|
|解密|`video.mp4.enc`|`video.mp4`|

加密后的文件在原文件名基础上追加 `.enc` 后缀，解密时去除 `.enc` 后缀还原。

## 七、注意事项

1. **密码正确性**：解密不会主动校验密码是否正确。如果密码错误，解密器会在中途抛出异常（因为 AES-CTR 密钥流不匹配导致解密结果无意义，但不会在开头就检测到）。
2. **Salt 唯一性**：每次加密都会生成新的随机 16 字节 Salt，因此同一文件用相同密码加密两次，密文完全不同。
3. **IV 唯一性**：每次加密生成新的随机 16 字节 IV，确保相同明文加密后密文不同。
4. **流式处理**：使用 64KB 块大小进行流式加解密，支持超大文件，无需将整个文件加载到内存。
