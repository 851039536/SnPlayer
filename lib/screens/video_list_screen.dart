// lib/screens/video_list_screen.dart — 视频列表主页面（权限初始化/文件夹标签/卡片网格/批量加密导入/缓存清理）

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/video_item.dart';
import '../providers/video_list_provider.dart';
import '../providers/folder_provider.dart';
import '../services/permission_service.dart';
import '../utils/file_utils.dart';
import '../widgets/video_card.dart';
import '../widgets/folder_tabs.dart';
import '../widgets/crypto_progress_dialog.dart';
import '../widgets/storage_stats_dialog.dart';
import '../widgets/video_dialogs.dart';
import '../theme/app_font_size.dart';
import '../theme/app_radius.dart';
import '../theme/app_sizes.dart';
import '../theme/app_spacing.dart';
import 'folder_manage_screen.dart';
import 'video_actions_handler.dart';

/// 视频列表主页面
///
/// AppBar + 文件夹标签 + 视频卡片网格 + 底部状态栏
class VideoListScreen extends StatefulWidget {
  const VideoListScreen({super.key});

  @override
  State<VideoListScreen> createState() => _VideoListScreenState();
}

class _VideoListScreenState extends State<VideoListScreen> {
  bool _hasPermission = false;
  bool _isInitializing = true;

  final ScrollController _scrollController = ScrollController();
  static const int _preloadRows = 2; // 上下各预加载 2 行

  /// 滚动防抖计时器（避免每帧触发缩略图加载）
  Timer? _scrollDebounce;

  /// 上次已请求的区间与筛选条件，用于跳过重复请求
  int _lastRangeStart = -1;
  int _lastRangeEnd = -1;
  String? _lastFolderKey;
  bool _lastFolderKeySet = false;

  /// 卡片操作分发器（含第三方播放的流式代理，dispose 时停止）
  final VideoActionsHandler _actions = VideoActionsHandler();

  /// 缓存的 Provider 引用
  ///
  /// dispose() 中不能再通过 context 查找祖先 Provider（元素树已失活，会抛
  /// "Looking up a deactivated widget's ancestor is unsafe"），故在此预先缓存。
  VideoListProvider? _videoProvider;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _initApp();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _videoProvider = context.read<VideoListProvider>();
  }

  /// 滚动监听：防抖后计算可见区间并请求缩略图
  ///
  /// 每帧直接触发会让同一区间被重复请求（导致同一视频并发重复解密），
  /// 故用 [_scrollDebounce] 合并连续滚动事件。
  void _onScroll() {
    _scrollDebounce?.cancel();
    _scrollDebounce = Timer(
      const Duration(milliseconds: 80),
      _loadThumbnailsForVisibleRange,
    );
  }

  /// 重置可见区间跟踪（列表内容变化后必须调用，否则去重会跳过应有的加载）
  void _resetVisibleRangeTracking() {
    _lastRangeStart = -1;
    _lastRangeEnd = -1;
    _lastFolderKeySet = false;
    _lastFolderKey = null;
  }

  /// 计算可见区间并请求缩略图
  ///
  /// 关键：区间索引必须基于**网格实际渲染的列表**（[getVideosInFolder]），
  /// 否则选中文件夹时索引会与全量列表错位，导致加载到错误的视频缩略图。
  void _loadThumbnailsForVisibleRange() {
    if (!mounted) { return; }
    final provider = context.read<VideoListProvider>();
    final folderProvider = context.read<FolderProvider>();
    final selectedFolder = folderProvider.selectedFolder;
    final videos = provider.getVideosInFolder(selectedFolder);
    if (videos.isEmpty) { return; }

    const crossAxisCount = AppSizes.gridCrossAxisCount;
    // 估算每项高度：网格宽度 / 列数 * aspectRatio
    final screenWidth = MediaQuery.of(context).size.width;
    const padding = AppSpacing.spacing4 * 2; // grid padding left+right
    const spacing = AppSpacing.spacing3 * (crossAxisCount - 1);
    final itemWidth = (screenWidth - padding - spacing) / crossAxisCount;
    // 与 SliverGrid 的 childAspectRatio 保持一致（1.0 时高度=宽度）
    final itemHeight = AppSizes.videoCardAspectRatio == 0
        ? itemWidth
        : itemWidth / AppSizes.videoCardAspectRatio;

    final scrollOffset = _scrollController.offset;
    final viewportHeight = _scrollController.position.viewportDimension;

    // 计算可见范围（含预加载行）
    const itemsPerRow = crossAxisCount;
    final rowHeight = itemHeight + AppSpacing.spacing3; // 含 mainAxisSpacing
    final firstVisibleRow = (scrollOffset / rowHeight).floor();
    final visibleRows = (viewportHeight / rowHeight).ceil() + 1; // +1 容错

    final firstVisible = ((firstVisibleRow - _preloadRows).clamp(0, double.infinity) * itemsPerRow).toInt();
    final lastVisible = ((firstVisibleRow + visibleRows + _preloadRows) * itemsPerRow)
        .toInt()
        .clamp(0, videos.length); // clamp 到筛选后长度，而非全量长度

    if (firstVisible >= lastVisible) { return; }

    // 区间与筛选条件均未变化：跳过重复请求
    if (_lastFolderKeySet &&
        _lastFolderKey == selectedFolder &&
        _lastRangeStart == firstVisible &&
        _lastRangeEnd == lastVisible) {
      return;
    }
    _lastFolderKeySet = true;
    _lastFolderKey = selectedFolder;
    _lastRangeStart = firstVisible;
    _lastRangeEnd = lastVisible;

    unawaited(provider.loadVisibleThumbnails(videos, firstVisible, lastVisible));
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
    if (!mounted) { return; }
    final folderProvider = context.read<FolderProvider>();
    final videoProvider = context.read<VideoListProvider>();

    await folderProvider.loadFolders();
    await videoProvider.loadVideos();

    // 先展示网格（含占位图），缩略图后台异步加载
    if (mounted) {
      setState(() { _isInitializing = false; });
    }
    unawaited(videoProvider.loadThumbnails());
    unawaited(videoProvider.cleanupExpiredThumbnails()); // 后台清理过期缓存

    // 首屏可见区缩略图（loadThumbnails 之外的兜底，确保当前视口优先）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) { _loadThumbnailsForVisibleRange(); }
    });
  }

  @override
  void dispose() {
    _scrollDebounce?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    // 用缓存的引用，避免在 dispose 中查找已失活的祖先 Provider
    _videoProvider?.cancelThumbnailLoading();
    // 停止第三方播放器的流式解密代理
    unawaited(_actions.dispose());
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
              const SizedBox(height: AppSpacing.spacing5),
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
            padding: const EdgeInsets.all(AppSpacing.spacing8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.folder_off_rounded, size: 72,
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
                const SizedBox(height: AppSpacing.spacing7),
                Text('需要存储权限才能访问视频文件',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.spacing3),
                Text('请在设置中授予存储权限',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.spacing7),
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
          // 列表内容已变，重置区间跟踪并重新加载可见区缩略图
          _resetVisibleRangeTracking();
          if (mounted) { _loadThumbnailsForVisibleRange(); }
        },
        child: CustomScrollView(
          controller: _scrollController,
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
      floatingActionButton: null,
      bottomNavigationBar: _buildBottomBar(),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      title: const Text(
        'SnPlayer',
        style: TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: AppFontSize.xl,
          letterSpacing: -0.5,
        ),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.add_rounded, size: AppSizes.iconSm),
          tooltip: '安全访问添加',
          onPressed: _pickAndEncryptVideosFullAccess,
        ),
        IconButton(
          icon: const Icon(Icons.cleaning_services_rounded, size: AppSizes.iconSm),
          tooltip: '清理缓存',
          onPressed: _cleanupCache,
        ),
        IconButton(
          icon: const Icon(Icons.storage_rounded, size: AppSizes.iconSm),
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
            // 切换筛选后列表内容变化，需重新计算可见区间缩略图
            _resetVisibleRangeTracking();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) { _loadThumbnailsForVisibleRange(); }
            });
          },
          onManage: () => _showFolderManagement(folderProvider),
        );
      },
    );
  }

  Widget _buildVideoGrid() {
    // 仅订阅"当前筛选下的视频列表"这一项：
    // 缩略图就绪会高频 notifyListeners，若用 Consumer2 包整个 sliver，
    // 每次通知都会重建整个网格。Selector 只在列表身份变化时才重建。
    return Selector2<VideoListProvider, FolderProvider, List<VideoItem>>(
      selector: (_, videoProvider, folderProvider) =>
          videoProvider.getVideosInFolder(folderProvider.selectedFolder),
      builder: (context, allVideos, _) {
        if (allVideos.isEmpty) {
          return SliverFillRemaining(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.video_library_outlined, size: 64,
                    color: Theme.of(context)
                        .colorScheme.onSurfaceVariant.withValues(alpha: 0.3)),
                  const SizedBox(height: AppSpacing.spacing5),
                  Text(
                    '还没有加密视频',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.spacing3),
                  Text(
                    '点击右上角 + 开始加密',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context)
                          .colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return SliverPadding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.spacing4, AppSpacing.spacing4, AppSpacing.spacing4, AppSpacing.spacing4),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: AppSizes.gridCrossAxisCount,
              mainAxisSpacing: AppSpacing.spacing2,
              crossAxisSpacing: AppSpacing.spacing2,
              childAspectRatio: AppSizes.videoCardAspectRatio,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final video = allVideos[index];
                return _VideoCardSlot(
                  // key 保证卡片在列表增删时保持元素身份，避免不必要重建
                  key: ValueKey(video.id),
                  video: video,
                  onTap: () => _actions.showActions(context, video,
                      context.read<VideoListProvider>()),
                );
              },
              childCount: allVideos.length,
            ),
          ),
        );
      },
    );
  }

  Widget _buildBottomBar() {
    return Consumer<VideoListProvider>(
      builder: (context, videoProvider, _) {
        final videos = videoProvider.videos;
        final totalSize = videos.fold<int>(0, (sum, v) => sum + v.fileSize);
        final colorScheme = Theme.of(context).colorScheme;

        return GestureDetector(
          onTap: _showStorageStats,
          child: Container(
            margin: const EdgeInsets.fromLTRB(
              AppSpacing.spacing4, 0, AppSpacing.spacing4, AppSpacing.spacing2),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.spacing4, vertical: AppSpacing.spacing1),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHigh.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(AppRadius.xl),
              border: Border.all(color: colorScheme.outlineVariant),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.videocam_rounded,
                  size: AppSizes.iconSm,
                  color: colorScheme.primary),
                const SizedBox(width: AppSpacing.spacing2),
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

  /// 完全访问模式：先确保拥有 MANAGE_EXTERNAL_STORAGE 权限，再打开文件选择器
  ///
  /// Android scoped storage 下若未授予此权限，FilePicker 会走 SAF 显示"安全访问"，
  /// 仅能看到媒体库中的视频。授予后直接浏览文件系统（"完全访问"）。
  Future<void> _pickAndEncryptVideosFullAccess() async {
    final manageStatus = await Permission.manageExternalStorage.status;

    // 已有完全访问权限，直接选文件
    if (manageStatus.isGranted) {
      if (mounted) {
        await _importVideos();
      }
      return;
    }

    // 需要完全访问 — 引导用户去设置页面开启
    if (!mounted) { return; }
    final goSettings = await VideoDialogs.showFullAccessGuide(context);
    if (goSettings == true) {
      await openAppSettings();
    }
  }

  /// 选择视频并批量加密（模态进度对话框显示文件名/第 n 个/百分比）
  Future<void> _importVideos() async {
    final videoProvider = context.read<VideoListProvider>();
    final targetFolder = context.read<FolderProvider>().selectedFolder;

    final paths = await videoProvider.pickVideoFiles();
    if (paths.isEmpty || !mounted) { return; }

    final controller = CryptoProgressController(label: '正在加密', progress: 0.0);
    CryptoProgressDialog.show(context, controller);

    ({int success, int failed}) result = (success: 0, failed: paths.length);
    try {
      result = await videoProvider.encryptVideos(
        paths,
        targetFolder: targetFolder,
        controller: controller,
      );
    } finally {
      if (mounted) { Navigator.pop(context); } // 关闭进度对话框
      controller.dispose();
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.failed == 0
              ? '加密完成：成功 ${result.success} 个'
              : '加密完成：成功 ${result.success} 个，失败 ${result.failed} 个'),
          backgroundColor:
              result.failed == 0 ? null : Theme.of(context).colorScheme.error,
        ),
      );
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
        final created = await folderProvider.createFolder(displayName, color);
        if (created == null) { return null; }
        await videoProvider.loadVideos();
        final count = videoProvider.videos
            .where((v) => v.folderName == created.name)
            .length;
        return FolderData(
          name: created.name,
          displayName: created.displayName,
          color: created.color,
          videoCount: count,
        );
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
    if (mounted) {
      StorageStatsDialog.show(context, stats);
    }
  }

  Future<void> _cleanupCache() async {
    final confirmed = await VideoDialogs.showCleanupConfirm(context);
    if (confirmed != true || !mounted) { return; }

    final videoProvider = context.read<VideoListProvider>();

    // 显示 loading
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );
    }

    int cacheCleaned = 0;
    int orphansCleaned = 0;
    bool failed = false;
    try {
      cacheCleaned = await videoProvider.clearAllCache();
      orphansCleaned = await videoProvider.cleanOrphanThumbnails();
    } catch (e) {
      failed = true;
      debugPrint('[SnPlayer] VideoListScreen._cleanupCache: $e');
    } finally {
      // 无论成功失败都关闭 loading，避免 barrierDismissible:false 的圈永久卡死
      if (mounted) { Navigator.pop(context); }
    }

    // 重新加载缩略图
    _resetVisibleRangeTracking();
    unawaited(videoProvider.loadThumbnails());

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            failed
                ? '清理未完成，请重试'
                : '清理完成：缓存 $cacheCleaned 个，孤儿缩略图 $orphansCleaned 个',
          ),
          backgroundColor:
              failed ? Theme.of(context).colorScheme.error : null,
        ),
      );
    }
  }
}

/// 单个视频卡片槽位
///
/// 只订阅"本视频的缩略图路径 + 处理状态"，使缩略图就绪的高频通知
/// 仅重建对应卡片，而非整个网格。外层的 [Selector2] 负责列表增删/筛选变化。
class _VideoCardSlot extends StatelessWidget {
  final VideoItem video;
  final VoidCallback onTap;

  const _VideoCardSlot({
    super.key,
    required this.video,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Selector<VideoListProvider, ({String? thumb, String? state})>(
      selector: (_, provider) => (
        thumb: video.thumbCachePath,
        state: provider.processingState[video.id],
      ),
      builder: (context, data, _) {
        return VideoCard(
          video: video,
          processingState: data.state,
          onTap: onTap,
        );
      },
    );
  }
}
