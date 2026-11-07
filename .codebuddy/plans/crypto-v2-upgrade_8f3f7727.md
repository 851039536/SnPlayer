---
name: crypto-v2-upgrade
overview: 将加密格式从 v1 升级到 v2 并最终统一 PBKDF2 10 次迭代；2026-11-07 完成 APP 加密/导出原子写入、双方联动规则与文档统一。
todos:
  - id: update-crypto-constants
    content: 修改 lib/config/crypto.dart：pbkdf2Iterations 最终统一为 10，reservedSize 改为 31，新增 versionByte=0x02 和 versionOffset=32 常量
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
    content: 更新 docs/snplayer-architecture-guide.md：迭代次数与文件头描述同步为当前 v2/10 次结构
    status: completed
    dependencies:
      - update-crypto-constants
  - id: app-atomic-write
    content: encryptVideos / decryptAndExport 改为临时文件 + 原子 rename，失败/取消清理
    status: completed
  - id: linkage-rules
    content: AGENTS.md 加入桌面端 GitHub 地址、共享加密契约、同步要求与联动验收清单
    status: completed
  - id: docs-sync
    content: 双方 encrypted-file-format.md 统一为 10 次迭代，并补充仓库地址
    status: completed
  - id: p2-p3
    content: APP 端用户可取消加解密、桌面预览/播放 Range 流式解密等 P2/P3 项
    status: pending
---

## 用户需求

将 SnPlayer Flutter 项目的加解密文件格式从 v1 升级到 v2，并与桌面端 **snVideoEditor** 保持双向兼容：

- 桌面端加密 → APP 解密播放/导出；
- APP 加密项目 → 桌面端解密播放；
- 不改变字节级格式契约。

## 2026-11-07 后续更新（当前状态）

- **迭代次数最终为 10 次**：v2 初始方案为 10,000 次，后为与桌面端当前代码统一，固定为 **10 次**；`lib/config/crypto.dart` 与双方文档已同步。
- **原子写入**：`encryptVideos` / `decryptAndExport` 先写带微秒时间戳的 `.tmp`，成功后原子 `rename`，失败/取消清理，避免半成品。
- **联动规则**：两个仓库的 AGENTS.md（桌面端还含 CODEBUDDY.md）已写入 GitHub 地址、共享契约与联动验收清单。
- **文档同步**：双方 `docs/encrypted-file-format.md` 统一为 10 次；APP 架构文档修正 Salt 长度与头部布局；MewTool 历史文档保留 100,000 并加注说明。
- **验证状态**：APP 端未运行 `flutter analyze` 与设备回归（当前环境无 Flutter/Dart），需本地补验。
- **剩余 P2/P3**：APP 用户可取消操作、桌面预览/播放 Range 流式解密、桌面并行加密等。

## 核心变更

1. **PBKDF2 迭代次数**：从 100,000 次降至 **10 次**（固定内置密码场景；早期 v2 曾使用 10,000 次）
2. **文件头结构变更**：64 字节头部从 `16 IV + 16 Salt + 32 保留（全零）` 改为 `16 IV + 16 Salt + 1 版本号(0x02) + 31 保留（全零）`
3. **解密时强制校验版本号**：偏移 32 处的字节必须为 `0x02`，否则拒绝解密并抛出明确的格式错误

## 影响范围

- **加密文件输出**：文件头写入版本号 0x02
- **解密文件输入**：读取头部后校验版本号，非 0x02 立即拒绝
- **内存加解密**（缩略图场景）：同步更新格式
- **并行解密**：校验版本号
- **常量配置**：新增版本号常量，修改迭代次数和保留区长度

## 技术方案

### 变更策略

采用**最小侵入、逐点修改**的方式。由于 v1 和 v2 文件头仅有 1 字节差异（偏移 32 从保留零值变为版本号），且所有加解密入口集中在 4 个文件内，改动范围可控。

### 修改文件清单

#### 1. `lib/config/crypto.dart` — 常量层

| 常量 | 旧值 | 当前值 |
| --- | --- | --- |
| `pbkdf2Iterations` | 100000 | 10（v2 初版曾为 10000） |
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

#### 5. `lib/providers/video_list_provider.dart` — 2026-11-07 新增

- `encryptVideos()`：先加密到 `.tmp`，成功后 `rename` 到 `.enc`；失败删除 `.tmp`。
- `decryptAndExport()`：先解密到 `.tmp`，成功后 `rename` 到导出路径；失败删除 `.tmp`，不破坏已有导出文件。

### 错误处理规范

版本校验失败抛出 `FormatException`，消息示例：`"不支持的加密格式版本: 0x01，当前仅支持 v2 (0x02)。请使用最新版 MewTool 重新加密该文件。"`

### 兼容性说明

- **加密**：此后所有加密输出均为 v2 格式
- **解密**：仅接受 v2 格式，旧的 v1 `.enc` 文件解密时会明确报错，提示用户用新工具重新加密
- **不提供 v1 兼容读取**：按用户要求，v2 拒绝 v1 格式，不搞双版本兼容

### 性能影响

PBKDF2 从 100K 迭代降至 10 次，密钥派生耗时大幅缩短（桌面端实测约 48ms → 0.13ms；手机端预计降至 10ms 以内，需设备实测）。AES-CTR 流式吞吐不变，工程优化重点转向 I/O、取消与原子写入。

## 跨项目联动地址

| 项目 | GitHub | 本地路径 |
| --- | --- | --- |
| APP SnPlayer | https://github.com/851039536/SnPlayer | `E:\demo\app\sn-player` |
| 桌面端 snVideoEditor | https://github.com/851039536/snVideoEditor | `E:\demo\desktop\snVideoEditor` |

共享契约与验收规则详见两个仓库的 `AGENTS.md`「跨项目联动」章节。