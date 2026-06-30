import 'package:flutter/material.dart';

import '../models/video_folder.dart';
import '../theme/app_spacing.dart';
import '../theme/app_radius.dart';
import '../utils/color_utils.dart';

/// 文件夹标签栏组件
///
/// 横向滚动的 TabBar 风格标签
class FolderTabs extends StatelessWidget {
  final List<VideoFolder> folders;
  final String? selectedFolder;
  final ValueChanged<String?> onSelect;
  final VoidCallback? onManage;

  const FolderTabs({
    super.key,
    required this.folders,
    required this.selectedFolder,
    required this.onSelect,
    this.onManage,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return SizedBox(
      height: 40,
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              children: [
                // "全部" 标签
                _buildTab(
                  context,
                  label: '全部',
                  isSelected: selectedFolder == null,
                  color: colorScheme.primary,
                  onTap: () => onSelect(null),
                ),

                // 文件夹标签
                ...folders.map((folder) {
                  final color = ColorUtils.parseHexColor(folder.color) ?? colorScheme.primary;
                  return _buildTab(
                    context,
                    label: folder.displayName,
                    isSelected: selectedFolder == folder.name,
                    color: color,
                    onTap: () => onSelect(folder.name),
                    onLongPress: onManage,
                  );
                }),
              ],
            ),
          ),

          // 文件夹管理按钮
          if (onManage != null)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.xs),
              child: IconButton(
                icon: Icon(
                  Icons.folder_rounded,
                  color: colorScheme.onSurfaceVariant,
                  size: 22,
                ),
                tooltip: '管理文件夹',
                onPressed: onManage,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTab(
    BuildContext context, {
    required String label,
    required bool isSelected,
    required Color color,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        margin: const EdgeInsets.only(
          right: AppSpacing.md,
          top: AppSpacing.xs,
          bottom: AppSpacing.xs,
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          color: isSelected
              ? color.withValues(alpha: 0.2)
              : colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(AppRadius.xxl),
          border: Border.all(
            color: isSelected ? color : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Center(
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: isSelected ? color : colorScheme.onSurfaceVariant,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }

}
