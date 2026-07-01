import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../theme/app_spacing.dart';

/// 增强进度条
///
/// 支持：
/// - 点击跳转到指定位置
/// - 拖动 seek
/// - 显示缓冲进度
/// - 显示当前时间和总时长
class PlayerProgressBar extends StatelessWidget {
  final VideoPlayerController controller;
  final bool isVisible;

  const PlayerProgressBar({
    super.key,
    required this.controller,
    required this.isVisible,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: controller,
      builder: (context, VideoPlayerValue value, child) {
        if (!value.isInitialized) {
          return const SizedBox.shrink();
        }

        final duration = value.duration;
        final position = value.position;
        final totalMs = duration.inMilliseconds.toDouble();
        final posMs = position.inMilliseconds.toDouble();
        final progress = totalMs > 0 ? posMs / totalMs : 0.0;

        return AnimatedOpacity(
          opacity: isVisible ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 200),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 进度条
                SizedBox(
                  height: 40,
                  child: Center(
                    child:                     _BufferedSlider(
                      progress: progress,
                      bufferedRanges: value.buffered,
                      duration: duration,
                      onSeek: controller.seekTo,
                    ),
                  ),
                ),
                // 时间显示
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _formatDuration(position),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        _formatDuration(duration),
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:$seconds';
    }
    return '$minutes:$seconds';
  }
}

/// 带缓冲区域显示的滑块
class _BufferedSlider extends StatefulWidget {
  final double progress;
  final List<DurationRange> bufferedRanges;
  final Duration duration;
  final ValueChanged<Duration> onSeek;

  const _BufferedSlider({
    required this.progress,
    required this.bufferedRanges,
    required this.duration,
    required this.onSeek,
  });

  @override
  State<_BufferedSlider> createState() => _BufferedSliderState();
}

class _BufferedSliderState extends State<_BufferedSlider> {
  bool _isDragging = false;
  double _dragValue = 0;

  double get _displayProgress => _isDragging ? _dragValue : widget.progress;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: _onTapDown,
      onHorizontalDragStart: _onDragStart,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            alignment: Alignment.centerLeft,
            children: [
              // 轨道背景
              Container(
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // 缓冲区域
              ..._buildBufferedRects(constraints.maxWidth),
              // 已播放轨道
              FractionallySizedBox(
                widthFactor: _displayProgress.clamp(0.0, 1.0),
                child: Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFF6366F1), // Indigo 主色
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // 滑块
              Positioned(
                left: (_displayProgress.clamp(0.0, 1.0) * constraints.maxWidth) - 7,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: _isDragging ? 18 : 14,
                  height: _isDragging ? 18 : 14,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black26,
                        blurRadius: 4,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                ),
              ),
              // 点击/拖动区域（比轨道高以便触摸）
              SizedBox(
                height: 40,
                width: constraints.maxWidth,
              ),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _buildBufferedRects(double totalWidth) {
    final totalMs = widget.duration.inMilliseconds.toDouble();
    if (totalMs <= 0) { return []; }

    final rects = <Widget>[];
    for (final range in widget.bufferedRanges) {
      final startFrac = (range.start.inMilliseconds / totalMs).clamp(0.0, 1.0);
      final endFrac = (range.end.inMilliseconds / totalMs).clamp(0.0, 1.0);
      if (endFrac <= startFrac) { continue; }

      rects.add(
        Positioned(
          left: startFrac * totalWidth,
          width: (endFrac - startFrac) * totalWidth,
          child: Container(
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      );
    }
    return rects;
  }

  void _onTapDown(TapDownDetails details) {
    final box = context.findRenderObject() as RenderBox;
    final localPos = details.localPosition;
    final fraction = (localPos.dx / box.size.width).clamp(0.0, 1.0);
    final seekMs = (fraction * widget.duration.inMilliseconds).round();
    // 单击：立即 seek（单次操作成本可控）
    widget.onSeek(Duration(milliseconds: seekMs));
  }

  void _onDragStart(DragStartDetails details) {
    final box = context.findRenderObject() as RenderBox;
    final localPos = box.globalToLocal(details.globalPosition);
    final fraction = (localPos.dx / box.size.width).clamp(0.0, 1.0);
    // 仅记录拖动起始状态，不 seek
    setState(() {
      _isDragging = true;
      _dragValue = fraction;
    });
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final box = context.findRenderObject() as RenderBox;
    final localPos = box.globalToLocal(details.globalPosition);
    final fraction = (localPos.dx / box.size.width).clamp(0.0, 1.0);
    // 仅更新 UI 预览，不 seek（避免加密视频频繁 seek 导致解码器卡死）
    setState(() => _dragValue = fraction);
  }

  void _onDragEnd(DragEndDetails details) {
    // 松手时才执行一次 seek
    final seekMs = (_dragValue * widget.duration.inMilliseconds).round();
    setState(() => _isDragging = false);
    widget.onSeek(Duration(milliseconds: seekMs));
  }
}
