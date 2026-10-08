// lib/widgets/video_detail_sheet.dart — 视频详细信息底部弹窗（文件名/大小/路径/文件夹/加密日期等）

import 'dart:io';

import 'package:flutter/material.dart';

import '../models/video_item.dart';
import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_sizes.dart';
import '../theme/app_spacing.dart';
import 'sheet_handle.dart';

/// 视频详细信息底部弹窗
class VideoDetailSheet {
  VideoDetailSheet._();

  /// 显示视频文件详细信息底部弹窗
  static void show(BuildContext context, VideoItem video) {
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
                  const SheetHandle(
                    topPadding: AppSpacing.spacing2,
                    bottomPadding: AppSpacing.spacing2,
                  ),

                  // 标题区
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sheetHorizontal,
                      vertical: AppSpacing.spacing3),
                    child: Row(
                      children: [
                        Container(
                          width: AppSizes.iconXxl,
                          height: AppSizes.iconXxl,
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
  static Widget _buildDetailRow(
    BuildContext ctx,
    IconData icon,
    String label,
    String value,
  ) {
    final colorScheme = Theme.of(ctx).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sheetHorizontal,
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
}
