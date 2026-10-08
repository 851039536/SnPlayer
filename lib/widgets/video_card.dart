import 'dart:io';

import 'package:flutter/material.dart';

import '../models/video_item.dart';
import '../config/crypto.dart';
import '../utils/color_utils.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_radius.dart';
import '../theme/app_sizes.dart';

/// 视频卡片组件
///
/// 展示缩略图 + 标题 + 文件大小 + 处理状态
/// 使用 Image.file + cacheWidth/cacheHeight 替代 Image.memory，
/// 缩略图由 Flutter 内置 ImageCache 管理内存（LRU 淘汰）
class VideoCard extends StatelessWidget {
  final VideoItem video;
  final String? processingState;
  final VoidCallback onTap;

  /// 所属文件夹的显示名（null = 根目录，或未提供）
  ///
  /// 注意不能直接用 [VideoItem.folderName]：那是物理目录名
  /// （如 folder_20260728153000_a1b2c3），对用户无意义。
  final String? folderLabel;

  /// 所属文件夹的颜色（十六进制），与文件夹标签栏保持一致
  final String? folderColor;

  const VideoCard({
    super.key,
    required this.video,
    this.processingState,
    required this.onTap,
    this.folderLabel,
    this.folderColor,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 缩略图区域：固定 16:9，不再用 Expanded 抢占剩余高度
            // （Expanded + AspectRatio 在正方形网格单元内会互相争夺高度导致布局冲突）
            _buildThumbnail(colorScheme),
            // 信息区域：占据剩余高度，超长内容裁切而非溢出报错
            Expanded(child: _buildInfo(context, colorScheme)),
          ],
        ),
      ),
    );
  }

  /// 信息区域（标题 / 文件大小 / 文件夹标签）
  Widget _buildInfo(BuildContext context, ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.spacing2, AppSpacing.spacing2, AppSpacing.spacing2, AppSpacing.spacing1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题
          Text(
            video.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
          ),
          const SizedBox(height: AppSpacing.spacing1),
          // 文件大小 + 处理状态
          Row(
            children: [
              Icon(
                Icons.movie_outlined,
                size: AppSizes.iconSm,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppSpacing.spacing1),
              Expanded(
                child: Text(
                  video.formattedSize,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (processingState != null) ...[
                const SizedBox(width: AppSpacing.spacing1),
                _ProcessingBadge(state: processingState!),
              ],
            ],
          ),
          if (folderLabel != null) ...[
            const SizedBox(height: AppSpacing.spacing2),
            // 用文件夹自身颜色，与标签栏色彩语言保持一致；
            // 超长时省略，避免撑破卡片
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.spacing2, vertical: 2),
              decoration: BoxDecoration(
                color: folderTint.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.folder_rounded,
                      size: AppSizes.iconXxs, color: folderTint),
                  const SizedBox(width: AppSpacing.spacing1),
                  Flexible(
                    child: Text(
                      folderLabel!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: folderTint,
                            fontWeight: FontWeight.w500,
                          ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 文件夹标签配色：优先用文件夹自身颜色，缺失时回退品牌色
  Color get folderTint {
    final hex = folderColor;
    if (hex == null) { return AppColors.brand; }
    return ColorUtils.parseHexColor(hex) ?? AppColors.brand;
  }

  Widget _buildThumbnail(ColorScheme colorScheme) {
    return AspectRatio(
      aspectRatio: AppSizes.videoThumbnailAspectRatio,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 磁盘缓存缩略图或占位符
          // 纯内存判断 thumbCachePath != null，避免同步 I/O
          // errorBuilder 兜底：缓存文件被意外清理时回退占位图
          if (video.thumbCachePath != null)
            Image.file(
              File(video.thumbCachePath!),
              fit: BoxFit.cover,
              cacheWidth: thumbnailWidth,
              cacheHeight: thumbnailHeight,
              errorBuilder: (_, __, ___) => _buildPlaceholder(colorScheme),
            )
          else
            _buildPlaceholder(colorScheme),

          // 播放按钮覆盖层
          Positioned.fill(
            child: Center(
              child: Container(
                width: AppSizes.iconButtonMd,
                height: AppSizes.iconButtonMd,
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(AppSizes.iconButtonMd / 2),
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: AppSizes.iconXl,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceholder(ColorScheme colorScheme) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.primaryContainer.withValues(alpha: 0.3),
            colorScheme.secondaryContainer.withValues(alpha: 0.3),
          ],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.video_library_rounded,
          size: AppSizes.iconXxl,
          color: colorScheme.onSurface.withValues(alpha: 0.2),
        ),
      ),
    );
  }
}

/// 处理状态徽章
class _ProcessingBadge extends StatelessWidget {
  final String state;

  const _ProcessingBadge({required this.state});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isError = state.contains('失败');

    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: AppSpacing.spacing2, vertical: 2),
      decoration: BoxDecoration(
        color: isError
            ? colorScheme.errorContainer.withValues(alpha: 0.8)
            : colorScheme.primaryContainer.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isError)
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: colorScheme.onPrimaryContainer,
              ),
            )
          else
            Icon(Icons.error_outline,
                size: AppSizes.iconXxs, color: colorScheme.onErrorContainer),
          const SizedBox(width: AppSpacing.spacing1),
          Text(
            state,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: isError
                      ? colorScheme.onErrorContainer
                      : colorScheme.onPrimaryContainer,
                ),
          ),
        ],
      ),
    );
  }
}
