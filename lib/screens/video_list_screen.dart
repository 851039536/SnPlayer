import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/video_item.dart';
import '../providers/video_list_provider.dart';
import '../providers/folder_provider.dart';
import '../services/permission_service.dart';
import '../services/storage_service.dart';
import '../utils/file_utils.dart';
import '../widgets/video_card.dart';
import '../widgets/folder_tabs.dart';
import '../widgets/action_sheet.dart';
import '../widgets/storage_stats_dialog.dart';
import 'video_player_screen.dart';
import 'folder_manage_screen.dart';

/// 视频列表主页面
///
/// AppBar + 文件夹标签 + 视频卡片网格 + FAB + 底部状态栏
class VideoListScreen extends StatefulWidget {
  const VideoListScreen({super.key});

  @override
  State<VideoListScreen> createState() => _VideoListScreenState();
}

class _VideoListScreenState extends State<VideoListScreen> {
  bool _hasPermission = false;
  bool _isInitializing = true;

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    // 1. 请求权限
    final hasPerm = await PermissionService.requestStoragePermission();
    if (mounted) {
      setState(() { _hasPermission = hasPerm; });
    }

    if (!hasPerm) {
      setState(() { _isInitializing = false; });
      return;
    }

    // 2. 加载数据
    final folderProvider = context.read<FolderProvider>();
    final videoProvider = context.read<VideoListProvider>();

    await folderProvider.loadFolders();
    await videoProvider.loadVideos();
    videoProvider.loadThumbnails();

    if (mounted) {
      setState(() { _isInitializing = false; });
    }
  }

  @override
  void dispose() {
    context.read<VideoListProvider>().cancelThumbnailLoading();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (_isInitializing) {
      return Scaffold(
        backgroundColor: colorScheme.surface,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text('正在初始化...',
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }

    if (!_hasPermission) {
      return Scaffold(
        backgroundColor: colorScheme.surface,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.folder_off_rounded, size: 72,
                  color: colorScheme.onSurfaceVariant.withOpacity(0.5)),
                const SizedBox(height: 24),
                Text('需要存储权限才能访问视频文件',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text('请在设置中授予存储权限',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _initApp,
                  icon: const Icon(Icons.security_rounded),
                  label: const Text('授予权限'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      extendBody: true,
      appBar: _buildAppBar(),
      body: RefreshIndicator(
        onRefresh: () async {
          await context.read<VideoListProvider>().loadVideos();
        },
        child: CustomScrollView(
          slivers: [
            // 文件夹标签栏
            SliverToBoxAdapter(child: _buildFolderTabs()),
            // 视频列表
            _buildVideoGrid(),
            // 底部留白（给 FAB + 状态栏留空间）
            const SliverPadding(padding: EdgeInsets.only(bottom: 80)),
          ],
        ),
      ),
      floatingActionButton: _buildFab(),
      bottomNavigationBar: _buildBottomBar(),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      title: const Text(
        'SnPlayer',
        style: TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 22,
          letterSpacing: -0.5,
        ),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.cleaning_services_rounded, size: 20),
          tooltip: '清理缓存',
          onPressed: _cleanupCache,
        ),
        IconButton(
          icon: const Icon(Icons.storage_rounded, size: 20),
          tooltip: '存储统计',
          onPressed: _showStorageStats,
        ),
      ],
    );
  }

  Widget _buildFolderTabs() {
    return Consumer<FolderProvider>(
      builder: (context, folderProvider, _) {
        return FolderTabs(
          folders: folderProvider.folders,
          selectedFolder: folderProvider.selectedFolder,
          onSelect: (folderName) {
            folderProvider.selectFolder(folderName);
          },
          onManage: () => _showFolderManagement(folderProvider),
        );
      },
    );
  }

  Widget _buildVideoGrid() {
    return Consumer2<VideoListProvider, FolderProvider>(
      builder: (context, videoProvider, folderProvider, _) {
        final allVideos = videoProvider.getVideosInFolder(
          folderProvider.selectedFolder,
        );

        if (allVideos.isEmpty) {
          return SliverFillRemaining(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.video_library_outlined, size: 64,
                    color: Theme.of(context)
                        .colorScheme.onSurfaceVariant.withOpacity(0.3)),
                  const SizedBox(height: 16),
                  Text(
                    '还没有加密视频',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '点击右下角 + 按钮开始加密',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context)
                          .colorScheme.onSurfaceVariant.withOpacity(0.6),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return SliverPadding(
          padding: const EdgeInsets.all(12),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 0.75,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final video = allVideos[index];
                return VideoCard(
                  video: video,
                  processingState: videoProvider.processingState[video.id],
                  onTap: () {
                    _showVideoActions(video, videoProvider);
                  },
                );
              },
              childCount: allVideos.length,
            ),
          ),
        );
      },
    );
  }

  Widget _buildFab() {
    return FloatingActionButton.extended(
      onPressed: () {
        context.read<VideoListProvider>().pickAndEncryptVideos(
          targetFolder: context.read<FolderProvider>().selectedFolder,
        );
      },
      icon: const Icon(Icons.add_rounded),
      label: const Text('选择视频加密'),
    );
  }

  Widget _buildBottomBar() {
    return Consumer<VideoListProvider>(
      builder: (context, videoProvider, _) {
        final videos = videoProvider.videos;
        final totalSize = videos.fold<int>(0, (sum, v) => sum + v.fileSize);

        return GestureDetector(
          onTap: _showStorageStats,
          child: Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Theme.of(context)
                  .colorScheme.surfaceContainerHigh.withOpacity(0.9),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.2),
                  blurRadius: 12,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.videocam_rounded, size: 16,
                  color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 6),
                Text(
                  '${videos.length} 个加密视频 · ${FileUtils.formatFileSize(totalSize)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // --- 交互逻辑 ---

  void _showVideoActions(VideoItem video, VideoListProvider videoProvider) {
    final colorScheme = Theme.of(context).colorScheme;

    ActionSheet.show(
      context,
      title: video.displayName,
      items: [
        // 播放
        ActionSheetItem(
          icon: Icons.play_arrow_rounded,
          label: '播放',
          color: colorScheme.primary,
          onTap: () => _playVideo(video),
        ),
        // 解密导出
        ActionSheetItem(
          icon: Icons.file_download_rounded,
          label: '解密导出',
          color: const Color(0xFF4CAF50),
          onTap: () => _decryptVideo(video, videoProvider),
        ),
        // 重命名
        ActionSheetItem(
          icon: Icons.edit_rounded,
          label: '重命名',
          onTap: () => _renameVideo(video, videoProvider),
        ),
        // 移动到文件夹
        ActionSheetItem(
          icon: Icons.folder_rounded,
          label: '移动到文件夹',
          onTap: () => _moveVideo(video, videoProvider),
        ),
        // 删除
        ActionSheetItem(
          icon: Icons.delete_outline_rounded,
          label: '删除',
          color: colorScheme.error,
          onTap: () => _deleteVideo(video, videoProvider),
        ),
      ],
    );
  }

  void _playVideo(VideoItem video) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VideoPlayerScreen(
          encPath: video.encPath,
          title: video.displayName,
        ),
      ),
    );
  }

  Future<void> _decryptVideo(VideoItem video, VideoListProvider provider) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('解密导出'),
        content: Text('将「${video.displayName}」解密到 UnLockVideo 目录？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('解密'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final success = await provider.decryptAndExport(video);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(success ? '导出成功' : '导出失败'),
            backgroundColor: success ? null : Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Future<void> _renameVideo(VideoItem video, VideoListProvider provider) async {
    final controller = TextEditingController(text: video.displayName);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '输入新名称',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(ctx, controller.text.trim());
              }
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );

    if (newName != null && FileUtils.isValidFileName(newName)) {
      final success = await provider.renameVideo(video, newName);
      if (context.mounted && !success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('重命名失败')),
        );
      }
    }
  }

  void _moveVideo(VideoItem video, VideoListProvider videoProvider) {
    final folderProvider = context.read<FolderProvider>();

    ActionSheet.show(
      context,
      title: '移动到文件夹',
      items: [
        // 根目录
        ActionSheetItem(
          icon: Icons.folder_open_rounded,
          label: '根目录（不在文件夹中）',
          onTap: () => videoProvider.moveVideo(video, null),
        ),
        // 各文件夹
        ...folderProvider.folders.map((folder) {
          return ActionSheetItem(
            icon: Icons.folder_rounded,
            label: folder.displayName,
            onTap: () => videoProvider.moveVideo(video, folder.name),
          );
        }),
      ],
    );
  }

  Future<void> _deleteVideo(VideoItem video, VideoListProvider provider) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除「${video.displayName}」吗？\n此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final success = await provider.deleteVideo(video);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(success ? '已安全删除' : '删除失败'),
          ),
        );
      }
    }
  }

  void _showFolderManagement(FolderProvider folderProvider) {
    final videoProvider = context.read<VideoListProvider>();

    final folderDataList = folderProvider.folders.map((folder) {
      final count = videoProvider.videos
          .where((v) => v.folderName == folder.name)
          .length;
      return FolderData(
        name: folder.name,
        displayName: folder.displayName,
        color: folder.color,
        videoCount: count,
      );
    }).toList();

    FolderManageSheet.show(
      context,
      folders: folderDataList,
      onCreate: (displayName, color) async {
        final result = await folderProvider.createFolder(displayName, color);
        if (result) {
          await videoProvider.loadVideos();
        }
        return result;
      },
      onRename: (folderName, newName) async {
        return await folderProvider.renameFolder(folderName, newName);
      },
      onRecolor: (folderName, color) async {
        return await folderProvider.recolorFolder(folderName, color);
      },
      onDelete: (folderName) async {
        return await folderProvider.deleteFolder(folderName);
      },
    );
  }

  Future<void> _showStorageStats() async {
    final videoProvider = context.read<VideoListProvider>();
    final stats = await videoProvider.getStorageStats();
    if (context.mounted) {
      StorageStatsDialog.show(context, stats);
    }
  }

  Future<void> _cleanupCache() async {
    final videoProvider = context.read<VideoListProvider>();
    final cacheCleaned = await videoProvider.cleanupCache();
    final orphansCleaned = await videoProvider.cleanOrphanThumbnails();

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '清理完成：缓存 $cacheCleaned 个，孤儿缩略图 $orphansCleaned 个',
          ),
        ),
      );
    }
  }
}
