// lib/widgets/storage_stats_dialog.dart — 存储统计弹窗（永久数据/可清理缓存分组 + 占用与可清理双总计）

import 'package:flutter/material.dart';

import '../utils/file_utils.dart';
import '../theme/app_spacing.dart';
import '../theme/app_radius.dart';
import '../theme/app_sizes.dart';
import '../theme/app_colors.dart';

/// 存储统计弹窗
class StorageStatsDialog extends StatelessWidget {
  final Map<String, dynamic> stats;

  const StorageStatsDialog({super.key, required this.stats});

  /// 显示存储统计弹窗
  static Future<void> show(BuildContext context, Map<String, dynamic> stats) {
    return showDialog(
      context: context,
      builder: (_) => StorageStatsDialog(stats: stats),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final encCount = stats['encCount'] as int? ?? 0;
    final encSize = stats['encSize'] as int? ?? 0;
    final tencCount = stats['tencCount'] as int? ?? 0;
    final tencSize = stats['tencSize'] as int? ?? 0;
    final cacheCount = stats['cacheCount'] as int? ?? 0;
    final cacheSize = stats['cacheSize'] as int? ?? 0;
    final thumbCacheCount = stats['thumbCacheCount'] as int? ?? 0;
    final thumbCacheSize = stats['thumbCacheSize'] as int? ?? 0;

    final totalSize = encSize + tencSize + cacheSize + thumbCacheSize;
    final clearableSize = cacheSize + thumbCacheSize;

    return AlertDialog(
      backgroundColor: colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xxl)),
      title: Row(
        children: [
          Icon(Icons.storage_rounded,
            color: colorScheme.primary, size: AppSizes.iconSm),
          const SizedBox(width: AppSpacing.spacing2),
          const Text('存储统计'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 永久数据（删除需重新生成，不可通过"清理缓存"释放）
          _buildSectionLabel(context, '永久数据'),
          _buildStatRow(
            context,
            icon: Icons.videocam_rounded,
            label: '加密视频',
            count: encCount,
            size: encSize,
            color: colorScheme.primary,
          ),
          const SizedBox(height: AppSpacing.spacing3),
          _buildStatRow(
            context,
            icon: Icons.image_rounded,
            label: '缩略图源',
            count: tencCount,
            size: tencSize,
            color: AppColors.success,
          ),

          const SizedBox(height: AppSpacing.spacing4),

          // 可清理缓存（点击"清理缓存"即可释放）
          _buildSectionLabel(context, '可清理缓存'),
          _buildStatRow(
            context,
            icon: Icons.play_circle_outline_rounded,
            label: '播放缓存',
            count: cacheCount,
            size: cacheSize,
            color: AppColors.warning,
          ),
          const SizedBox(height: AppSpacing.spacing3),
          _buildStatRow(
            context,
            icon: Icons.cached_rounded,
            label: '缩略图缓存',
            count: thumbCacheCount,
            size: thumbCacheSize,
            color: AppColors.brand,
          ),

          const SizedBox(height: AppSpacing.spacing3),
          Divider(color: colorScheme.outlineVariant, height: AppSpacing.spacing5),
          _buildTotalRow(context, '占用总量',
            FileUtils.formatFileSize(totalSize), colorScheme.primary),
          const SizedBox(height: AppSpacing.spacing2),
          _buildTotalRow(context, '其中可清理',
            FileUtils.formatFileSize(clearableSize), AppColors.warning),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  /// 分组标题
  Widget _buildSectionLabel(BuildContext context, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.spacing2),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildStatRow(
    BuildContext context, {
    required IconData icon,
    required String label,
    required int count,
    required int size,
    required Color color,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return Row(
      children: [
        Container(
          width: AppSizes.iconButtonXs,
          height: AppSizes.iconButtonXs,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Icon(icon, color: color, size: AppSizes.iconXs),
        ),
        const SizedBox(width: AppSpacing.spacing3),
        Expanded(
          child: Row(
            children: [
              Text(label,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(width: AppSpacing.spacing2),
              Text('$count 个',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Text(
          FileUtils.formatFileSize(size),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w500,
            color: color,
          ),
        ),
      ],
    );
  }

  /// 总计行（占用总量 / 可清理）
  Widget _buildTotalRow(
    BuildContext context, String label, String value, Color valueColor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        Text(value,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: valueColor,
          ),
        ),
      ],
    );
  }
}
