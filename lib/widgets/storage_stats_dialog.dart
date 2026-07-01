import 'package:flutter/material.dart';

import '../utils/file_utils.dart';
import '../theme/app_spacing.dart';
import '../theme/app_radius.dart';
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

    return AlertDialog(
      backgroundColor: colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xxl)),
      title: Row(
        children: [
          Icon(Icons.storage_rounded, color: colorScheme.primary),
          const SizedBox(width: 10),
          const Text('存储统计'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildStatRow(
            context,
            icon: Icons.videocam_rounded,
            label: '加密视频',
            count: encCount,
            size: encSize,
            color: colorScheme.primary,
          ),
          const SizedBox(height: AppSpacing.spacing4),
          _buildStatRow(
            context,
            icon: Icons.image_rounded,
            label: '缩略图',
            count: tencCount,
            size: tencSize,
            color: AppColors.success,
          ),
          const SizedBox(height: AppSpacing.spacing4),
          _buildStatRow(
            context,
            icon: Icons.cached_rounded,
            label: '缓存文件',
            count: cacheCount,
            size: cacheSize,
            color: AppColors.warning,
          ),
          const SizedBox(height: AppSpacing.spacing5),
          Divider(color: colorScheme.outlineVariant),
          const SizedBox(height: AppSpacing.spacing3),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('总计',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                FileUtils.formatFileSize(encSize + tencSize + cacheSize),
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: colorScheme.primary,
                ),
              ),
            ],
          ),
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
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(width: AppSpacing.spacing4),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              Text('$count 个文件',
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
}
