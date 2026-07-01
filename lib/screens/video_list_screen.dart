import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/video_item.dart';
import '../providers/video_list_provider.dart';
import '../providers/folder_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/crypto_service.dart';
import '../services/permission_service.dart';
import '../services/path_provider_service.dart';
import '../services/playback_cache_manager.dart';
import '../services/streaming_decrypt_proxy.dart';
import '../utils/file_utils.dart';
import '../widgets/video_card.dart';
import '../widgets/folder_tabs.dart';
import '../widgets/action_sheet.dart';
import '../widgets/storage_stats_dialog.dart';
import '../theme/app_colors.dart';
import '../theme/app_font_size.dart';
import '../theme/app_radius.dart';
import '../theme/app_sizes.dart';
import '../theme/app_spacing.dart';
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
  static const _fileChannel = MethodChannel('com.snplayer.sn_player/file');

  bool _hasPermission = false;
  bool _isInitializing = true;

  final ScrollController _scrollController = ScrollController();
  static const int _preloadRows = 2; // 上下各预加载 2 行

  /// 第三方播放器使用的流式解密代理（页面存活期间保持，dispose 时停止）
  StreamingDecryptProxy? _externalProxy;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _initApp();
  }

  void _onScroll() {
    final provider = context.read<VideoListProvider>();
    final videos = provider.videos;
    if (videos.isEmpty) { return; }

    final crossAxisCount = 2;
    // 估算每项高度：网格宽度 / 列数 * aspectRatio
    final screenWidth = MediaQuery.of(context).size.width;
    final padding = AppSpacing.spacing4 * 2; // grid padding left+right
    final spacing = AppSpacing.spacing3 * (crossAxisCount - 1);
    final itemWidth = (screenWidth - padding - spacing) / crossAxisCount;
    final itemHeight = itemWidth; // childAspectRatio: 1.0

    final scrollOffset = _scrollController.offset;
    final viewportHeight = _scrollController.position.viewportDimension;

    // 计算可见范围（含预加载行）
    final itemsPerRow = crossAxisCount;
    final rowHeight = itemHeight + AppSpacing.spacing3; // 含 mainAxisSpacing
    final firstVisibleRow = (scrollOffset / rowHeight).floor();
    final visibleRows = (viewportHeight / rowHeight).ceil() + 1; // +1 容错

    final firstVisible = ((firstVisibleRow - _preloadRows).clamp(0, double.infinity) * itemsPerRow).toInt();
    final lastVisible = ((firstVisibleRow + visibleRows + _preloadRows) * itemsPerRow).toInt().clamp(0, videos.length);

    if (firstVisible < lastVisible) {
      provider.loadVisibleThumbnails(firstVisible, lastVisible);
    }
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

    // 先展示网格（含占位图），缩略图后台异步加载
    if (mounted) {
      setState(() { _isInitializing = false; });
    }
    unawaited(videoProvider.loadThumbnails());
    unawaited(videoProvider.cleanupExpiredThumbnails()); // 后台清理过期缓存
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    context.read<VideoListProvider>().cancelThumbnailLoading();
    // 停止第三方播放器的流式解密代理
    _externalProxy?.stop();
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
              crossAxisCount: 2,
              mainAxisSpacing: AppSpacing.spacing2,
              crossAxisSpacing: AppSpacing.spacing2,
              childAspectRatio: 1.0,
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
      if (mounted && context.mounted) {
        context.read<VideoListProvider>().pickAndEncryptVideos(
          targetFolder: context.read<FolderProvider>().selectedFolder,
        );
      }
      return;
    }

    // 需要完全访问 — 引导用户去设置页面开启
    final goSettings = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('需要完全访问权限'),
        content: const Text(
          '当前仅「安全访问」模式，只能看到部分视频。\n\n'
          '请在系统设置中开启「允许管理所有文件」，\n'
          '获得完全访问权限后可以浏览任意目录下的视频。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('前往设置'),
          ),
        ],
      ),
    );

    if (goSettings == true) {
      await openAppSettings();
    }
  }

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
        // 第三方播放
        ActionSheetItem(
          icon: Icons.open_in_new_rounded,
          label: '第三方播放',
          color: AppColors.warning,
          onTap: () => _playExternal(video),
        ),
        // 解密导出
        ActionSheetItem(
          icon: Icons.file_download_rounded,
          label: '解密导出',
          color: AppColors.success,
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
        // 详细信息
        ActionSheetItem(
          icon: Icons.info_outline_rounded,
          label: '详细信息',
          color: AppColors.brand,
          onTap: () => _showVideoDetail(video),
        ),
        // 打开存储路径
        ActionSheetItem(
          icon: Icons.folder_open_rounded,
          label: '打开存储路径',
          onTap: () => _openStoragePath(video),
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

  Future<void> _playExternal(VideoItem video) async {
    try {
      final cacheDir = await PathProviderService.getCacheDir();

      // ── 阶段 1：磁盘缓存命中 → 直接打开缓存文件（零解密） ──
      final cachedFile = await PlaybackCacheManager.getCachedFile(
        video.encPath, cacheDir,
      );
      if (cachedFile != null) {
        debugPrint('[SnPlayer] _playExternal: 磁盘缓存命中，直接打开');
        await _fileChannel.invokeMethod('openFile', {'path': cachedFile});
        return;
      }

      // ── 阶段 2：流式解密代理 → HTTP URL 打开第三方播放器 ──
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );

      // 停止上一次的代理（如有）
      await _externalProxy?.stop();
      _externalProxy = null;

      _externalProxy = StreamingDecryptProxy();
      await _externalProxy!.start(video.encPath);

      if (mounted) { Navigator.pop(context); } // 关闭 loading

      debugPrint('[SnPlayer] _playExternal: 流式代理 ${_externalProxy!.proxyUrl}');
      await _fileChannel.invokeMethod('openUrl', {
        'url': _externalProxy!.proxyUrl,
      });
      // 代理在页面存活期间保持运行，dispose 时自动停止
    } on PlatformException catch (e) {
      if (mounted) { Navigator.pop(context); }
      debugPrint('[SnPlayer] _playExternal PlatformException: code=${e.code}, msg=${e.message}');

      // 流式代理失败 → 降级全量解密
      if (e.code == 'NO_PLAYER') {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('没有找到可播放视频的应用，请安装 MX Player 或 VLC')),
          );
        }
        return;
      }

      // 其他错误尝试降级全量解密
      await _playExternalFallback(video);
    } catch (e) {
      if (mounted) { Navigator.pop(context); }
      debugPrint('[SnPlayer] _playExternal: $e，降级全量解密');
      await _playExternalFallback(video);
    }
  }

  /// 降级路径：全量解密后用原生 openFile 打开
  Future<void> _playExternalFallback(VideoItem video) async {
    try {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );

      // 停止代理（全量解密不需要代理）
      await _externalProxy?.stop();
      _externalProxy = null;

      final unlockDir = await PathProviderService.getUnlockVideoDir();
      await Directory(unlockDir).create(recursive: true);
      final tempPath = '$unlockDir/${video.displayName}.mp4';
      await CryptoService.decryptFile(video.encPath, tempPath);

      if (mounted) { Navigator.pop(context); }

      await _fileChannel.invokeMethod('openFile', {'path': tempPath});
    } on PlatformException catch (e) {
      if (mounted) { Navigator.pop(context); }
      debugPrint('[SnPlayer] _playExternalFallback PlatformException: code=${e.code}, msg=${e.message}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_getPlayExternalErrorMsg(e.code, e.message))),
        );
      }
    } catch (e) {
      if (mounted) { Navigator.pop(context); }
      debugPrint('[SnPlayer] _playExternalFallback: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('打开失败，请检查是否安装了播放器')),
        );
      }
    }
  }

  /// 将原生错误码转为用户可读的错误提示
  String _getPlayExternalErrorMsg(String code, String? message) {
    switch (code) {
      case 'NO_PLAYER':
        return '没有找到可播放视频的应用，请安装 MX Player 或 VLC';
      case 'FILE_NOT_FOUND':
        return '解密文件不存在，请重试';
      case 'SECURITY':
        return '缺少文件访问权限，请在系统设置中开启「允许管理所有文件」';
      case 'NO_PATH':
        return '文件路径为空，请联系开发者';
      default:
        return '播放失败（$code）${message ?? ""}';
    }
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

  /// 打开加密视频所在文件夹
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

  /// 显示视频文件详细信息底部弹窗
  void _showVideoDetail(VideoItem video) {
    final colorScheme = Theme.of(context).colorScheme;
    final file = File(video.encPath);
    final fileName = file.uri.pathSegments.last;
    final ext = fileName.contains('.') ? fileName.split('.').last.toUpperCase() : '未知';
    final parentPath = file.parent.path;
    final folderLabel = video.folderName ?? '根目录';

    // 格式化日期
    final dt = video.encryptedAt;
    final dateStr =
        '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}';

    final maxHeight = MediaQuery.of(context).size.height * 0.8;

    showModalBottomSheet(
      context: context,
      backgroundColor: colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: AppSpacing.spacing2),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 拖拽指示条
                  Center(
                    child: Container(
                      margin: const EdgeInsets.only(
                        top: AppSpacing.spacing2, bottom: AppSpacing.spacing2),
                      width: 32,
                      height: 4,
                      decoration: BoxDecoration(
                        color: colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),

                  // 标题区
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.spacing6, vertical: AppSpacing.spacing2),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: AppColors.brand.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(AppRadius.lg),
                          ),
                          child: const Icon(
                            Icons.info_outline_rounded,
                            color: AppColors.brand,
                            size: AppSizes.iconMd,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.spacing4),
                        Expanded(
                          child: Text(
                            video.displayName,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),

                  // 详细信息行
                  _buildDetailRow(
                    ctx, Icons.insert_drive_file_outlined, '文件名', fileName,
                  ),
                  _buildDetailRow(
                    ctx, Icons.category_outlined, '文件类型', ext,
                  ),
                  _buildDetailRow(
                    ctx, Icons.storage_rounded, '文件大小', video.formattedSize,
                  ),
                  _buildDetailRow(
                    ctx, Icons.folder_outlined, '存储路径', parentPath,
                  ),
                  _buildDetailRow(
                    ctx, Icons.folder_copy_outlined, '所属文件夹', folderLabel,
                  ),
                  _buildDetailRow(
                    ctx, Icons.calendar_today_rounded, '加密日期', dateStr,
                  ),
                  _buildDetailRow(
                    ctx, Icons.fingerprint, '视频 ID', video.id,
                  ),

                  // 取消按钮
                  const SizedBox(height: AppSpacing.spacing2),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.spacing4),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(ctx),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            vertical: AppSpacing.spacing3),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(AppRadius.lg),
                          ),
                        ),
                        child: const Text('关闭'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 详情行：左侧图标 + 标签 + 右侧值
  Widget _buildDetailRow(
    BuildContext ctx,
    IconData icon,
    String label,
    String value,
  ) {
    final colorScheme = Theme.of(ctx).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.spacing6,
        vertical: AppSpacing.spacing3,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: AppSizes.iconXs, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: AppSpacing.spacing4),
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.spacing3),
          Expanded(
            child: Text(
              value,
              style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清理缓存'),
        content: const Text(
          '将清空所有播放缓存和缩略图缓存。\n'
          '下次播放视频时需要重新解密，缩略图也会重新生成。\n\n'
          '确定要清理吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清理'),
          ),
        ],
      ),
    );

    if (confirmed != true) { return; }

    final videoProvider = context.read<VideoListProvider>();

    // 显示 loading
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );
    }

    final cacheCleaned = await videoProvider.clearAllCache();
    final orphansCleaned = await videoProvider.cleanOrphanThumbnails();

    if (mounted) { Navigator.pop(context); } // 关闭 loading

    // 重新加载缩略图
    unawaited(videoProvider.loadThumbnails());

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
