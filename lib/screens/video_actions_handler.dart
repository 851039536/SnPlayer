// lib/screens/video_actions_handler.dart — 视频卡片操作分发（动作面板/播放/第三方播放/导出/重命名/移动/详情/删除）

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/video_item.dart';
import '../providers/folder_provider.dart';
import '../providers/video_list_provider.dart';
import '../theme/app_colors.dart';
import '../utils/file_utils.dart';
import '../widgets/action_sheet.dart';
import '../widgets/crypto_progress_dialog.dart';
import '../widgets/video_detail_sheet.dart';
import '../widgets/video_dialogs.dart';
import 'external_play_handler.dart';
import 'video_player_screen.dart';

/// 视频卡片操作分发器
///
/// 承接列表页卡片点击后的动作面板及各项操作的执行。
/// 持有第三方播放处理器（流式代理需页面存活期间保持运行），
/// 宿主页面 dispose 时必须调用 [dispose]。
class VideoActionsHandler {
  static const _fileChannel = MethodChannel('com.snplayer.sn_player/file');

  final ExternalPlayHandler _externalPlay = ExternalPlayHandler();

  /// 显示视频操作面板
  void showActions(
    BuildContext context,
    VideoItem video,
    VideoListProvider videoProvider,
  ) {
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
          onTap: () => _playVideo(context, video),
        ),
        // 第三方播放
        ActionSheetItem(
          icon: Icons.open_in_new_rounded,
          label: '第三方播放',
          color: AppColors.warningOf(context),
          onTap: () => _externalPlay.play(context, video),
        ),
        // 解密导出
        ActionSheetItem(
          icon: Icons.file_download_rounded,
          label: '解密导出',
          color: AppColors.successOf(context),
          onTap: () => _decryptVideo(context, video, videoProvider),
        ),
        // 重命名
        ActionSheetItem(
          icon: Icons.edit_rounded,
          label: '重命名',
          onTap: () => _renameVideo(context, video, videoProvider),
        ),
        // 移动到文件夹
        ActionSheetItem(
          icon: Icons.folder_rounded,
          label: '移动到文件夹',
          onTap: () => _moveVideo(context, video, videoProvider),
        ),
        // 详细信息
        ActionSheetItem(
          icon: Icons.info_outline_rounded,
          label: '详细信息',
          color: AppColors.brand,
          onTap: () => VideoDetailSheet.show(context, video),
        ),
        // 打开存储路径
        ActionSheetItem(
          icon: Icons.folder_open_rounded,
          label: '打开存储路径',
          onTap: () => _openStoragePath(context, video),
        ),
        // 删除
        ActionSheetItem(
          icon: Icons.delete_outline_rounded,
          label: '删除',
          color: colorScheme.error,
          onTap: () => _deleteVideo(context, video, videoProvider),
        ),
      ],
    );
  }

  void _playVideo(BuildContext context, VideoItem video) {
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

  /// 解密导出（确认 → 模态进度对话框 → 结果 SnackBar）
  Future<void> _decryptVideo(
    BuildContext context,
    VideoItem video,
    VideoListProvider provider,
  ) async {
    final confirmed = await VideoDialogs.showDecryptConfirm(context, video.displayName);
    if (confirmed != true || !context.mounted) { return; }

    final controller = CryptoProgressController(
      label: '正在解密导出',
      fileName: video.displayName,
      progress: 0.0,
    );
    CryptoProgressDialog.show(context, controller);

    bool success = false;
    try {
      success = await provider.decryptAndExport(video, controller: controller);
    } finally {
      if (context.mounted) { Navigator.pop(context); } // 关闭进度对话框
      controller.dispose();
    }

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? '导出成功' : '导出失败'),
          backgroundColor: success ? null : Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  Future<void> _renameVideo(
    BuildContext context,
    VideoItem video,
    VideoListProvider provider,
  ) async {
    final newName = await VideoDialogs.showRenameDialog(context, video.displayName);

    if (newName != null && FileUtils.isValidFileName(newName)) {
      final success = await provider.renameVideo(video, newName);
      if (context.mounted && !success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('重命名失败')),
        );
      }
    }
  }

  void _moveVideo(
    BuildContext context,
    VideoItem video,
    VideoListProvider videoProvider,
  ) {
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
  Future<void> _openStoragePath(BuildContext context, VideoItem video) async {
    try {
      final parentDir = File(video.encPath).parent.path;
      await _fileChannel.invokeMethod('openFolder', {'path': parentDir});
    } on PlatformException catch (e) {
      debugPrint('[SnPlayer] VideoActionsHandler._openStoragePath: code=${e.code}, msg=${e.message}');
      if (context.mounted) {
        final msg = switch (e.code) {
          'NO_FILE_MANAGER' => '未找到文件管理器',
          'FOLDER_NOT_FOUND' => '文件夹不存在',
          _ => '打开失败',
        };
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (e) {
      debugPrint('[SnPlayer] VideoActionsHandler._openStoragePath: $e');
    }
  }

  Future<void> _deleteVideo(
    BuildContext context,
    VideoItem video,
    VideoListProvider provider,
  ) async {
    final confirmed = await VideoDialogs.showDeleteConfirm(context, video.displayName);

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

  /// 停止第三方播放的流式解密代理（宿主页面 dispose 时调用）
  Future<void> dispose() => _externalPlay.dispose();
}
