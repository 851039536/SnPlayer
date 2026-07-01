---
name: fix-streaming-cache-corrupt-file
overview: 修复流式解密代理磁盘缓存文件为空导致的二次播放失败 bug。预分配缓存文件但从未写入解密数据，导致缓存检查误判命中。
todos:
  - id: remove-proxy-cache-preal
    content: 从 StreamingDecryptProxy 移除 _cacheFile 预分配死代码，简化 start() 签名去掉 cacheFilePath 参数
    status: completed
  - id: validate-cache-content
    content: PlaybackCacheManager.getCachedFile() 增加文件头内容校验，拦截全零脏缓存
    status: completed
  - id: cache-fallback-proxy
    content: VideoPlayerScreen 缓存播放失败时降级到流式代理，并适配新的 start() 调用
    status: completed
    dependencies:
      - validate-cache-content
      - remove-proxy-cache-preal
---

## 问题描述

100MB 左右的加密视频首次播放正常（流式代理按 Range 解密），但第二次点击播放时缓存命中，ExoPlayer 报 `UnrecognizedInputFormatException: None of the available extractors could read the stream`，`sniff failures: [NoDeclaredBrand, NoDeclaredBrand]`。

## 根因分析

1. `StreamingDecryptProxy.start()` 预分配了一个与解密后等大的缓存文件，内容全为零字节
2. `_decryptAndStream()` 注释明确说明"流式传输期间不写磁盘缓存"，实际从未向该文件写入解密数据
3. `PlaybackCacheManager.getCachedFile()` 仅校验文件存在 + 大小匹配，误将全零文件视为有效缓存
4. ExoPlayer 加载全零文件，无法识别任何视频格式

## 核心修复

- **移除代理中的无效缓存预分配**：`StreamingDecryptProxy` 不再预分配缓存文件，消除全零文件的产生源头
- **增强缓存校验**：`PlaybackCacheManager` 增加文件头内容验证（前 64 字节非全零），拦截已存在的脏缓存
- **增加播放降级**：`VideoPlayerScreen` 在缓存播放失败时自动降级到流式代理，避免直接报错退出

## Tech Stack

- Flutter + Dart
- video_player (ExoPlayer / AVPlayer)
- 现有加密/解密架构（AES-256-CTR + PBKDF2）

## 实现方案

### 修复策略（三层防御）

**第一层（源头）**：移除 `StreamingDecryptProxy` 中的缓存文件预分配代码。该代理的职责是流式解密传输，不负责磁盘缓存。`_cacheFile` 字段及 `start()` 中的预分配逻辑（第 60-65 行）、`stop()` 中的 flush/close 逻辑（第 128-132 行）全部移除。`start()` 签名简化，不再接收 `cacheFilePath` 参数。

**第二层（校验）**：`PlaybackCacheManager.getCachedFile()` 在大小校验通过后，增加文件头内容校验——打开文件读取前 64 字节，检查是否全为零。若全为零则判定为无效缓存，删除后返回 null。这能拦截已存在于磁盘上的脏缓存文件。

**第三层（兜底）**：`VideoPlayerScreen._initPlayer()` 缓存命中路径增加 try-catch，若 `_controller!.initialize()` 抛出异常，清理脏缓存并降级到流式代理路径，避免直接显示错误页面。

### 关键决策

- **不从代理写缓存**：避免磁盘 I/O 拖慢供数（现有注释已验证此设计意图），未来如需缓存可在播放结束后异步写入
- **64 字节校验足够**：任何有效视频文件（MP4/MKV/AVI 等）前 64 字节必然包含非零数据（文件签名 + 元数据），全零文件只会来自代理的预分配操作
- **不改动加密解密核心逻辑**：AES-CTR 流式解密、PBKDF2 密钥派生等核心流程零改动，保持与 MewTool 的兼容性

## 受影响文件

```
lib/
├── services/
│   ├── streaming_decrypt_proxy.dart   # [MODIFY] 移除 _cacheFile 及预分配逻辑
│   └── playback_cache_manager.dart    # [MODIFY] 增加文件头内容校验
└── screens/
    └── video_player_screen.dart       # [MODIFY] 缓存播放失败降级 + 调用适配
```

### 文件变更详情

**`lib/services/streaming_decrypt_proxy.dart`**

- 移除 `_cacheFile` 字段（第 40-41 行）
- `start()` 移除 `cacheFilePath` 参数，删除预分配逻辑（第 59-65 行）
- `stop()` 删除 `_cacheFile` flush/close 块（第 128-132 行）
- 更新 class doc 中关于缓存的相关描述

**`lib/services/playback_cache_manager.dart`**

- `getCachedFile()` 在大小校验通过后，新增 `_isValidCacheContent()` 辅助方法
- 辅助方法打开文件读取前 64 字节，检查是否全为零：`buffer.any((b) => b != 0)`
- 若全为零则 `SafeDeleteHelper.fastDelete()` 并返回 null

**`lib/screens/video_player_screen.dart`**

- `_initWithProxy(cacheDir)` 不再调用 `PlaybackCacheManager.getCacheFilePath()`，`start()` 改为仅传入 `encPath`
- `_initPlayer()` 缓存命中路径包裹 try-catch：catch 时删除脏缓存，重置 `_usingCache=false`、`_tempPath=null`，降级到阶段 2（流式代理）