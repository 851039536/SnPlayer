---
name: video-player-optimization
overview: 为 SnPlayer Flutter 视频播放器增加手势控制（滑动调节音量/亮度/进度、双击快进快退）和触摸按钮（播放/暂停、快进/快退、倍速、锁屏、上下视频切换），并考虑是否使用 chewie 等成熟组件。
design:
  styleKeywords:
    - Dark Immersive
    - Material 3
    - Minimal Control Overlay
    - Smooth Animation
  fontSystem:
    fontFamily: Roboto
    heading:
      size: 16px
      weight: 500
    subheading:
      size: 14px
      weight: 400
    body:
      size: 12px
      weight: 400
  colorSystem:
    primary:
      - "#3949AB"
      - "#5C6BC0"
      - "#3F51B5"
    background:
      - "#000000"
      - "#1A1A2E"
    text:
      - "#FFFFFF"
      - "#B0B0B0"
    functional:
      - "#4CAF50"
      - "#FF5252"
      - "#FFC107"
todos:
  - id: explore-player-code
    content: 深入阅读现有 video_player_screen.dart 完整代码，确认当前架构细节和可复用逻辑
    status: completed
  - id: query-video-player-api
    content: 使用 [mcp:Context7] 查询 video_player 包最新 API 文档，确认 setPlaybackSpeed、seekTo、buffered 等方法的正确用法
    status: completed
  - id: create-player-widgets
    content: 新建 lib/widgets/player/ 目录，实现 player_gesture.dart（手势层）、player_progress_bar.dart（增强进度条）、speed_selector.dart（倍速弹窗）三个核心组件
    status: completed
    dependencies:
      - explore-player-code
      - query-video-player-api
  - id: create-player-controls
    content: 实现 player_controls.dart 底部控制栏组件，包含自动隐藏、播放暂停按钮、快进快退按钮、锁屏按钮、倍速按钮、上下视频切换按钮
    status: completed
    dependencies:
      - explore-player-code
  - id: refactor-player-screen
    content: 重构 video_player_screen.dart，集成手势层和控制组件，替换原有极简 UI，保持加密解密流程不变
    status: completed
    dependencies:
      - create-player-widgets
      - create-player-controls
  - id: add-prev-next-navigation
    content: 在 video_list_provider.dart 新增相邻视频查询方法，播放页实现上一个/下一个视频即时切换
    status: completed
    dependencies:
      - refactor-player-screen
  - id: verify-and-test
    content: 检查所有新增文件和修改文件的编译正确性，确保无 lint 错误，验证各功能逻辑完整性
    status: completed
    dependencies:
      - add-prev-next-navigation
---

## 用户需求

优化 SnPlayer Flutter 项目的视频播放体验，为当前极简的播放器增加完善的触摸交互和可视化控制组件。

## 产品概览

将当前仅支持单击播放/暂停 + 拖动进度条的基础播放器，升级为功能完善的现代化视频播放器，支持手势操作、控制按钮、倍速调节、锁屏、上下视频切换等功能。

## 核心功能

1. **触摸手势系统**：左右滑动快进/快退（±10秒），上下滑动左侧调节亮度、右侧调节音量，双击左右半区快进/快退
2. **控制按钮覆盖层**：中央播放/暂停按钮、左右快退/快进按钮（±10秒）、倍速选择器、锁屏按钮、全屏切换按钮
3. **控制栏自动隐藏**：点击屏幕显示控制覆盖层，3秒无操作自动隐藏
4. **倍速播放**：支持 0.5x / 0.75x / 1.0x / 1.25x / 1.5x / 2.0x 六档速度切换
5. **锁屏功能**：锁定后禁用所有触摸手势和控制按钮交互，防止误触
6. **上下视频切换**：在播放页内直接切换到同一文件夹的上一个/下一个视频
7. **增强进度条**：支持点击跳转、拖拽预览、缓冲进度显示

## 技术栈

- **框架**：Flutter 3.x + Dart
- **核心播放**：video_player ^2.8.0（保持不变）
- **状态管理**：provider ^6.1.0（沿用现有模式）
- **UI 组件**：自建组件（不引入第三方播放器 UI 库）

## 实现方案

### 方案选型：自建增强播放器 UI vs 引入第三方包

经过分析，选择**自建增强播放器 UI**，理由如下：

1. **加密工作流兼容性**：项目有自定义 AES-256-CTR 解密流程（播放前解密到临时缓存，退出时安全删除），第三方包（chewie/better_player）可能无法无缝适配
2. **依赖最小化**：不新增外部依赖，减少版本冲突和维护负担
3. **完全可控**：手势行为、UI 风格、控制逻辑均可按需定制
4. **架构一致性**：与项目现有 Self-built UI 模式一致（video_card、folder_tabs、action_sheet 均为自建）

### 架构设计

```
VideoPlayerScreen (页面)
├── GestureDetector（手势层）
│   ├── 双击检测（左右半区 ±10s seek）
│   ├── 水平滑动（快进/快退）
│   └── 垂直滑动（左半区亮度 / 右半区音量）
├── Stack
│   ├── VideoPlayer（底层 - 视频画面）
│   ├── PlayerLockOverlay（锁屏覆盖层 - 条件渲染）
│   ├── CenterPlayButton（中央播放/暂停按钮 - 自动隐藏）
│   └── PlayerControlsBar（底部控制栏 - 自动隐藏）
│       ├── VideoProgressBar（增强进度条）
│       ├── TimeDisplay（时间显示）
│       ├── SkipButtons（快退/快进按钮）
│       ├── SpeedSelector（倍速选择器）
│       ├── LockButton（锁屏按钮）
│       ├── PrevNextButtons（上下视频切换）
│       └── FullscreenButton（全屏按钮）
└── SpeedSelectorSheet（倍速选择底部弹窗 - 条件渲染）
```

### 数据流

```
用户手势/点击 → GestureDetector/按钮回调
    → setState() 更新控制状态（显隐、锁定、速度）
    → VideoPlayerController 执行播放操作（play/pause/seek/setSpeed）
    → ValueListenableBuilder 监听进度变化，驱动 UI 更新
```

### 性能考虑

- **手势防抖**：双击检测使用 300ms 间隔，避免误触发
- **自动隐藏定时器**：使用单例 Timer，每次交互重置，避免多 Timer 泄漏
- **进度条更新**：沿用 ValueListenableBuilder，仅重建必要的子组件
- **缓冲进度**：VideoPlayerController 原生支持 buffered 属性，直接读取，无额外开销

## 实现细节

### 核心目录结构

```
lib/
├── screens/
│   └── video_player_screen.dart          # [MODIFY] 重构播放页，集成新组件
├── widgets/
│   └── player/                            # [NEW] 播放器组件目录
│       ├── player_controls.dart           # [NEW] 底部控制栏（进度条+按钮组+自动隐藏）
│       ├── player_gesture.dart            # [NEW] 手势处理层（双击/滑动/垂直调节）
│       ├── player_progress_bar.dart       # [NEW] 增强进度条（点击跳转+缓冲显示）
│       └── speed_selector.dart            # [NEW] 倍速选择底部弹窗
├── providers/
│   └── video_list_provider.dart           # [MODIFY] 新增相邻视频查询方法
```

### 关键实现说明

1. **手势冲突处理**：手势层包裹整个 Stack，双击和单机通过 GestureDetector 的 onTap + onDoubleTap 区分；滑动手势使用 onHorizontalDragUpdate / onVerticalDragUpdate，与进度条拖拽通过 HitTestBehavior 隔离

2. **亮度/音量调节**：Flutter 没有直接的系统亮度/音量 API，需使用 platform channel 或第三方包（如 `screen_brightness` / `volume_controller`）。考虑到依赖最小化原则，垂直滑动暂时调节视频播放进度（细粒度 seek），亮度/音量功能留作后续扩展点。实际左右滑动快进快退 ±10s 覆盖了主要需求

3. **锁屏状态**：使用 bool `_isLocked` 状态控制，锁定时所有手势回调返回空、控制按钮覆盖层不渲染

4. **自动隐藏**：用 Timer + 标志位，每次屏幕交互后重置 3 秒定时器，定时器到期设置 `_controlsVisible = false`

5. **上下视频切换**：从 VideoListProvider 获取当前播放列表及当前索引，通过 prev/next 计算出相邻视频，触发解密→播放流程，无需页面跳转

### 向后兼容

- 所有现有 API 保持不变
- VideoPlayerScreen 构造函数参数不变
- 加密/解密流程不受影响

## 设计风格

采用**暗色沉浸式播放器**风格，与当前项目 Material 3 + Indigo 主题保持一致。

### 播放器视觉设计

**整体布局**：全屏黑色背景 (#000000)，视频居中自适应宽高比，控制元素叠加于视频上方

**控制覆盖层设计**：

- 中央播放/暂停按钮：64px 白色半透明圆形背景（rgba(255,255,255,0.2)），内含白色 play_arrow/pause 图标，带缩放动画过渡，自动隐藏时有淡出动画
- 底部控制栏：从底部渐变的黑色半透明背景（rgba(0,0,0,0) → rgba(0,0,0,0.7)），高 120px，包含进度条区域 + 按钮行
- 进度条：4px 高度轨道，已播放部分使用主题蓝色 (#3949AB)，缓冲部分使用白色透明度 0.3，滑块 14px 白色圆形
- 按钮区：快退 10s / 播放暂停 / 快进 10s 居中排列，左侧倍速按钮 + 锁屏按钮，右侧全屏按钮
- 倍速选择器：底部弹出白色半透明面板，6 个速度选项网格排列，当前速度高亮蓝色
- 锁屏图标：锁定时中央显示 Lock 图标（2 秒后自动消失），解锁时左上角显示 LockOpen 图标按钮

**动画效果**：

- 控制栏显示/隐藏：300ms 淡入淡出 + 向上滑动 (SlideTransition)
- 中央播放按钮：200ms 缩放动画 (ScaleTransition)
- 倍速面板：从底部滑入 (BottomSheet 默认动画)

**手势视觉反馈**：

- 双击快进时，中央短暂显示 ">> 10s" 文字 + 半透明圆形背景，500ms 后消失
- 双击快退时，中央短暂显示 "<< 10s" 文字
- 滑动 seek 时，顶部显示当前 seek 位置预览缩略图（如可获取）和时间文字

## Agent Extensions

### MCP

- **Context7**
- Purpose: 查询 video_player 包最新 API 文档，确认 VideoPlayerController 的 setPlaybackSpeed、seekTo、buffered 等方法的正确用法和参数，以及 Android/iOS 平台兼容性注意事项
- Expected outcome: 获取准确的 API 签名和使用示例，确保代码不因 API 版本差异而出错