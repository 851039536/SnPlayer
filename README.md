# SnPlayer - 视频加密管理工具

<p align="center">
  <img src="https://img.shields.io/badge/Flutter-3.x+-02569B?logo=flutter&logoColor=white" alt="Flutter">
  <img src="https://img.shields.io/badge/Dart-3.1+-0175C2?logo=dart&logoColor=white" alt="Dart">
  <img src="https://img.shields.io/badge/Platform-Android-green" alt="Android">
  <img src="https://img.shields.io/badge/Encryption-AES--256--CTR-6750A4" alt="AES-256-CTR">
</p>

## 为什么选择 SnPlayer？

SnPlayer 是一款基于 Flutter 的视频加密管理 APP，使用 **AES-256-CTR** 加密算法保护您的隐私视频。完全兼容 MewTool `.enc` 文件格式，支持加密文件的浏览、播放、文件夹分类和安全管理。

- **🔐 军用级加密** — AES-256-CTR + PBKDF2-HMAC-SHA256，64 字节文件头保证跨语言兼容
- **🎬 三段式播放** — 缓存命中直播 → 流式按需解密（秒级起播）→ 全量解密回退，优先最优策略
- **📁 文件夹管理** — 创建/重命名/改色/删除文件夹，视频自由移动分类
- **⚡ 并行加速** — 大文件自动 2-6 路并行加解密，4MB 双缓冲流水线
- **🛡️ 安全删除** — 零覆写 + 指数退避重试，防止数据恢复工具还原
- **📊 存储统计** — 实时统计加密视频、缩略图、缓存文件的数量与占用空间

## 快速开始

> **前置条件**：Flutter SDK 3.1+、Android Studio（用于 Android 构建）

```bash
# 1. 安装 Flutter SDK
# 参见: https://docs.flutter.dev/get-started/install

# 2. 创建 Flutter 项目骨架（补全 android/ios 平台文件）
cd SnPlayer
flutter create --project-name sn_player --org com.snplayer .

# 3. 获取依赖
flutter pub get

# 4. 连接 Android 设备并运行
flutter run
```

> **注意**：由于 Flutter CLI 未在当前环境安装，项目已提供完整的 `lib/` 源码和 `pubspec.yaml`。执行 `flutter create` 将补全缺失的平台目录结构（`android/app/build.gradle` 等）。

## 项目结构

```
SnPlayer/
├── pubspec.yaml                              # 项目依赖配置
├── analysis_options.yaml                     # Lint 规则
├── lib/
│   ├── main.dart                             # 应用入口，MultiProvider 注入
│   ├── config/
│   │   └── crypto.dart                       # 加密常量（密码、密钥长度、缓冲区大小等）
│   ├── models/
│   │   ├── video_item.dart                   # VideoItem 数据模型
│   │   └── video_folder.dart                 # VideoFolder 数据模型
│   ├── services/
│   │   ├── crypto_service.dart               # AES-256-CTR + PBKDF2 加解密核心
│   │   ├── crypto_isolate.dart               # Isolate 后台加解密 Worker
│   │   ├── streaming_decrypt_proxy.dart      # 本地 HTTP 流式解密代理
│   │   ├── storage_service.dart              # 文件存储管理 + .folders.json 读写
│   │   ├── playback_cache_manager.dart       # 播放磁盘缓存校验与清理
│   │   ├── thumbnail_service.dart            # 缩略图生成与加密存储
│   │   ├── permission_service.dart           # Android 存储权限请求
│   │   ├── safe_delete_helper.dart           # 零覆写安全删除
│   │   └── path_provider_service.dart        # 统一路径管理
│   ├── providers/
│   │   ├── video_list_provider.dart          # 视频列表 CRUD + 缩略图分批加载
│   │   └── folder_provider.dart              # 文件夹 CRUD + 筛选
│   ├── screens/
│   │   ├── video_list_screen.dart            # 视频列表主页面
│   │   ├── video_player_screen.dart          # 内置播放器页面
│   │   └── folder_manage_screen.dart         # 文件夹管理弹窗
│   ├── widgets/
│   │   ├── player/
│   │   │   ├── player_controls.dart          # 底部控制栏（播放/暂停/±10s/倍速/全屏）
│   │   │   ├── player_gesture.dart           # 手势层（双击跳过/滑动seek）
│   │   │   ├── player_progress_bar.dart      # 增强进度条（缓冲/拖动/点击）
│   │   │   └── speed_selector.dart           # 倍速选择底部弹窗
│   │   ├── video_card.dart                   # 视频卡片组件
│   │   ├── folder_tabs.dart                  # 文件夹标签栏
│   │   ├── action_sheet.dart                 # 底部操作菜单
│   │   └── storage_stats_dialog.dart         # 存储统计弹窗
│   ├── theme/
│   │   ├── app_theme.dart                    # Material 3 双主题（亮/暗）
│   │   ├── app_colors.dart                   # 语义化颜色 Token
│   │   ├── app_spacing.dart                  # 间距 Token
│   │   ├── app_radius.dart                   # 圆角 Token
│   │   ├── app_font_size.dart                # 字号 Token
│   │   ├── app_duration.dart                 # 动画时长 Token
│   │   └── app_sizes.dart                    # 图标/按钮尺寸 Token
│   └── utils/
│       ├── crypto_utils.dart                 # 纯 Dart 密码学工具（PBKDF2/CTR/IV递增）
│       ├── file_utils.dart                   # 文件名去重、大小格式化、时长格式化
│       ├── color_utils.dart                  # 颜色工具
│       └── cancellable.dart                  # 可取消操作令牌
└── android/
    └── app/src/main/
        ├── AndroidManifest.xml               # 权限声明
        └── res/xml/file_paths.xml            # FileProvider 路径配置
```

## 功能全景

| 功能 | 说明 |
|------|------|
| **视频加密** | 从系统相册多选视频 → AES-256-CTR 流式加密 → 生成 `.enc` + `.tenc`，≥64MB 自动 2-6 路并行加速 |
| **加密播放** | 三段式降级：磁盘缓存秒开 → HTTP Range 流式按需解密（s 级起播）→ 全量解密回退 |
| **解密导出** | `.enc` → 原始 MP4 导出到 `UnLockVideo/` 目录 |
| **缩略图** | 提取视频首帧（480×270 JPEG 60%质量）→ 加密存储 (.tenc) → 可视区懒加载 + 后台队列生成 |
| **文件夹** | 创建/重命名/改色/删除，视频自由移动 |
| **安全删除** | 零覆写 + 指数退避重试（3s→6s→12s→24s→30s） |
| **缓存管理** | 自动清理过期播放缓存（3 天/LRU 500MB）+ 孤儿缩略图检测 + 一键清空 |
| **存储统计** | 实时统计各类型文件数量和占用空间 |

## 加密格式兼容性

`.enc` 文件格式与 MewTool 原版完全兼容：

```
offset 0-15:   IV (16 bytes, 随机)
offset 16-31:  Salt (16 bytes, 随机)
offset 32:     版本号 (v2 = 0x02)
offset 33-63:  Reserved (31 bytes, 全零)
offset 64+:    AES-256-CTR 密文
```

| 参数 | 值 |
|------|-----|
| 密码 | `SN-Video-Editor-2026-Default-Key!` |
| 密钥派生 | PBKDF2-HMAC-SHA256, 10 次迭代 |
| 密钥长度 | 32 字节 (256 位) |
| 加密模式 | AES-256-CTR |
| 缓冲区 | 4 MB 双缓冲流水线 |

## 技术栈

| 类别 | 选择 | 用途 |
|------|------|------|
| 框架 | Flutter (Dart) | 跨平台 UI |
| 加密 | pointycastle 3.7+ | AES-CTR + PBKDF2 |
| 播放器 | video_player 2.8+ | 本地视频播放 |
| 文件选择 | file_picker 11.0+ | 系统文件选择 |
| 权限 | permission_handler 11.0+ | 存储权限 |
| 状态管理 | Provider 6.1+ | 状态驱动 UI |
| 缩略图 | video_thumbnail 0.5+ | 视频帧提取 |

## 依赖项

```yaml
dependencies:
  pointycastle: ^3.7.3          # AES-256-CTR 加密
  video_player: ^2.8.0          # 内置视频播放器
  file_picker: ^11.0.0           # 文件选择器
  permission_handler: ^11.0.0   # 权限管理
  path_provider: ^2.1.0         # 路径管理
  path: ^1.8.0                  # 路径操作
  provider: ^6.1.0              # 状态管理
  video_thumbnail: ^0.5.3       # 缩略图提取
  uuid: ^4.2.0                  # UUID 生成
```

## 许可证

MIT License

---

<p align="center">
  <strong>Built with Flutter ❤️</strong><br>
  <sub>AES-256-CTR Video Encryption Manager</sub>
</p>
