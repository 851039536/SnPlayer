---
name: streaming-throttle-fix
overview: 为流式解密代理增加真正的数据节流机制（块间延迟 + 初始爆发），解决 ExoPlayer 管道溢出导致的音频帧全部丢弃和卡死问题。
todos:
  - id: add-throttle-constants
    content: 在 crypto.dart 流式解密配置区新增 streamingThrottleDelayMs（20ms）和 streamingBurstBlocks（4 块）两个常量
    status: completed
  - id: replace-throttle-logic
    content: 在 streaming_decrypt_proxy.dart 的 _decryptAndStream 方法中：新增 blocksSent 局部计数器，将缓存命中路径和解密路径的 Future.delayed(Duration.zero) 均替换为节流逻辑（前 burst 块 Duration.zero，之后等待 throttle 延迟）
    status: completed
    dependencies:
      - add-throttle-constants
  - id: update-memory
    content: 更新 .codebuddy/memory/2026-07-01.md 追加本次修复纪录
    status: completed
    dependencies:
      - replace-throttle-logic
---

## 需求

700MB+ 加密视频通过流式解密代理播放时，pipelineFull 持续数百次，音频帧全部丢弃（Render:0, Drop:107），Video 正常（Render:101）。AudioTrack 在约 20 秒暂停，播放卡死。

## 根因

上轮修复（512KB 块 + flush + Duration.zero yield）未能解决。根本原因是 localhost 回环 TCP 缓冲区极大（2-64MB），`response.flush()` 几乎瞬间返回，`Future.delayed(Duration.zero)` 仅让出微任务队列不限制供数速度。ExoPlayer 管道容量仅 6 帧，数据灌入速度远超消费速度导致 pipelineFull，音频帧因 PTS 落后被丢弃，最终 AudioTrack 暂停→卡死。

## 修复方案

引入真正的节流延迟（20ms/块），前 4 块（2MB）快速爆发保证秒级起播，之后每块等待固定延迟。将有效吞吐从无穷大压降至约 25MB/s（512KB ÷ 20ms），远高于视频播放所需（约 1MB/s）但不会灌满管道。

## 技术方案

### 修改文件

- `lib/config/crypto.dart`：新增两个常量
- `lib/services/streaming_decrypt_proxy.dart`：替换两处 `Future.delayed(Duration.zero)` 为节流逻辑

### 核心思路

在 `_decryptAndStream()` 中引入局部块计数器 `blocksSent`，每成功发送一个块后计数+1，根据计数决定延迟时长：

- `blocksSent < streamingBurstBlocks`：`Duration.zero`（快速爆发，秒级起播）
- `blocksSent >= streamingBurstBlocks`：`Duration(milliseconds: streamingThrottleDelayMs)`（节流）

### 常量设计

| 常量 | 值 | 说明 |
| --- | --- | --- |
| `streamingBurstBlocks` | 4 | 前 4 块（512KB×4=2MB）零延迟爆发，保证起播速度 |
| `streamingThrottleDelayMs` | 20 | 节流延迟毫秒数，压降至约 25MB/s |


### 影响分析

- 小文件（＜streamingBurstBlocks 块）：全部零延迟，不受影响
- 大文件（700MB）：1434 块中前 4 块零延迟，后 1430 块各延迟 20ms，总延迟约 28.6s，有效吞吐约 25MB/s，远超视频播放所需约 1MB/s
- 每 20ms 间隔给 ExoPlayer 足够时间消费管道中的帧（6 帧约需 200ms），杜绝 pipelineFull
- 解密流程零改动，仅调整供数节奏