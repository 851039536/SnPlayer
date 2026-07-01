---
name: code-review-fixes
overview: 修复代码审查发现的 1 个严重 Bug（并行加解密输出损坏）+ 3 个中等问题 + 若干低风险清理。
todos:
  - id: fix-parallel-write-mode
    content: "严重: crypto_service.dart _writeBatchToOutput 将 FileMode.writeOnlyAppend 改为 FileMode.write"
    status: completed
  - id: fix-range-status-code
    content: "中等: streaming_decrypt_proxy.dart 修复 Range 解析失败时 isPartial 判断，改为基于 parsed != null"
    status: completed
  - id: simplify-cache-continue
    content: "中等: streaming_decrypt_proxy.dart 删除缓存命中路径的冗余 continue 分支"
    status: completed
  - id: fix-stale-comment
    content: "中等: crypto.dart 更新 streamingBlockSize 注释，反映实际 512KB 粒度和废弃状态"
    status: completed
  - id: await-proxy-stop
    content: "低风险: video_player_screen.dart dispose 中 await _proxy!.stop()"
    status: completed
  - id: extract-format-duration
    content: "低风险: file_utils.dart 新增 formatDuration，player_gesture 和 player_progress_bar 统一调用"
    status: completed
---

## 需求概述

修复代码审查发现的 6 个问题，按严重程度分三级处理。

## 严重 Bug (P0)

1. **并行加解密输出损坏** — `crypto_service.dart:483` 的 `_writeBatchToOutput` 使用了 `FileMode.writeOnlyAppend`（等价 append 模式），导致 `setPositionSync` 被忽略，所有 chunk 追加到文件末尾而非正确偏移位置。影响 `_runParallelDecrypt` 和 `_runParallelEncrypt`，所有 ≥64MB 文件的并行加解密输出均损坏。

## 中等问题 (P1)

2. **Range 解析失败时状态码不一致** — `streaming_decrypt_proxy.dart:197` 的 `isPartial` 只看 `rangeHeader != null`，若 `_parseRange` 解析失败（非法格式）返回 null，仍返回 `206 Partial Content` 但实际发送全量数据。
3. **缓存命中路径冗余 continue** — `streaming_decrypt_proxy.dart:345-350` 两个连续的 `continue` 存在结构冗余。
4. **`streamingBlockSize` 注释过时** — `crypto.dart:128-131` 注释仍写"4MB，与 bufferSize 一致"，实际缓存粒度已改为 512KB。

## 低风险清理 (P2)

5. **`_proxy!.stop()` 未 await** — `video_player_screen.dart:166` dispose 中未等待异步 stop 完成。
6. **`_formatDuration` 重复定义** — `player_gesture.dart:283-291` 和 `player_progress_bar.dart:92-100` 完全相同的方法，提取到 `file_utils.dart` 公共工具类。

## 技术方案

### 修复策略

所有修复均为单一文件内的局部改动，不涉及架构变更。

### P0: 修复并行加解密输出损坏

**根因**: Dart 的 `FileMode.writeOnlyAppend` 等价 `FileMode.append`，POSIX 层使用 `O_APPEND` 标志，所有写入强制追加到文件末尾，`setPositionSync` 被内核忽略。

**修复**: `crypto_service.dart:483` 将 `FileMode.writeOnlyAppend` 改为 `FileMode.write`。预分配已在调用方通过 `setPositionSync(size-1) + writeByte(0)` 完成，`write` 模式允许 seek 后覆盖写入，不影响预分配逻辑。

### P1: 修复 Range 解析状态码

**修复**: `streaming_decrypt_proxy.dart:188-197` 将 `isPartial` 的判断条件从 `rangeHeader != null` 改为 `parsed != null`（跟踪 `_parseRange` 的返回结果）。

### P1: 简化缓存命中路径

**修复**: `streaming_decrypt_proxy.dart:345-350` 删除第 345 行的条件 `continue`，因 `actualCopyLen == copyLen` 时逻辑上已自然走出 if，不需要独立分支。

### P1: 更新过时注释

**修复**: `crypto.dart:128-131` 的 `streamingBlockSize` 注释修正为 `512KB`，实际常量值不变。

### P2: await stop()

**修复**: `video_player_screen.dart:165-167` 将 `dispose()` 改为 `Future<void> dispose() async`（Flutter 框架已支持 async dispose），并在 `_proxy!.stop()` 前加 `await`。注意 `_stopped = true` 是同步的，await 只等 server close + file flush/close，不会延长 dispose 时间。

### P2: 提取公共 _formatDuration

**修复**: 在 `file_utils.dart` 新增 `static String formatDuration(Duration d)` 方法。`player_gesture.dart` 和 `player_progress_bar.dart` 改为调用 `FileUtils.formatDuration()`，删除各自的私有方法。

### 目录结构

```
lib/
├── config/
│   └── crypto.dart                    # [MODIFY] 更新 streamingBlockSize 注释
├── screens/
│   └── video_player_screen.dart       # [MODIFY] dispose 中 await _proxy!.stop()
├── services/
│   ├── crypto_service.dart            # [MODIFY] FileMode.writeOnlyAppend → write
│   └── streaming_decrypt_proxy.dart   # [MODIFY] Range 状态码 + 简化 continue
├── utils/
│   └── file_utils.dart                # [MODIFY] 新增 formatDuration 静态方法
└── widgets/player/
    ├── player_gesture.dart            # [MODIFY] 使用 FileUtils.formatDuration
    └── player_progress_bar.dart       # [MODIFY] 使用 FileUtils.formatDuration
```

### 实现注意事项

- `_formatDuration` 提取时，`player_progress_bar.dart` 版本有冗余 `.toString()` (line 97: `minutes.toString().padLeft`)，提取后统一用干净版本 `minutes.padLeft(2, '0')`
- `streamingBlockSize` 常量无法直接删除（是 const 公共导出，外部可能引用），仅更新注释
- `dispose()` 改为 `Future<void>` 在 Flutter 3.x+ 已官方支持，无需额外处理