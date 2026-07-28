// lib/widgets/video_dialogs.dart — 视频操作确认/输入对话框集合（解密导出/重命名/删除/清理缓存）

import 'package:flutter/material.dart';

/// 视频操作相关的确认与输入对话框
class VideoDialogs {
  VideoDialogs._();

  /// 解密导出确认，返回 true = 确认
  static Future<bool?> showDecryptConfirm(BuildContext context, String displayName) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('解密导出'),
        content: Text('将「$displayName」解密到 UnLockVideo 目录？'),
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
  }

  /// 重命名输入框，返回非空新名称或 null（取消）
  static Future<String?> showRenameDialog(BuildContext context, String currentName) {
    final controller = TextEditingController(text: currentName);
    return showDialog<String>(
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
  }

  /// 删除确认，返回 true = 确认
  static Future<bool?> showDeleteConfirm(BuildContext context, String displayName) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除「$displayName」吗？\n此操作不可撤销。'),
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
  }

  /// 清理缓存确认，返回 true = 确认
  static Future<bool?> showCleanupConfirm(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清理缓存'),
        content: const Text(
          '将清空所有播放缓存和缩略图缓存，并清理无对应视频的残留缩略图。\n'
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
  }

  /// 引导开启「允许管理所有文件」权限，返回 true = 前往设置
  static Future<bool?> showFullAccessGuide(BuildContext context) {
    return showDialog<bool>(
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
  }
}
