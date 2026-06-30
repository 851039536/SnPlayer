---
name: third-party-video-thumbnail-generation
overview: 为 LockVideo 目录中缺少 .tenc 缩略图的加密视频自动生成缩略图，使"第三方"导入的视频也能像加密导入流程一样显示封面图片。
todos:
  - id: add-generate-method
    content: 在 ThumbnailService 中新增 generateThumbnailFromEncrypted() 方法，实现从加密视频生成 .tenc 缩略图的完整流程
    status: completed
  - id: update-load-thumbnails
    content: 修改 VideoListProvider.loadThumbnails()，在 decryptThumbnailToCache 返回 null 且 .tenc 不存在时回退调用 generateThumbnailFromEncrypted()
    status: completed
    dependencies:
      - add-generate-method
  - id: verify-integration
    content: 验证完整链路：扫描含缺失缩略图的 .enc 视频，确认 loadThumbnails 能自动生成并显示缩略图
    status: completed
    dependencies:
      - update-load-thumbnails
---

## 用户需求

第三方 .enc 加密视频文件（直接放置在 LockVideo 目录中，没有对应 .tenc 缩略图）当前在视频列表中只显示渐变占位符图标，无法显示视频封面预览。需要让这些视频也能像通过 APP 加密导入的视频一样正常显示缩略图。

## 产品概述

SnPlayer 是一款加密视频管理播放器。用户可通过"选择视频加密"按钮导入视频（加密 + 生成缩略图），也可将已加密的 .enc 文件直接放入 LockVideo 目录。当前后者缺失缩略图生成环节。

## 核心功能

- **自动检测缺失缩略图**：扫描时识别 .enc 文件是否存在对应 .tenc 缩略图文件
- **回退缩略图生成**：对缺失 .tenc 的视频，解密视频 → 提取第 1 秒帧 → 生成 JPEG 缩略图 → 加密保存为 .tenc
- **增量处理**：仅处理缺失缩略图的视频，已有 .tenc 的视频直接使用缓存
- **与加密导入行为一致**：生成的缩略图格式、尺寸、质量与加密导入流程完全一致

## 技术栈

- **语言/框架**: Dart + Flutter
- **缩略图提取**: video_thumbnail 包 (ImageFormat.JPEG)
- **加解密**: 项目自研 CryptoService (AES-256-CTR + PBKDF2，兼容 MewTool .enc 格式)
- **状态管理**: ChangeNotifier (Provider)
- **配置常量**: lib/config/crypto.dart

## 实现方案

### 整体思路

在 `loadThumbnails()` 的现有流程中增加一层回退：当 `decryptThumbnailToCache()` 返回 null（.tenc 不存在导致解密失败）时，不直接放弃，而是调用新方法 `generateThumbnailFromEncrypted()` 从加密视频源文件重新生成 .tenc 缩略图。

### 关键设计决策

**1. .tenc 存在性检查时机**

- 在 `VideoListProvider.loadThumbnails()` 中，`decryptThumbnailToCache()` 返回 null 后，用 `File(video.thumbPath).exists()` 检查 .tenc 是否真实存在（因为 loadThumbnail 内部也检查 .tenc 存在性，此处再次检查是防御性编程，且 exist 为同步操作开销极低）
- 若 .tenc 不存在，调用生成流程；若存在但解密失败（数据损坏），也重走生成流程

**2. 生成流程**

```
decryptToTemp(encPath) → video_thumbnail 提取帧 → encryptBytes(jpeg) → 写入 .tenc → decryptThumbnailToCache 写缓存 → 删除临时解密文件
```

- 复用 `CryptoService.decryptToTemp()` 解密到 play_cache/ 临时目录
- 复用 `video_thumbnail` 提取第 1 秒帧（timeMs: 1000）
- 复用 `CryptoService.encryptBytes()` 加密 JPEG 数据
- 复用 `ThumbnailService.decryptThumbnailToCache()` 将解密后的 JPEG 写入 thumb_cache/
- 生成完成后 `File(tempPath).delete()` 清理临时文件，已有 30 秒自动清理作为兜底

**3. 性能考量**

- 解密整个视频开销大（对于大文件可能耗时数秒至数十秒），但仅对每个缺失 .tenc 的视频执行一次
- 批次大小保持 `thumbnailBatchSize = 3`，与现有机制一致
- 每批处理完成后 `notifyListeners()` 刷新 UI，让用户看到渐进式加载
- 支持 `CancellationToken` 取消，用户退出页面时中断

**4. 错误处理**

- 任何步骤失败均 catch 并 debugPrint 日志，不阻断其他视频处理
- 生成失败时 `thumbCachePath` 保持 null，VideoCard 继续显示占位符
- 不在 UI 层弹出 Toast（避免用户困惑），静默降级

## 实现细节

### 目录结构

```
lib/
├── services/
│   └── thumbnail_service.dart  # [MODIFY] 新增 generateThumbnailFromEncrypted() 静态方法
├── providers/
│   └── video_list_provider.dart # [MODIFY] loadThumbnails() 增加 .tenc 缺失回退逻辑
└── screens/
    └── video_list_screen.dart  # 无需改动（已 await loadThumbnails）
```

### 核心修改

**1. thumbnail_service.dart — 新增方法**

- `generateThumbnailFromEncrypted(String encPath, String thumbPath, String cacheDir, String videoId)` 
- 返回 `Future<String?>` — 成功返回 thumbCachePath，失败返回 null
- 内部调用链：`CryptoService.decryptToTemp(encPath, cacheDir)` → `extractThumbnail(tempPath)` → `CryptoService.encryptBytes(jpeg)` → 写 .tenc 文件 → `decryptThumbnailToCache(videoId, thumbPath, cacheDir)` → 删除 tempPath
- 复用现有常量 thumbnailWidth/thumbnailHeight/thumbnailQuality

**2. video_list_provider.dart — loadThumbnails() 修改**

- 在 `decryptThumbnailToCache()` 返回 null 的分支中，增加判断：

```
if (cachePath == null && !await File(video.thumbPath).exists()) {
cachePath = await ThumbnailService.generateThumbnailFromEncrypted(
video.encPath, video.thumbPath, cacheDir, video.id,
);
}
video.thumbCachePath = cachePath;
```

- 每批处理完成后 `notifyListeners()` 确保 UI 能看到新生成的缩略图
- 操作完整包裹在 try-catch 中防止单视频失败影响整批

## 代理扩展

### SubAgent

- **code-explorer**
- 目的：在生成技术方案前探索项目代码库，确认 CryptoService、ThumbnailService、VideoListProvider 的完整接口和调用链
- 预期产出：确认 decryptToTemp/encryptBytes/extractThumbnail 等方法的签名和参数，确保新方法集成无冲突