---
name: open-video-storage-path
overview: 在视频操作菜单（ActionSheet）中新增"打开存储路径"选项，点击后用系统文件管理器打开加密视频文件所在的文件夹。
todos:
  - id: add-native-openfolder
    content: 在 MainActivity.kt 中新增 openFolder MethodChannel 分支，实现路径校验 + Intent 打开文件夹
    status: completed
  - id: add-dart-action-item
    content: 在 video_list_screen.dart 的 _showVideoActions 菜单列表中添加「打开存储路径」选项
    status: completed
    dependencies:
      - add-native-openfolder
  - id: add-dart-openstorage-method
    content: 在 video_list_screen.dart 新增 _openStoragePath 方法，提取父目录并调用原生 openFolder
    status: completed
    dependencies:
      - add-native-openfolder
---

## 用户需求

在视频卡片长按/点击后弹出的操作菜单（ActionSheet）中，新增一项"打开存储路径"功能。点击后调用系统文件管理器，自动定位到当前加密视频文件（.enc）所在的文件夹目录。

## 核心功能

- 操作菜单新增"打开存储路径"选项，图标使用 `Icons.folder_open_rounded`
- 点击后获取 `VideoItem.encPath` 的父目录路径
- 通过 MethodChannel 调用 Android 原生 `openFolder` 方法
- 系统自动弹出文件管理器并定位到目标文件夹

## 技术方案

### 实现思路

沿用现有 `openFile` 的 MethodChannel 通信模式，新增 `openFolder` 方法。Dart 侧通过 `intent://` 无法直接文件夹的 limitations，故采用原生 Intent `ACTION_VIEW` + type `resource/folder` 的方式打开系统文件管理器并定位到指定目录。

### 改动清单

**1. MainActivity.kt — 新增 openFolder 分支**

在 `setMethodCallHandler` 的 if-else 链中，于 `openFile` 分支之后新增 `else if (call.method == "openFolder")`：

```
else if (call.method == "openFolder") {
    val path = call.argument<String>("path")
    if (path == null) {
        result.error("NO_PATH", "path is null", null)
        return@setMethodCallHandler
    }
    try {
        val folder = File(path)
        if (!folder.exists() || !folder.isDirectory) {
            result.error("FOLDER_NOT_FOUND", "folder not found: $path", null)
            return@setMethodCallHandler
        }
        val uri = Uri.fromFile(folder)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "resource/folder")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        // Check if any app can handle
        if (packageManager.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY) == null) {
            result.error("NO_FILE_MANAGER", "no file manager installed", null)
            return@setMethodCallHandler
        }
        startActivity(Intent.createChooser(intent, "打开文件夹"))
        result.success(true)
    } catch (e: Exception) {
        result.error("OPEN_FOLDER_FAILED", e.message, null)
    }
}
```

**2. video_list_screen.dart — 两处改动**

改动 A：在 `_showVideoActions()` 菜单项列表中，「移动到文件夹」之后、「删除」之前插入新项：

```
// 打开存储路径
ActionSheetItem(
  icon: Icons.folder_open_rounded,
  label: '打开存储路径',
  onTap: () => _openStoragePath(video),
),
```

改动 B：新增 `_openStoragePath` 方法（放在其他交互方法附近，如 `_moveVideo` 之后）：

```
Future<void> _openStoragePath(VideoItem video) async {
  try {
    final parentDir = File(video.encPath).parent.path;
    await _fileChannel.invokeMethod('openFolder', {'path': parentDir});
  } on PlatformException catch (e) {
    debugPrint('[SnPlayer] _openStoragePath: code=${e.code}, msg=${e.message}');
    if (mounted) {
      final msg = switch (e.code) {
        'NO_FILE_MANAGER' => '未找到文件管理器',
        'FOLDER_NOT_FOUND' => '文件夹不存在',
        _ => '打开失败',
      };
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  } catch (e) {
    debugPrint('[SnPlayer] _openStoragePath: $e');
  }
}
```

### 无需修改的文件

- `action_sheet.dart` — ActionSheet 组件本身无需改动，仅消费端新增数据项
- `video_item.dart` — 数据模型无需改动，直接使用已有 `encPath` 字段
- `file_paths.xml` — 打开文件夹不需要 FileProvider content URI