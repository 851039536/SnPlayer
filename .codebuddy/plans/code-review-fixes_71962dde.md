---
name: code-review-fixes
overview: 修复代码审查中发现的 8 个问题：Worker 竞态、空指针崩溃、重复方法、Isolate 代码重复、fire-and-forget 缺失 unawaited、CancellationToken 类型不匹配、逐字节随机数、重复常量。
todos:
  - id: fix-worker-race
    content: 修复 video_list_provider.dart Worker 竞态：双 worker 改为单 worker 循环，删除 nextIndex/worker 闭包
    status: completed
  - id: fix-null-crash
    content: 修复 video_player_screen.dart _onGestureTap 空指针：增加 if _controller==null return 提前退出
    status: completed
  - id: remove-duplicate-method
    content: 删除 video_list_provider.dart 重复方法 cleanExpiredThumbnails，更新 video_list_screen.dart 调用为 cleanupExpiredThumbnails
    status: completed
  - id: extract-common-isolate
    content: 重构 crypto_service.dart：提取 _spawnAndManageIsolate 公共方法，_runInIsolate 与 _runPartialInIsolate 委托调用消除 ~60 行重复
    status: completed
  - id: fix-unawaited
    content: video_list_screen.dart:99 为 cleanupExpiredThumbnails 添加 unawaited 包裹
    status: completed
  - id: fix-cancellable-type
    content: cancellable.dart _onCancelCallbacks 和 onCancel 类型从 Future
    status: completed
---

## 修复内容概览

修复代码审查中发现的全部 8 项问题，按严重程度分为 HIGH/MEDIUM/LOW 三级。

### HIGH（3 项）

1. **Worker 竞态条件**（`video_list_provider.dart:306-321`）：双 worker 并发消费队列时 `nextIndex++` 非原子操作。Dart 单线程下 2 worker 无实际 I/O 并行收益，改为单 worker 消除竞态。

2. **空指针崩溃风险**（`video_player_screen.dart:82-89`）：`_onGestureTap` 的 else 分支直接调用 `_controller!.play()` 无 null 检查，与 if 分支行为不一致。

3. **重复方法**（`video_list_provider.dart:359-363`）：`cleanExpiredThumbnails` 与 `cleanupExpiredThumbnails` 完全相同，应删除一个。

### MEDIUM（3 项）

4. **Isolate 代码重复**（`crypto_service.dart:75-206`）：`_runInIsolate` 和 `_runPartialInIsolate` 约 60 行几乎相同，仅 message 字段和超时时间不同。提取公共基方法。

5. **unawaited 缺失**（`video_list_screen.dart:99`）：后台清理调用缺少 `unawaited()` 包裹。

6. **类型不匹配**（`cancellable.dart:8`）：`_onCancelCallbacks` 声明为 `Future<void> Function()` 但 `cancel()` 中从未 await，应改为 `void Function()`。

### LOW（2 项）

7. **随机数生成低效**（`crypto_utils.dart:17-24`）：逐字节循环调用 `Random.secure()` 创建新实例。

8. **重复常量**（`file_utils.dart:40,51`）：`const invalidChars` 在两方法中各定义一次。

## 修复方案

### HIGH-1: Worker 竞态 → 单 worker

**文件**：`lib/providers/video_list_provider.dart:306-321`

**方案**：删除 `worker()` 闭包，将 `Future.wait([worker(), worker()])` 改为单 worker 循环：

```
// 改前（双 worker + 竞态）
Future<void> worker() async {
  while (true) {
    if (_thumbnailToken.isCancelled) { break; }
    final int idx = nextIndex;        // 非原子读取
    if (idx >= queue.length) { break; }
    nextIndex++;                       // 非原子递增
    await processVideo(queue[idx]);
  }
}
await Future.wait([worker(), worker()]);  // 可能重复处理

// 改后（单 worker 顺序处理）
for (final video in queue) {
  if (_thumbnailToken.isCancelled) { break; }
  await processVideo(video);
}
```

删除 `nextIndex` 变量、`worker()` 闭包定义。Dart 是单线程事件循环，`await processVideo()` 内部的 I/O（文件读写）是非阻塞的，2 个 worker 只是在同一线程上交替执行——没有真正的并行加速，反而引入了竞态和额外复杂度。

### HIGH-2: 空指针崩溃

**文件**：`lib/screens/video_player_screen.dart:82-89`

**修改**：在方法开头增加 null 检查：

```
void _onGestureTap() {
  if (_controller == null) { return; }
  if (_controller!.value.isPlaying) {
    _controller!.pause();
  } else {
    _controller!.play();
  }
  setState(() {});
}
```

### HIGH-3: 删除重复方法

**文件**：`lib/providers/video_list_provider.dart:359-363`

删除 `cleanExpiredThumbnails()` 方法（359-363行）。同步更新 `video_list_screen.dart:99` 调用点：`videoProvider.cleanExpiredThumbnails()` → `videoProvider.cleanupExpiredThumbnails()`。

### MEDIUM-4: 提取公共 Isolate 方法

**文件**：`lib/services/crypto_service.dart:75-206`

提取公共方法 `_spawnAndManageIsolate`，封装完整的 Isolate 生命周期：

```
static Future<void> _spawnAndManageIsolate({
  required Map<String, dynamic> message,
  required Duration timeout,
  void Function(double)? onProgress,
}) async {
  final completer = Completer<void>();
  final receivePort = ReceivePort();
  final isolate = await Isolate.spawn(cryptoWorker, receivePort.sendPort);
  final workerSendPort = await receivePort.first as SendPort;

  final progressPort = ReceivePort();
  progressPort.listen((event) {
    if (event is Map) {
      final type = event['type'] as String?;
      if (type == 'progress') {
        onProgress?.call((event['value'] as num?)?.toDouble() ?? 0);
      } else if (type == 'done') {
        if (!completer.isCompleted) { completer.complete(); }
      } else if (type == 'error') {
        final msg = event['message'] as String? ?? 'Unknown error';
        if (!completer.isCompleted) { completer.completeError(Exception(msg)); }
      }
    }
  });

  try {
    message['progressPort'] = progressPort.sendPort;
    workerSendPort.send(message);
    await completer.future.timeout(timeout, onTimeout: () {
      throw TimeoutException('Isolate ${message['command']} 超时');
    });
  } catch (e) {
    debugPrint('[SnPlayer] CryptoService: $e');
    rethrow;
  } finally {
    progressPort.close();
    receivePort.close();
    try { isolate.kill(priority: Isolate.beforeNextEvent); }
    catch (e) { isolate.kill(priority: Isolate.immediate); }
  }
}
```

原 `_runInIsolate` 和 `_runPartialInIsolate` 改为简单委托调用，仅负责组装 message map。

### MEDIUM-5: 添加 unawaited

**文件**：`lib/screens/video_list_screen.dart:99`

```
// 改前
videoProvider.cleanupExpiredThumbnails();
// 改后
unawaited(videoProvider.cleanupExpiredThumbnails());
```

### MEDIUM-6: 修正类型

**文件**：`lib/utils/cancellable.dart:8,22`

```
// 改前
final List<Future<void> Function()> _onCancelCallbacks = [];
void onCancel(Future<void> Function() callback) { ... }

// 改后
final List<void Function()> _onCancelCallbacks = [];
void onCancel(void Function() callback) { ... }
```

### LOW-7: 随机数生成优化

**文件**：`lib/utils/crypto_utils.dart:17-24`

```
// 改前
static Uint8List generateRandomBytes(int length) {
  final random = Random.secure();  // 每次调用创建新实例
  ...
  for (int i = 0; i < length; i++) { bytes[i] = random.nextInt(256); }
}

// 改后
static final _secureRandom = Random.secure();
static Uint8List generateRandomBytes(int length) {
  final bytes = Uint8List(length);
  for (int i = 0; i < length; i++) { bytes[i] = _secureRandom.nextInt(256); }
}
```

### LOW-8: 提取常量

**文件**：`lib/utils/file_utils.dart`

```
class FileUtils {
  static const _invalidChars = ['/', '\\', ':', '*', '?', '"', '<', '>', '|'];

  static bool isValidFileName(String name) {
    for (final c in _invalidChars) { ... }
  }
  static String sanitizeFileName(String name) {
    for (final c in _invalidChars) { ... }
  }
}
```