---
name: crypto-v2-upgrade
overview: 将加密格式从 v1 升级到 v2：1) PBKDF2 迭代次数从 100000 降到 10000；2) 文件头偏移 32 处写入版本字节 0x02；3) 解密时校验版本号，非 0x02 拒绝解密。
todos:
  - id: update-crypto-constants
    content: 修改 lib/config/crypto.dart：pbkdf2Iterations 改为 10000，reservedSize 改为 31，新增 versionByte=0x02 和 versionOffset=32 常量
    status: completed
  - id: update-isolate-worker
    content: 修改 lib/services/crypto_isolate.dart：_encryptFileInIsolate 写入版本号字节，_decryptFileInIsolate 和 _decryptFilePartialInIsolate 增加版本号校验
    status: completed
    dependencies:
      - update-crypto-constants
  - id: update-crypto-service
    content: 修改 lib/services/crypto_service.dart：encryptBytes 写入版本号，decryptBytes 和 _runParallelDecrypt 增加版本号校验
    status: completed
    dependencies:
      - update-crypto-constants
  - id: create-format-doc
    content: 创建 docs/encrypted-file-format.md：填充完整的 v2 加密格式说明文档（文件头结构、密钥派生、解密流程、各语言示例）
    status: completed
  - id: update-architecture-doc
    content: 更新 docs/snplayer-architecture-guide.md：将 PBKDF2 迭代次数从"10万次"改为"1万次"，文件头描述更新为 v2 结构
    status: completed
    dependencies:
      - update-crypto-constants
---

## 用户需求

将 SnPlayer Flutter 项目的加解密文件格式从 v1 升级到 v2，对齐 SN Video Editor 的最新加密规范。

## 核心变更

1. **PBKDF2 迭代次数降低**：从 100,000 次降至 10,000 次，大幅缩短密钥派生耗时（约 10 倍）
2. **文件头结构变更**：64 字节头部从 `16 IV + 16 Salt + 32 保留（全零）` 改为 `16 IV + 16 Salt + 1 版本号(0x02) + 31 保留（全零）`
3. **解密时强制校验版本号**：偏移 32 处的字节必须为 `0x02`，否则拒绝解密并抛出明确的格式错误

## 影响范围

- **加密文件输出**：epub 头部写入版本号 0x02
- **解密文件输入**：读取头部后校验版本号，非 0x02 立即拒绝
- **内存加解密**（缩略图场景）：同步更新格式
- **并行解密**：校验版本号
- **常量配置**：新增版本号常量，修改迭代次数和保留区长度

## 技术方案

### 变更策略

采用**最小侵入、逐点修改**的方式。由于 v1 和 v2 文件头仅有 1 字节差异（偏移 32 从保留零值变为版本号），且所有加解密入口集中在 4 个文件内，改动范围可控。

### 修改文件清单

#### 1. `lib/config/crypto.dart` — 常量层

| 常量 | 旧值 | 新值 |
| --- | --- | --- |
| `pbkdf2Iterations` | 100000 | 10000 |
| `reservedSize` | 32 | 31 |
| （新增）`versionByte` | — | `0x02` |
| （新增）`versionOffset` | — | `32` |


#### 2. `lib/services/crypto_isolate.dart` — Isolate Worker 层

- **`_encryptFileInIsolate()`** — `headerBuilder` 闭包中，在写完 IV+Salt 后追加：`header[versionOffset] = versionByte`
- **`_decryptFileInIsolate()`** — 读取头后新增：`if (header[versionOffset] != versionByte) throw FormatException(...)`
- **`_decryptFilePartialInIsolate()`** — 同上，新增版本校验

#### 3. `lib/services/crypto_service.dart` — 调度层

- **`encryptBytes()`** — `encrypted.setAll()` 写入 IV+Salt 后追加：`encrypted[versionOffset] = versionByte`
- **`decryptBytes()`** — 提取 IV/Salt 后新增：`if (encrypted[versionOffset] != versionByte) throw FormatException(...)`
- **`_runParallelDecrypt()`** — 读取 64 字节头部后，在派生密钥前新增版本校验

#### 4. `lib/utils/crypto_utils.dart`

**无需修改**。`deriveKeyFromPassword()` 通过引用 `pbkdf2Iterations` 常量自动适配新的迭代次数。

### 错误处理规范

版本校验失败抛出 `FormatException`，消息示例：`"不支持的加密格式版本: 0x01，当前仅支持 v2 (0x02)。请使用最新版 MewTool 重新加密该文件。"`

### 兼容性说明

- **加密**：此后所有加密输出均为 v2 格式
- **解密**：仅接受 v2 格式，旧的 v1 `.enc` 文件解密时会明确报错，提示用户用新工具重新加密
- **不提供 v1 兼容读取**：按用户要求，v2 拒绝 v1 格式，不搞双版本兼容

### 性能影响

PBKDF2 从 100K 迭代降至 10K，密钥派生耗时约缩减 10 倍（典型设备从 ~200ms 降至 ~20ms），对加解密启动速度有正向提升。