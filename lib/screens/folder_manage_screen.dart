import 'dart:io';

import 'package:flutter/material.dart';

/// 文件夹管理页面（BottomSheet）
///
/// 支持创建/重命名/改色/删除文件夹
class FolderManageSheet extends StatefulWidget {
  final List<FolderData> folders;
  final Future<bool> Function(String displayName, String color) onCreate;
  final Future<bool> Function(String folderName, String newName) onRename;
  final Future<bool> Function(String folderName, String color) onRecolor;
  final Future<bool> Function(String folderName) onDelete;

  const FolderManageSheet({
    super.key,
    required this.folders,
    required this.onCreate,
    required this.onRename,
    required this.onRecolor,
    required this.onDelete,
  });

  /// 显示文件夹管理弹窗
  static Future<void> show(
    BuildContext context, {
    required List<FolderData> folders,
    required Future<bool> Function(String displayName, String color) onCreate,
    required Future<bool> Function(String folderName, String newName) onRename,
    required Future<bool> Function(String folderName, String color) onRecolor,
    required Future<bool> Function(String folderName) onDelete,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => FolderManageSheet(
        folders: folders,
        onCreate: onCreate,
        onRename: onRename,
        onRecolor: onRecolor,
        onDelete: onDelete,
      ),
    );
  }

  @override
  State<FolderManageSheet> createState() => _FolderManageSheetState();
}

class _FolderManageSheetState extends State<FolderManageSheet> {
  static const _presetColors = [
    '#6750A4', // 紫
    '#FF4D4D', // 红
    '#FF9800', // 橙
    '#FFC107', // 黄
    '#4CAF50', // 绿
    '#2196F3', // 蓝
    '#00BCD4', // 青
    '#E91E63', // 粉
  ];

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 拖拽指示条
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 8, bottom: 16),
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: colorScheme.onSurfaceVariant.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // 标题行
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '管理文件夹',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => _showCreateDialog(context),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('新建'),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 8),

            // 文件夹列表
            if (widget.folders.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  '还没有文件夹，点击右上角创建一个吧',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: widget.folders.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final folder = widget.folders[index];
                  return _buildFolderRow(context, folder);
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFolderRow(BuildContext context, FolderData folder) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = _parseColor(folder.color) ?? colorScheme.primary;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: color.withOpacity(0.2),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(Icons.folder_rounded, color: color, size: 22),
        ),
        title: Text(folder.displayName),
        subtitle: Text('${folder.videoCount} 个视频',
          style: TextStyle(
            fontSize: 12,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (action) {
            switch (action) {
              case 'rename':
                _showRenameDialog(context, folder);
                break;
              case 'color':
                _showColorPicker(context, folder);
                break;
              case 'delete':
                _showDeleteConfirm(context, folder);
                break;
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'rename', child: Text('重命名')),
            const PopupMenuItem(value: 'color', child: Text('修改颜色')),
            const PopupMenuItem(
              value: 'delete',
              child: Text('删除', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      ),
    );
  }

  void _showCreateDialog(BuildContext context) {
    final controller = TextEditingController();
    String selectedColor = _presetColors[0];

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('新建文件夹'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  hintText: '输入文件夹名称',
                  border: OutlineInputBorder(),
                ),
                autofocus: true,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: _presetColors.map((color) {
                  final parsed = _parseColor(color);
                  return GestureDetector(
                    onTap: () {
                      setDialogState(() {
                        selectedColor = color;
                      });
                    },
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: parsed,
                        shape: BoxShape.circle,
                        border: selectedColor == color
                            ? Border.all(color: Colors.white, width: 2.5)
                            : null,
                        boxShadow: selectedColor == color
                            ? [BoxShadow(
                                color: parsed!.withOpacity(0.5),
                                blurRadius: 8,
                              )]
                            : null,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                if (controller.text.trim().isNotEmpty) {
                  final ok = await widget.onCreate(
                    controller.text.trim(),
                    selectedColor,
                  );
                  if (ok && ctx.mounted) {
                    Navigator.pop(ctx);
                    Navigator.pop(context); // 关闭 BottomSheet
                  }
                }
              },
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
  }

  void _showRenameDialog(BuildContext context, FolderData folder) {
    final controller = TextEditingController(text: folder.displayName);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名文件夹'),
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
            onPressed: () async {
              if (controller.text.trim().isNotEmpty) {
                await widget.onRename(folder.name, controller.text.trim());
                if (ctx.mounted) {
                  Navigator.pop(ctx);
                }
              }
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _showColorPicker(BuildContext context, FolderData folder) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改颜色'),
        content: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: _presetColors.map((color) {
            final parsed = _parseColor(color);
            final isSelected = folder.color == color;
            return GestureDetector(
              onTap: () async {
                await widget.onRecolor(folder.name, color);
                if (ctx.mounted) {
                  Navigator.pop(ctx);
                }
              },
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: parsed,
                  shape: BoxShape.circle,
                  border: isSelected
                      ? Border.all(color: Colors.white, width: 3)
                      : null,
                  boxShadow: isSelected
                      ? [BoxShadow(color: parsed!.withOpacity(0.5), blurRadius: 10)]
                      : null,
                ),
                child: isSelected
                    ? const Icon(Icons.check, color: Colors.white, size: 20)
                    : null,
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  void _showDeleteConfirm(BuildContext context, FolderData folder) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除文件夹'),
        content: Text(
          '确定要删除「${folder.displayName}」吗？\n（只能删除空文件夹）',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () async {
              final ok = await widget.onDelete(folder.name);
              if (ctx.mounted) {
                Navigator.pop(ctx);
                if (!ok) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('无法删除非空文件夹')),
                  );
                }
              }
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  Color? _parseColor(String hex) {
    try {
      final colorStr = hex.replaceAll('#', '');
      if (colorStr.length == 6) {
        return Color(int.parse('FF$colorStr', radix: 16));
      }
    } catch (_) {}
    return null;
  }
}

/// 文件夹数据（管理界面用）
class FolderData {
  final String name;
  final String displayName;
  final String color;
  final int videoCount;

  const FolderData({
    required this.name,
    required this.displayName,
    required this.color,
    this.videoCount = 0,
  });
}
