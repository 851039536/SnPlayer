import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/video_item.dart';
import '../theme/app_spacing.dart';
import '../theme/app_radius.dart';

/// 视频卡片组件
///
/// 展示缩略图 + 标题 + 文件大小 + 处理状态
class VideoCard extends StatelessWidget {
  final VideoItem video;
  final String? processingState;
  final VoidCallback onTap;
  final VoidCallback? onPlay;
  final VoidCallback? onDecrypt;
  final VoidCallback? onRename;
  final VoidCallback? onMove;
  final VoidCallback? onDelete;

  const VideoCard({
    super.key,
    required this.video,
    this.processingState,
    required this.onTap,
    this.onPlay,
    this.onDecrypt,
    this.onRename,
    this.onMove,
    this.onDelete,
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
            // 缩略图区域
            _buildThumbnail(colorScheme),
            // 信息区域
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
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
                  SizedBox(height: AppSpacing.xs),
                  // 文件大小 + 时间
                  Row(
                    children: [
                      Icon(
                        Icons.movie_outlined,
                        size: 14,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      SizedBox(width: AppSpacing.xs),
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
                        SizedBox(width: AppSpacing.xs),
                        _ProcessingBadge(state: processingState!),
                      ],
                    ],
                  ),
                  if (video.folderName != null) ...[
                    SizedBox(height: AppSpacing.xs),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm, vertical: 2),
                      decoration: BoxDecoration(
                        color: colorScheme.secondaryContainer.withOpacity(0.4),
                        borderRadius: BorderRadius.circular(AppRadius.xs),
                      ),
                      child: Text(
                        video.folderName!,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnail(ColorScheme colorScheme) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 缩略图或占位符
          if (video.coverData != null)
            Image.memory(
              video.coverData!,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _buildPlaceholder(colorScheme),
            )
          else
            _buildPlaceholder(colorScheme),

          // 播放按钮覆盖层
          Positioned.fill(
            child: Center(
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 28,
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
            colorScheme.primaryContainer.withOpacity(0.3),
            colorScheme.secondaryContainer.withOpacity(0.3),
          ],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.video_library_rounded,
          size: 48,
          color: colorScheme.onSurface.withOpacity(0.2),
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
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm, vertical: 2),
      decoration: BoxDecoration(
        color: isError
            ? colorScheme.errorContainer.withOpacity(0.8)
            : colorScheme.primaryContainer.withOpacity(0.8),
        borderRadius: BorderRadius.circular(AppRadius.xs),
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
            Icon(Icons.error_outline, size: 12,
              color: colorScheme.onErrorContainer),
          SizedBox(width: AppSpacing.xs),
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
