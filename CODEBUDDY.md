# CODEBUDDY.md This file provides guidance to CodeBuddy when working with code in this repository.

## 常用命令

```bash
# 获取依赖
flutter pub get

# 静态分析（检查 lint 和类型错误）
flutter analyze

# 运行应用（需连接 Android 设备或模拟器）
flutter run

# 运行测试
flutter test

# 补全平台目录结构（如果 android/ios 等目录不完整）
flutter create --project-name sn_player --org com.snplayer .
```

- **不要私自执行 `flutter build` 构建项目**，构建过程太慢太卡，修改完代码后由用户自行调试验证。
- lint 规则来自 `analysis_options.yaml`：强制要求 `if` 语句必须有花括号 `{}`（`curly_braces_in_flow_control_structures: true`）。

## 项目架构

SnPlayer 是 Flutter Android 视频加密管理应用，使用 AES-256-CTR + PBKDF2 加密保护视频文件，兼容 MewTool `.enc` 格式。

### 分层架构（自上而下）

```
screens/          # 页面级 UI，组装 widgets + 调用 providers
widgets/          # 可复用 UI 组件（播放器控制、视频卡片、菜单等）
providers/        # 状态管理（Provider + ChangeNotifier），持有业务状态
services/         # 核心业务逻辑（加密、存储、缩略图、权限）
models/           # 纯数据模型（VideoItem、VideoFolder、ProcessingState）
config/           # 密码学常量、目录名、版本号
theme/            # Design Token 体系（颜色、间距、字号、圆角、时长、尺寸）
utils/            # 纯函数工具（文件工具、加密工具、颜色工具、可取消令牌）
```

依赖方向：`screens → widgets/providers → services → models/config`，上层不跨过 services 直接访问底层。`utils/` 和 `theme/` 是横向工具层，各层均可引用。

### 入口与状态注入

`lib/main.dart` 使用 `MultiProvider` 注入两个顶层 Provider：

- **FolderProvider** — 文件夹 CRUD、当前选中文件夹、筛选逻辑
- **VideoListProvider** — 视频列表 CRUD、加密/解密流程、缩略图加载队列、存储统计、缓存清理

首页为 `VideoListScreen`，支持 Material 3 双主题（light/dark），跟随系统 `ThemeMode.system`。主列表页已按职责拆分：卡片操作分发在 `screens/video_actions_handler.dart`，第三方播放三级策略在 `screens/external_play_handler.dart`，详情弹窗与确认/输入对话框分别在 `widgets/video_detail_sheet.dart`、`widgets/video_dialogs.dart`。

### 加密核心（services/crypto_service.dart）

加密算法：**AES-256-CTR + PBKDF2-HMAC-SHA256（10 次迭代）**

> **安全说明**：PBKDF2 迭代次数仅 10 次（非标准的 100,000+），因本项目使用固定密码而非用户密码，安全性靠密码本身强度而非 KDF 迭代。若改为用户自定义密码，应将 `pbkdf2Iterations` 提升至 100,000 以上。

文件格式（64 字节明文文件头）：

```
offset 0-15:   IV（16 字节，随机生成）
offset 16-31:  Salt（16 字节，随机生成）
offset 32:     版本号（v2 = 0x02）
offset 33-63:  Reserved（31 字节，全零）
offset 64+:    AES-256-CTR 密文
```

关键设计：
- `CryptoService` 使用 **Isolate** 在后台线程执行加解密，避免阻塞 UI。
- 加密/解密均支持**多 Isolate 并行分块**，`encryptFile`/`decryptFile` 会根据文件大小自动选择路径：≥64MB 走并行（2-6 路），否则串行。并行分块调度器已拆分至 `parallel_crypto_scheduler.dart`（加/解密共用同一参数化调度流程，异步批量合并 + 复制总量校验）。并行路径曾存在文件头版本字节（偏移 32）被截断为 0x00 的 bug，根因是 `_writeBatchToOutput` 使用 `FileMode.write`（等同 `O_TRUNC`）重复打开输出文件，清空了已写入的 64 字节文件头。已于 2026-07-02 修复：改为在整个并行流程中复用同一 `RandomAccessFile` 句柄，由 `try/finally` 保证关闭。并行失败时会清理临时 chunk 文件和损坏的输出文件，进度回调单调递增避免多 chunk 交错跳变。
- 解密到播放缓存（`decryptToTemp`）先写 `.decrypting.tmp` 再原子 rename 到最终名，防止预分配/半写入的文件被 `PlaybackCacheManager` 误判为有效缓存（TOCTOU）。
- 密钥派生结果使用 LRU 缓存（容量 100），避免重复 PBKDF2 计算。
- `crypto_isolate.dart` 是 Isolate Worker，在独立线程中执行 encrypt/decrypt 命令，采用双缓冲流水线（4MB 缓冲区）。
- `utils/crypto_utils.dart` 是纯 Dart 的密码学工具函数（含 64 字节文件头的统一解析/构建 `parseEncHeader`/`buildEncHeader`），不依赖 Flutter/Isolate，可跨平台使用。

### 视频播放策略（三段式降级）

`VideoPlayerScreen` 加载视频时按以下优先级尝试：

1. **磁盘缓存命中** — `PlaybackCacheManager` 校验缓存完整性（大小匹配 + 文件头非零验证），有效则直接播放本地文件
2. **流式解密代理** — 启动本地 HTTP 代理服务器（`StreamingDecryptProxy`），利用 AES-CTR 随机访问特性 + 原生播放器 HTTP Range 请求实现按需解密：
   - **长驻 Worker Isolate**（`streaming_decrypt_worker.dart`）：解密在独立 Isolate 执行，主线程零同步阻塞。每个请求分配唯一 `requestId`，支持并发 Range 请求（视频轨+音频轨）独立取消/完成，互不干扰；文件截断/EOF 提前到来时上报 error 而非静默短写
   - **ack 窗口流控**：Worker 每发 4 块（~2MB）等待主线程 ack，防止超前解密导致内存积压
   - **首块 64KB 快速返回**：seek 后首字节延迟从 ~100ms 降至 ~15ms，后续块恢复 512KB 提升吞吐
   - **内存 LRU 块缓存**（128 块 = 64MB）：缓存命中时主线程直接返回，不经过 Worker。仅缓存 512KB 对齐的整块，避免索引错位导致 `Invalid NAL length` 解码错误
   - **连接断开处理**：提前终止时 `detachSocket().destroy()` 发 RST 重置 TCP，让播放器明确收到中断信号并发起新 Range 请求
3. **全量解密回退** — 前两种方式不可用时，解密整个文件到临时目录再播放（全量临时文件在 dispose 时自动删除）；解密期间播放页 loading 视图显示线性进度条 +「正在解密 xx%」

缓存策略：`PlaybackCacheManager` 缓存最多保留 3 天，LRU 淘汰上限 500MB，每次启动自动清理过期缓存。用户可通过 `VideoListProvider.clearAllCache()` 手动清空全部缓存（播放 + 缩略图）。

### 加解密进度 UI

所有前台加解密操作均有可见进度（底层 Isolate 进度经 `onProgress` 回调逐层上报）：

- **CryptoProgressDialog / CryptoProgressController**（`widgets/crypto_progress_dialog.dart`）— 统一的模态进度对话框：标题 + 文件名 + 线性进度条 + 百分比，批量场景显示「第 n/总数 个」；controller 按整数百分比节流 notifyListeners，避免高频重建；对话框用 PopScope 屏蔽返回键，由调用方在 finally 中关闭
- **加密导入** — `VideoListProvider.pickVideoFiles()` 选文件后由列表页调 `encryptVideos()` 批量加密，全程模态进度对话框（文件名/第 n 个/百分比），完成后 SnackBar 汇总成功/失败数；加密期间视频尚未入列表，不写 processingState
- **解密导出** — 进度双通道：模态进度对话框 + 视频卡片角标徽章（processingState 文本）
- **第三方播放全量解密降级** — `ExternalPlayHandler` 内使用同一进度对话框（流式代理启动阶段为不定进度态，降级解密时显示百分比）
- **应用内播放全量解密回退** — 播放页 loading 视图内显示线性进度条，setState 同样按整数百分比节流

### 存储与文件管理

- **`StorageService`** — 管理加密视频目录（`MewTool/LockVideo/`）和解密导出目录（`MewTool/UnLockVideo/`），扫描 `.enc` 文件，维护 `.folders.json` 元数据，统计存储使用量。支持视频移动/重命名/文件夹 CRUD、孤儿缩略图清理
- **`PlaybackCacheManager`** — 播放磁盘缓存管理：缓存完整性校验（文件大小比对 + 64 字节文件头非零验证，拦截全零脏缓存）、过期清理（3 天）、LRU 总量淘汰（上限 500MB）
- **`ThumbnailService`** — 生成缩略图（.tenc 加密格式），提取视频首帧，GIF 格式检测，磁盘缓存管理。后台通过部分解密（前 30MB）从加密视频生成缩略图，避免全量解密开销
- **`PathProviderService`** — 统一路径管理，提供 LockVideo / UnLockVideo / Cache / ThumbCache 四个目录的路径
- **`SafeDeleteHelper`** — 安全删除：零覆写（1MB 块，append 模式打开避免 O_TRUNC 截断导致覆写失效）+ 指数退避重试（3s→6s→12s→24s→30s），另有快速删除模式（3 次简单重试）用于播放缓存临时文件

### Android 原生通信

`MainActivity.kt` 通过 `MethodChannel("com.snplayer.sn_player/file")` 提供两个原生通道：

- **openFile** — 使用第三方播放器打开文件：FileProvider → `Uri.fromFile` fallback，精确 MIME 映射（10 种视频格式），`Intent.createChooser` 弹出播放器选择
- **openFolder** — 打开文件管理器到指定目录：三级降级策略（`file://` URI → SAF `content://` URI → `ACTION_OPEN_DOCUMENT_TREE` + `EXTRA_INITIAL_URI`）

权限模型：声明 `MANAGE_EXTERNAL_STORAGE` 用于完全文件访问，`file_paths.xml` 配置 FileProvider 共享路径。

### 权限管理（PermissionService）

Android 三级权限回退策略：
1. `manageExternalStorage`（Android 11+ 完全文件访问）
2. `storage`（传统存储权限）
3. `videos`（媒体访问权限，最低要求）

### Design Token 体系

`lib/theme/` 提供完整的语义化 Design Token，禁止在页面/组件中硬编码样式值：

| Token 文件 | 内容 |
|-----------|------|
| `app_colors.dart` | 语义化颜色（brand/success/warning/error/background/surface）+ 8 种文件夹预设色 |
| `app_spacing.dart` | 8 级间距（4/6/8/12/16/20/24/32px） |
| `app_radius.dart` | 7 级圆角（4/6/8/12/16/20/24/9999px） |
| `app_font_size.dart` | 5 级字号（12/14/16/18/20px） |
| `app_duration.dart` | 动画时长（standard 120ms / slow 300ms） |
| `app_sizes.dart` | 图标和按钮尺寸 |
| `app_theme.dart` | Indigo 蓝紫双主题（Material 3），Card 无阴影用 border 替代 |

### 播放器组件架构

播放器由四个自建组件构成（未引入 chewie 等第三方播放器 UI 库，以保持加密工作流兼容性）：

- **PlayerControls** — 底部控制栏（始终可见）：倍速切换（左侧）、播放/暂停（中心圆形按钮）+ ±10s 跳过、全屏（右侧）。播放按钮含 500ms 重试机制（流式代理下 seek 后可能暂停）
- **PlayerGesture** — 手势层：单击切换播放/暂停、双击左右半区 ±10s 跳过（带反馈动画）、水平滑动粗粒度 seek、垂直滑动细粒度 seek（2x 速度）。拖动时不实时 seek（避免加密视频频繁 seek 卡死），仅显示位置预览浮层，松手才真正 seek。seek 后 100ms 延迟恢复播放
- **PlayerProgressBar** — 进度条：ExoPlayer 缓冲区域显示（灰色分段）、点击跳转、拖动 seek（实时预览）、时间显示含小时格式（h:mm:ss）
- **SpeedSelector** — 倍速选择底部弹窗（0.5x / 0.75x / 1.0x / 1.25x / 1.5x / 2.0x 六档），当前速度高亮，选中自动关闭

### 关键代码规范

- **if 语句必须有花括号 `{}`**，即使只有一行语句也不能省略（lint 规则强制执行）
- **禁止私自执行 `flutter build` 构建项目**，太慢太卡，由用户自行验证
- 缩略图采用**分批懒加载**策略：只加载可视区内的视频缩略图，滚动时动态加载新进入视口的
- 后台缩略图生成使用队列机制，避免并发生成导致性能问题

### 强制规则：文件头注释

所有 `.dart` 文件顶部必须包含注释，简要说明文件功能。禁止遗漏或写 "TODO" 占位。生成文件（如 `*.g.dart`、`generated_plugin_registrant.dart`）不在此规则适用范围内。

格式：

```dart
// lib/services/xxx.dart — 文件功能说明
```

或单行（较短）：

```dart
// 文件功能说明
```

### 强制规则：单文件行数上限

单文件代码行数是衡量可维护性的关键指标。超过阈值必须拆分重构。

#### 分级标准

| 级别 | 行数范围 | 评价 |
|------|---------|------|
| 理想 | ≤ 200 行 | 职责单一，易读易维护 |
| 可接受 | 200 ~ 300 行 | 轻微超限，可留可不拆 |
| 需要关注 | 300 ~ 500 行 | 建议重构，考虑拆分 |
| 严重超标 | 500 ~ 1000 行 | 强烈建议拆分 |
| 必须重构 | ≥ 1000 行 | 不可维护，必须拆分 |

#### 不同场景建议

**UI 层（screens/、widgets/）：**

- 理想范围：200 ~ 300 行
- 可接受：300 ~ 500 行
- 超过 500 行 → 应拆分：提取子 Widget、将大段 `build` 逻辑拆为私有方法或独立组件文件

**业务类/服务层（services/、providers/）：**

- 理想范围：200 ~ 400 行
- 单一职责原则下，一个类不应超过 300 行
- 超过 800 行 → 几乎必然违反单一职责原则

**单一方法/函数：**

- 最佳实践：≤ 30 行（Rule of 30）
- 超过 50 行 → 应考虑提取子函数（`build` 方法尤其如此）

> ESLint 参考：`max-lines` 规则默认建议 300 行触发警告（跳过空行与注释）。

#### 关键考量：不只看行数

行数只是表象，真正需要优化的判断标准包括：

| 指标 | 阈值 |
|------|------|
| 行数 | > 300 行应警觉，> 500 行必须拆 |
| 圈复杂度 | 单个函数 > 10 ~ 15 |
| 嵌套深度 | 超过 4 层 |
| 职责数量 | 一个文件做 > 1 件事 |
| PR 变更行数 | > 400 行 reviewers 开始丧失注意力 |

#### 快速判断法

问自己 3 个问题：

1. **滚轮滑多少次才能看完？** — 超过 3~4 屏（约 300 行）就有问题
2. **能用一个短句说清它的职责吗？** — 如果不能，职责太多
3. **改了需求 A，会不小心影响 B 吗？** — 如果是，耦合太高

**结论**：300 行是警戒线，500 行是必须优化的硬阈值，1000 行以上属于不可维护代码。但更重要的是职责是否单一，而非机械按行数拆分。

### 强制规则：模块提取判定标准

> 核心原则：**重复远比错误抽象便宜。在同一个问题出现 3 次之前，不要抽象。** — Sandi Metz, The Wrong Abstraction (2016)

提取独立文件（模块化）不是"越拆越好"。错误的抽象比重复更难维护——它会固化错误的假设，让后续修改束手束脚。以下规则用于判断**什么条件下必须提取**以及**什么条件下不应提取**。

#### Flutter Widget 提取判定（widgets/ 目录）

**必须提取（高置信度）**

| 条件 | 说明 | 引用 |
|------|------|------|
| 被 2 个以上父 Widget/页面复用 | DRY 原则的最小触发阈值。仅 1 处使用的 Widget 不应提取为独立文件（除非满足以下其他条件） | Rule of Three |
| 文件超过 500 行硬阈值 | 见上方「单文件行数上限」规则 | 项目硬规则 |
| 含有独立复杂的内部状态管理（StatefulWidget 有 ≥3 个状态字段 + 对应的操作方法） | 构成一个可独立理解、独立测试的 UI 概念单元 | 单一职责原则 |
| 通过"紧密耦合组件"测试 | 子 Widget 在父 Widget 语境下有明确独立的子领域含义，且不是单纯的外观包装（如 `VideoCard` 之于 `VideoListScreen`） | Vue 官方风格指南 § 紧密耦合组件（理念通用） |

**不应提取（过度模块化）**

| 条件 | 说明 |
|------|------|
| 仅被 1 个父 Widget 使用且是薄壳包装 | 仅含 `child` 透传 + 极简状态（≤2 个状态字段）+ 简单样式外壳。提取后父 Widget 反而更难阅读（需跨文件跳跃理解完整 UI 流） |
| Widget ≤80 行且无独立业务逻辑 | 拆分带来的文件碎片化成本超过可读性收益；优先在同文件内提取私有 Widget 类或 build 子方法 |
| 仅是对原生 Widget 的简单封装 | 如 `Container` 包一层 `child`，没有独立的数据/行为逻辑 |
| 提取后父 Widget 反而更难阅读 | 代码阅读者需要在 2 个文件间来回跳跃才能理解一个完整的 UI 区域 |

> 反面案例（参考）：一个仅被 1 个父组件使用、~50 行、仅含 1 个展开状态 + 切换函数 + 内容透传的折叠区组件。无独立业务逻辑，是典型的薄壳包装，应合并回父组件。

**补充指引**

- **单例组件**（每页只用一次，如全局侧边栏/顶栏）：虽然只出现一次，但代表一个完整的独立 UI 区域（含自己的布局/样式/状态），应独立成文件
- **基础组件**（纯展示、通用可复用，如通用按钮/空态占位）：即使暂时只用一次，因其通用可复用性质，应独立成文件
- **同文件私有 Widget 优先**：仅在当前页面使用、无复用前景的子块，优先提取为同文件内的私有 `_XxxWidget` 类，而非新建 widgets/ 文件
