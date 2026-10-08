// lib/screens/folder_manage_screen.dart — 文件夹管理弹窗（创建/重命名/改色/删除，就地刷新 + 名称校验）

import 'package:flutter/material.dart';

import '../services/storage_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_radius.dart';
import '../theme/app_sizes.dart';
import '../utils/color_utils.dart';

/// 文件夹管理页面（BottomSheet）
///
/// 支持创建/重命名/改色/删除文件夹
class FolderManageSheet extends StatefulWidget {
  final List<FolderData> folders;
  final Future<FolderData?> Function(String displayName, String color) onCreate;
  final Future<bool> Function(String folderName, String newName) onRename;
  final Future<bool> Function(String folderName, String color) onRecolor;
  final Future<DeleteFolderResult> Function(String folderName) onDelete;

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
    required Future<FolderData?> Function(String displayName, String color) onCreate,
    required Future<bool> Function(String folderName, String newName) onRename,
    required Future<bool> Function(String folderName, String color) onRecolor,
    required Future<DeleteFolderResult> Function(String folderName) onDelete,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.xxl)),
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
  static const _presetColors = AppColors.presetFolderColors;

  /// 文件夹名称长度上限（防止超长名撑破标签布局）
  static const int _maxNameLength = 20;

  /// 本地可变副本：弹窗内增删改后就地刷新，无需重开
  /// （show 时传入的 widget.folders 是快照，StatefulWidget 不监听 Provider）
  late final List<FolderData> _folders = List.of(widget.folders);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.spacing5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 拖拽指示条
            Center(
              child: Container(
                margin: const EdgeInsets.only(
                  top: AppSpacing.spacing3, bottom: AppSpacing.spacing5),
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // 标题行
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.spacing6),
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
                    icon: const Icon(Icons.add, size: AppSizes.iconLg),
                    label: const Text('新建'),
                  ),
                ],
              ),
            ),

            const SizedBox(height: AppSpacing.spacing3),

            // 文件夹列表
            if (_folders.isEmpty)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.spacing8),
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
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.spacing5),
                itemCount: _folders.length,
                separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.spacing3),
                itemBuilder: (context, index) {
                  final folder = _folders[index];
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
    final color = ColorUtils.parseHexColor(folder.color) ?? colorScheme.primary;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: ListTile(
        leading: Container(
          width: AppSizes.iconButtonSm,
          height: AppSizes.iconButtonSm,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Icon(Icons.folder_rounded, color: color, size: AppSizes.iconMd),
        ),
        title: Text(folder.displayName),
        subtitle: Text('${folder.videoCount} 个视频',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
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
            PopupMenuItem(
              value: 'delete',
              child: Text('删除',
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          ],
        ),
      ),
    );
  }

  void _showCreateDialog(BuildContext context) {
    final controller = TextEditingController();
    String selectedColor = _presetColors[0];
    String? errorText;
    final colorScheme = Theme.of(context).colorScheme;

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
                maxLength: _maxNameLength,
                decoration: InputDecoration(
                  hintText: '输入文件夹名称',
                  border: const OutlineInputBorder(),
                  errorText: errorText,
                ),
                autofocus: true,
              ),
              const SizedBox(height: AppSpacing.spacing4),
              Wrap(
                spacing: AppSpacing.spacing3,
                children: _presetColors.map((color) {
                  final parsed = ColorUtils.parseHexColor(color);
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
                            ? Border.all(
                                color: colorScheme.onSurface, width: 2.5)
                            : Border.all(
                                color: Colors.transparent, width: 2.5),
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
                final name = controller.text.trim();
                if (name.isEmpty) {
                  setDialogState(() => errorText = '请输入文件夹名称');
                  return;
                }
                if (_isDuplicateName(name)) {
                  setDialogState(() => errorText = '已存在同名文件夹');
                  return;
                }
                final created = await widget.onCreate(name, selectedColor);
                if (!ctx.mounted) { return; }
                if (created != null) {
                  Navigator.pop(ctx);
                  _addFolder(created);
                } else {
                  setDialogState(() => errorText = '创建失败，请重试');
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
    String? errorText;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('重命名文件夹'),
          content: TextField(
            controller: controller,
            maxLength: _maxNameLength,
            decoration: InputDecoration(
              hintText: '输入新名称',
              border: const OutlineInputBorder(),
              errorText: errorText,
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
                final newName = controller.text.trim();
                if (newName.isEmpty) {
                  setDialogState(() => errorText = '请输入新名称');
                  return;
                }
                // 名称未变化：直接关闭，不触发保存
                if (newName == folder.displayName) {
                  Navigator.pop(ctx);
                  return;
                }
                if (_isDuplicateName(newName, excludeName: folder.name)) {
                  setDialogState(() => errorText = '已存在同名文件夹');
                  return;
                }
                final ok = await widget.onRename(folder.name, newName);
                if (!ctx.mounted) { return; }
                if (ok) {
                  Navigator.pop(ctx);
                  _replaceFolder(folder.name, displayName: newName);
                } else {
                  setDialogState(() => errorText = '重命名失败，请重试');
                }
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }

  void _showColorPicker(BuildContext context, FolderData folder) {
    final colorScheme = Theme.of(context).colorScheme;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改颜色'),
        content: Wrap(
          spacing: AppSpacing.spacing4,
          runSpacing: AppSpacing.spacing4,
          children: _presetColors.map((color) {
            final parsed = ColorUtils.parseHexColor(color);
            final isSelected = folder.color == color;
            return GestureDetector(
              onTap: () async {
                final ok = await widget.onRecolor(folder.name, color);
                if (!ctx.mounted) { return; }
                Navigator.pop(ctx);
                if (ok) {
                  _replaceFolder(folder.name, color: color);
                } else {
                  _showError('修改颜色失败，请重试');
                }
              },
              child: Container(
                width: AppSizes.iconButtonMd,
                height: AppSizes.iconButtonMd,
                decoration: BoxDecoration(
                  color: parsed,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isSelected
                        ? colorScheme.onSurface
                        : Colors.transparent,
                    width: 3,
                  ),
                ),
                child: isSelected
                    ? Icon(Icons.check, color: colorScheme.onSurface, size: AppSizes.iconSm)
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
              final result = await widget.onDelete(folder.name);
              if (!ctx.mounted) { return; }
              Navigator.pop(ctx);
              switch (result) {
                case DeleteFolderResult.success:
                  _removeFolder(folder.name);
                  break;
                case DeleteFolderResult.notEmpty:
                  _showError('无法删除非空文件夹，请先移出其中的视频');
                  break;
                case DeleteFolderResult.notFound:
                  // 已被删除：同步本地列表即可，无需报错
                  _removeFolder(folder.name);
                  break;
                case DeleteFolderResult.saveFailed:
                  _showError('删除失败：文件夹信息保存出错，请重试');
                  break;
              }
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  /// 名称是否与现有文件夹重复（忽略首尾空格；用于创建与重命名查重）
  ///
  /// [excludeName] 用于重命名场景排除文件夹自身，避免"改成同名"被误判为重复。
  bool _isDuplicateName(String name, {String? excludeName}) {
    return _folders.any(
      (f) => f.name != excludeName && f.displayName == name,
    );
  }

  /// 显示错误提示（弹窗关闭后仍可见）
  void _showError(String message) {
    if (!mounted) { return; }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  /// 就地替换某文件夹的显示名/颜色并刷新弹窗列表
  void _replaceFolder(String name, {String? displayName, String? color}) {
    final index = _folders.indexWhere((f) => f.name == name);
    if (index == -1) { return; }
    setState(() {
      _folders[index] = _folders[index].copyWith(
        displayName: displayName,
        color: color,
      );
    });
  }

  /// 就地移除某文件夹并刷新弹窗列表
  void _removeFolder(String name) {
    setState(() {
      _folders.removeWhere((f) => f.name == name);
    });
  }

  /// 就地追加新建的文件夹并刷新弹窗列表（无需重开弹窗）
  void _addFolder(FolderData folder) {
    setState(() {
      _folders.add(folder);
    });
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

  /// 复制并覆盖部分字段
  ///
  /// 避免调用方逐字段重建实例：新增字段时不会因漏写而被静默重置为默认值。
  FolderData copyWith({
    String? name,
    String? displayName,
    String? color,
    int? videoCount,
  }) {
    return FolderData(
      name: name ?? this.name,
      displayName: displayName ?? this.displayName,
      color: color ?? this.color,
      videoCount: videoCount ?? this.videoCount,
    );
  }
}
