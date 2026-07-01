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

首页为 `VideoListScreen`，支持 Material 3 双主题（light/dark），跟随系统 `ThemeMode.system`。

### 加密核心（services/crypto_service.dart）

加密算法：**AES-256-CTR + PBKDF2-HMAC-SHA256（100,000 次迭代）**

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
- **重要**：`encryptFile` 在 2026-07-01 被强制改为串行 Isolate 加密。原先存在并行加密路径（`_runParallelEncrypt`），但其产物文件头版本字节（偏移 32）实际为 0x00 而非预期的 0x02，导致 App 和第三方程序均解密失败。根因尚未确定（代码审查两条路径的写入逻辑均正确），暂用串行路径规避。**并行加密代码保留在文件中但不应被启用**，除非找到并修复根因。
- 密钥派生结果使用 LRU 缓存（容量 100），避免重复 PBKDF2 计算。
- `crypto_isolate.dart` 是 Isolate Worker，在独立线程中执行 encrypt/decrypt 命令，采用双缓冲流水线（4MB 缓冲区）。
- `utils/crypto_utils.dart` 是纯 Dart 的密码学工具函数，不依赖 Flutter/Isolate，可跨平台使用。

### 视频播放策略（三段式降级）

`VideoPlayerScreen` 加载视频时按以下优先级尝试：

1. **磁盘缓存命中** — 如果之前解密过且有有效缓存文件，直接使用本地缓存路径播放
2. **流式解密代理** — 启动本地 HTTP 代理服务器（`StreamingDecryptProxy`），按需解密视频块（512KB），支持 HTTP Range 请求实现 seek。代理使用内存 LRU 块缓存（128 块 = 64MB），带节流机制
3. **全量解密回退** — 当前两种方式不可用时，解密整个文件到临时目录再播放

播放缓存管理（`PlaybackCacheManager`）：缓存最多保留 3 天，LRU 淘汰上限 500MB，每次启动自动清理过期缓存。

### 存储与文件管理

- **`StorageService`** — 管理加密视频目录（`LockVideo/`）和解密导出目录（`UnLockVideo/`），扫描 `.enc` 文件，维护 `.folders.json` 元数据，统计存储使用量
- **`ThumbnailService`** — 生成缩略图（.tenc 加密格式），提取视频首帧，GIF 格式检测，磁盘缓存管理
- **`PathProviderService`** — 统一路径管理，提供 LockVideo / UnLockVideo / Cache / ThumbCache 四个目录的路径
- **`SafeDeleteHelper`** — 安全删除：零覆写 + 指数退避重试（3s→6s→12s→24s→30s），另有快速删除模式用于临时文件

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

- **PlayerControls** — 底部控制栏：播放/暂停、±10s 跳过、倍速切换、全屏，4 秒自动隐藏渐隐动画
- **PlayerGesture** — 手势层：双击左右半区 ±10s 跳过、水平滑动 seek、垂直滑动细粒度 seek
- **PlayerProgressBar** — 进度条：缓冲区域显示（灰色）、点击跳转、拖动 seek、时间显示含小时
- **SpeedSelector** — 倍速选择底部弹窗（0.5x / 0.75x / 1.0x / 1.25x / 1.5x / 2.0x 六档）

### 关键代码规范

- **if 语句必须有花括号 `{}`**，即使只有一行语句也不能省略（lint 规则强制执行）
- **禁止私自执行 `flutter build` 构建项目**，太慢太卡，由用户自行验证
- 缩略图采用**分批懒加载**策略：只加载可视区内的视频缩略图，滚动时动态加载新进入视口的
- 后台缩略图生成使用队列机制，避免并发生成导致性能问题
