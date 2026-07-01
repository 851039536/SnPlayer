# SnPlayer 项目记忆

## 项目概述
- Flutter Android 视频加密播放器
- 核心功能：视频文件加密存储、播放、解密导出、第三方播放

## 技术要点

### Android 原生
- MainActivity.kt 通过 MethodChannel ("com.snplayer.sn_player/file") 提供 openFile/openFolder 两个原生通道
- openFile：FileProvider → Uri.fromFile fallback，精确 MIME 类型映射（10种），createChooser 弹出播放器选择
- openFolder：三级降级策略（file:// URI → SAF content:// URI → ACTION_OPEN_DOCUMENT_TREE + EXTRA_INITIAL_URI）
- 权限模型：MANAGE_EXTERNAL_STORAGE 用于完全文件访问，file_paths.xml 配置 FileProvider 路径

### Dart 端
- 状态管理：Provider（VideoListProvider, FolderProvider）
- 加密：CryptoService（AES-256-CTR + PBKDF2 密钥派生）
- 视频列表页：VideoListScreen，懒加载缩略图，ActionSheet 菜单（播放/第三方播放/解密导出/重命名/移动/打开存储路径/删除）
- 播放器：自建组件（player_gesture, player_progress_bar, speed_selector, player_controls）

### 加密
- 2026-07-01：将 `CryptoService.encryptFile` 强制改为串行 Isolate 加密，移除并行路径。因并行加密（`_runParallelEncrypt`）产物的文件头版本字节（偏移 32）实际为 0x00 而非预期的 0x02，导致 App 和第三方程序均解密失败。根因未确定（代码审查两条路径写入逻辑均正确），暂用串行路径规避。并行加密代码保留未删除。

### 代码规范
- if 语句必须有花括号 `{}`，即使只有一行
- 禁止私自执行 `dotnet build`，修改完代码由用户自行验证
