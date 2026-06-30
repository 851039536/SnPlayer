---
name: snplayer-thumbnail-refactor
overview: 彻底重构视频封面系统：磁盘缓存 Image.file 替代 Image.memory + 可视区懒加载 + 缩略图分辨率缩减 + 过期清理，不保证向后兼容，内存从 25MB 降至 ~500KB。
todos:
  - id: p0-model-config
    content: P0 数据模型与配置：VideoItem.coverData 改为 thumbCachePath，crypto.dart 新增 thumbCache 常量并缩分辨率 192x108
    status: completed
  - id: p0-service-provider
    content: P0 服务层与 Provider：path_provider 新增 getThumbCacheDir，thumbnail_service 新增 decryptThumbnailToCache，video_list_provider 重写 loadThumbnails 写磁盘
    status: completed
    dependencies:
      - p0-model-config
  - id: p0-widget
    content: P0 Widget 层：video_card 从 Image.memory 改为 Image.file + cacheWidth/cacheHeight
    status: completed
    dependencies:
      - p0-model-config
  - id: p1-lazy-load
    content: P1 可视区懒加载：video_list_screen 新增 ScrollController + _onScroll，video_list_provider 新增 loadVisibleThumbnails
    status: completed
    dependencies:
      - p0-service-provider
  - id: p2-cleanup
    content: P2 过期清理：safe_delete_helper 新增 cleanupExpiredThumbnails，thumbnail_service 新增 cleanupExpiredCache，删除视频时同步清理缓存
    status: completed
    dependencies:
      - p0-model-config
---

## 产品概述

重构 SnPlayer 视频列表封面展示架构，解决当前 `Image.memory(Uint8List)` 方案导致的内存占用过高问题。当前 100 个视频会固定占用 20-25MB（JPEG 5MB + 解码纹理 15-20MB），且所有缩略图预加载，未滚到也占用内存。

## 核心功能

### P0：磁盘缓存替代内存持有

- 解密缩略图时直接写入 `thumb_cache/` 目录作为 JPEG 文件，不再将 `Uint8List` 保存在 `VideoItem.coverData` 中
- `VideoCard` 使用 `Image.file()` 替代 `Image.memory()`，利用 Flutter 内置 `ImageCache`（上限 100MB/100张，自动 LRU 淘汰）管理内存
- `VideoItem.coverData (Uint8List?)` 改为 `thumbCachePath (String?)`，仅存储文件路径

### P1：可视区懒加载

- `video_list_screen.dart` 新增 `ScrollController`，通过 `_onScroll` 回调计算当前可视区域内的视频索引范围
- `video_list_provider.dart` 新增 `loadVisibleThumbnails(start, end)` 方法，仅加载可视区及上下各一屏预加载区的缩略图
- 远离子视口的卡片显示占位符（渐变色图标），不持有任何缩略图数据

### P2：分辨率缩减与过期清理

- `thumbnailWidth` 从 280 降至 192，`thumbnailHeight` 从 150 降至 108（仍保持 16:9 比例，匹配网格卡片约 184px 的实际显示宽度）
- `Image.file()` 配合 `cacheWidth: 192, cacheHeight: 108` 提示解码器以显示尺寸解码，单张解码内存从约 150KB 降至约 40KB
- `ThumbnailService.cleanupExpiredCache()` 自动清理 7 天未访问的 `thumb_cache/` 文件

## 性能收益

| 指标 | 现方案 | 重构后 |
| --- | --- | --- |
| 100视频缩略图内存 | ~25MB（固定） | ~500KB（按需） |
| 滚动时加载数 | 100张全部 | 8-12张（可见+预加载） |
| 单张解码内存 | ~150KB | ~40KB |


## 技术栈

- Flutter 3.x + Dart，Provider 状态管理
- `path_provider` 获取临时目录
- `video_thumbnail` 生成缩略图
- 无新增第三方依赖

## 实现方案

### 核心设计决策

**为什么用 `Image.file` + `cacheWidth/cacheHeight` 而不是自定义 LRU Map？**

Flutter 内置 `ImageCache` 是经过充分测试的工业级方案，默认上限 100MB/100张图片，按 LRU 策略自动淘汰。`Image.file()` 加载后自动将解码纹理注册到 `ImageCache`，页面 pop 时自动释放。无需自己维护 Map、手动清理。

**为什么可视区懒加载用 `ScrollController` 而不是 `ScrollablePositionedList`？**

当前 `SliverGrid` + `SliverChildBuilderDelegate` 已经是惰性构建（不在视口的 Widget 不会 build），但缩略图数据 (`coverData`) 存储在 Provider 的 `VideoItem` 中，与 Widget 生命周期无关。需要通过可见性通知来决定何时加载/卸载缩略图路径。`ScrollController.addListener` 是 Flutter 推荐的轻量方案，无需引入额外 package。

**为什么不兼容旧的 `.enc` 缩略图文件？**

用户明确不需要向后兼容。旧的 `.tenc` 文件仍然存在并可用于播放，但列表中的缩略图展示会使用新的 `thumb_cache/` 缓存机制。如果旧缓存不存在，`decryptThumbnailToCache()` 会自动解密 `.tenc` 生成新缓存文件。已有视频无需重新加密。

### 数据流变更

```
旧流程:
  .tenc → loadThumbnail() → Uint8List → video.coverData → Image.memory()

新流程:
  .tenc → decryptThumbnailToCache() → thumb_cache/{id}.jpg → video.thumbCachePath → Image.file(cachePath, cacheWidth:192, cacheHeight:108)
                                                                      ↓
                                                          Flutter ImageCache 自动管理
```

### 关键代码结构

**VideoItem 模型变更：**

```
// 旧
Uint8List? coverData;

// 新
String? thumbCachePath;  // thumb_cache/ 下的 JPEG 文件路径
```

**VideoCard 缩略图变更：**

```
// 旧
if (video.coverData != null)
  Image.memory(video.coverData!, fit: BoxFit.cover)

// 新
if (video.thumbCachePath != null)
  Image.file(File(video.thumbCachePath!),
    fit: BoxFit.cover,
    cacheWidth: thumbnailWidth,
    cacheHeight: thumbnailHeight,
    errorBuilder: (_, __, ___) => _buildPlaceholder(colorScheme),
  )
```

**可见性检测核心逻辑：**

```
// video_list_screen.dart
void _onScroll() {
  final renderBox = _gridKey.currentContext?.findRenderObject() as RenderSliverGrid?;
  if (renderBox == null) return;
  // 根据 scrollOffset 和 viewport 高度计算可见视频索引范围
  final firstVisible = ...;
  final lastVisible = ...;
  provider.loadVisibleThumbnails(
    max(0, firstVisible - _preloadCount),
    min(totalCount, lastVisible + _preloadCount),
  );
}
```

## 实现注意事项

- **禁止构建验证**：按项目规则不执行 `flutter build`，修改后由用户自行验证
- **if 花括号**：严格遵守项目代码风格规则，if 语句必须有花括号
- **加密流程零改动**：`.tenc` 文件仍然通过 `encryptBytes/decryptBytes` 生成和读取，`decryptThumbnailToCache()` 内部调用已有函数
- **安全删除保留**：删除视频时仍使用 `SafeDeleteHelper.safeDelete()` 销毁 `.enc` 和 `.tenc`，同时清理对应的 `thumb_cache/` 文件