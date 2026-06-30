---
name: snplayer-code-quality-fix
overview: 修复 SnPlayer 项目的 21 个代码质量问题：6 个逻辑漏洞、7 个代码冗余、8 个内存泄漏风险，涵盖播放器竞态条件、UUID 冲突、O(N²) 扫描、Isolate 超时、资源释放等。
todos:
  - id: fix-player-race-dispose
    content: 修复播放器竞态条件与 dispose 资源管理：Timer 引用管理 + unawaited 安全删除 + 日志记录
    status: completed
  - id: fix-uuid-exception-handling
    content: 修复 UUID 生成冲突（改用 uuid v4）+ _processingState try-finally 异常加固
    status: completed
  - id: fix-batch-encrypt-performance
    content: 优化批量加密性能：loadVideos 移出循环，直接构造 VideoItem 避免 O(N²) 扫描
    status: completed
  - id: fix-isolate-lifecycle
    content: 修复 Isolate 生命周期：添加 5 分钟超时 + 优雅关闭（beforeNextEvent 优先）
    status: completed
  - id: fix-key-cache
    content: 修复密钥缓存：_keyCache 增加 LRU 100 条上限 + 移除无效 _isoKeyCache
    status: completed
  - id: extract-shared-utils
    content: 代码去重：新增 color_utils.dart 和 crypto_utils.dart 共享模块，统一 parseColor/formatFileSize/加密工具函数
    status: completed
  - id: cleanup-deps-logs-thumbnail
    content: 依赖清理 + 全局日志加固 + 缩略图加载超时：移除 intl、清理 VideoCard 未使用回调、所有 catch 添加 debugPrint、缩略图 10 秒超时
    status: completed
---

## 用户需求

修复 SnPlayer 项目中全部 21 项代码质量问题，包括 6 处逻辑漏洞、7 处代码冗余、8 处内存泄漏风险。

## 核心修复内容

### 逻辑漏洞修复（6项）

1. **播放器临时文件竞态条件** — `Future.delayed` 30秒自动删除与快速进出播放页产生竞态，旧回调会删除新临时文件
2. **UUID 生成冲突风险** — `_generateShortUuid()` 用微秒时间戳取模，同一微秒内创建多个文件夹必定产生重复 ID
3. **批量加密 O(N²) 扫描** — 每加密一个视频就全量递归扫描文件系统，N个视频产生 N² 次 I/O
4. **dispose 中 safeDelete 无感知** — fire-and-forget 删除，失败无日志，与30秒定时删除可能双重删除
5. **Isolate 无超时机制** — worker 崩溃未发 error 消息时主线程永久挂起，Isolate 永不 kill
6. **_processingState 异常残留** — 非 Exception 类型错误（Error）时状态不清理

### 代码冗余消除（7项）

7. `_parseColor` 在 folder_manage_screen 和 folder_tabs 中重复实现
8. `formatFileSize` 在 VideoItem 和 FileUtils 中重复实现
9. `_generateRandomBytes` 在 crypto_service 和 crypto_isolate 中重复
10. PBKDF2 `deriveKey` 在 crypto_service 和 crypto_isolate 中重复
11. AES-CTR `_createCipher` 在 crypto_service 和 crypto_isolate 中重复
12. pubspec.yaml 中 uuid 和 intl 依赖未使用
13. VideoCard 中 onPlay/onDecrypt/onRename/onMove/onDelete 五个回调定义了但从未使用

### 内存泄漏修复（8项）

14. `Future.delayed` 无 Timer 引用，页面 pop 后回调仍持有 `_tempPath` 闭包
15. `_processingState` Map 异常时残留僵尸条目
16. Isolate 强制 kill 可能留未关闭文件句柄
17. `_keyCache` Map 永不清理，文件越多缓存越大
18. `_isoKeyCache` 设计无效 —— 每次 spawn 新 Isolate 立即 kill，缓存从未被利用
19. `loadThumbnails` 批量 Future.wait 无超时
20. `Image.memory` 持有 Uint8List，大量视频时缩略图占用数百 MB
21. 所有 `catch (_)` 静默吞异常，生产环境调试困难

## 技术栈

- Flutter + Dart SDK >=3.1.0
- Provider 状态管理
- pointycastle 加密库
- uuid 包（已有依赖，用于 UUID 生成）

## 实现方案

### 分组策略

按影响范围和依赖关系分为 7 个独立任务组，每组可单独验证：

### 分组一：播放器竞态条件 + dispose 资源管理

**文件**: `video_player_screen.dart`

**Timer 竞态修复**：

- 新增 `Timer? _deleteTimer` 字段保存定时器引用
- `_initPlayer()` 开始时先 `_deleteTimer?.cancel()` 取消旧定时器
- 用 `Timer()` 替代 `Future.delayed()`，以获得可取消的引用
- `dispose()` 中 `_deleteTimer?.cancel()` 确保定时器生命周期受控

**dispose 安全删除修复**：

- 引入 `dart:async` 的 `unawaited` 包裹 `safeDelete`，显式表达异步意图
- 增加 `debugPrint` 日志记录删除结果

### 分组二：UUID 生成 + 异常处理加固

**文件**: `storage_service.dart`、`video_list_provider.dart`

**_generateShortUuid 修复**：

- 导入 `package:uuid/uuid.dart`，使用 `const Uuid().v4()` 生成真正随机 ID
- 截取前 8 位作为短 ID（保留文件夹命名简洁性）

**_processingState 异常加固**：

- `pickAndEncryptVideos` 和 `decryptAndExport` 中使用 `try-catch-finally` 确保 `_removeProcessingState` 始终执行
- catch 块保留 Error 类型捕获能力

### 分组三：批量加密性能优化

**文件**: `video_list_provider.dart`

- 将 `loadVideos()` 调用移出循环，在循环结束后只扫描一次
- 循环内改为直接构造 `VideoItem` 追加到 `_videos` 列表并 `notifyListeners()`
- `renameVideo` 方法同理改为直接修改现有 VideoItem 而非全量重扫

### 分组四：Isolate 生命周期管理

**文件**: `crypto_service.dart`

**超时机制**：

- 使用 `completer.future.timeout(Duration(minutes: 5))` 包装
- 超时后 kill Isolate 并抛出明确的 TimeoutException

**优雅关闭**：

- 先用 `Isolate.kill(priority: Isolate.beforeNextEvent)` 尝试优雅关闭
- 2 秒后若 Isolate 仍存活再用 `Isolate.immediate` 强制终止

### 分组五：_keyCache 与 _isoKeyCache 修复

**文件**: `crypto_service.dart`、`crypto_isolate.dart`

**_keyCache LRU 限制**：

- 设置最大缓存条目 100（32字节 x 100 = 3.2KB，可忽略）
- 新增 `_addToCache` 方法，超过上限时删除最早条目（利用 Map 插入顺序）

**_isoKeyCache 移除**：

- 删除 `crypto_isolate.dart` 中的 `_isoKeyCache` 及其缓存逻辑
- `_isoDeriveKey` 直接计算密钥不缓存（每次 spawn 新 Isolate 缓存本就不生效）

### 分组六：代码去重

**新增文件**: `utils/color_utils.dart`、`utils/crypto_utils.dart`
**修改文件**: `folder_manage_screen.dart`、`folder_tabs.dart`、`video_item.dart`、`crypto_service.dart`、`crypto_isolate.dart`

**color_utils.dart** — 提取 `parseHexColor(String hex)` 公共函数，同时支持 6 位和 8 位格式

**crypto_utils.dart** — 提取三个纯计算函数（无 Isolate/Flutter 依赖）：

- `generateRandomBytes(int length)` — 生成加密安全随机字节
- `deriveKeyFromPassword(Uint8List passwordBytes, Uint8List salt)` — PBKDF2 密钥派生
- `createCtrCipher(Uint8List key, Uint8List iv)` — AES-CTR Cipher 创建

**video_item.dart** — `formattedSize` getter 改为委托 `FileUtils.formatFileSize(fileSize)`

**crypto_service.dart** — `deriveKey`、`_generateRandomBytes`、`_createCipher` 改为调用 `CryptoUtils.*`
**crypto_isolate.dart** — `_isoDeriveKey`、`_isoRandomBytes`、`_isoCreateCipher` 改为调用 `CryptoUtils.*`

### 分组七：依赖清理 + 日志 + 缩略图超时

**文件**: `pubspec.yaml`、`video_card.dart`、`thumbnail_service.dart`、`video_list_provider.dart`

**依赖清理**：移除 `intl: ^0.19.0`（`uuid` 保留因为现在要使用它）

**VideoCard 清理**：移除 `onPlay`、`onDecrypt`、`onRename`、`onMove`、`onDelete` 五个未使用的属性及构造函数参数

**全局日志加固**：所有 `catch (_)` 改为 `catch (e)`，增加 `debugPrint('[SnPlayer] 模块名: $e')` 日志——涉及文件：

- `crypto_service.dart`（已有部分）
- `crypto_isolate.dart`
- `storage_service.dart`
- `thumbnail_service.dart`
- `safe_delete_helper.dart`
- `video_list_provider.dart`

**缩略图加载超时**：`loadThumbnails` 的 `Future.wait` 中单个缩略图加载添加 10 秒超时 `Future.any([loadTask, timeout])`

## 实施注意事项

- **禁止构建验证**：按项目规则不执行 `flutter build`，修改后由用户自行验证
- **向后兼容**：所有修改保持现有 API 签名不变
- **if 花括号**：严格遵守项目代码风格规则，if 语句必须有花括号
- **Isolate 共享模块**：`crypto_utils.dart` 是纯 Dart 无 UI 依赖的工具函数，可安全被 Isolate 和主线程共用