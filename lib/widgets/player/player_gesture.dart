import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// 手势检测层
///
/// 包裹视频画面，处理触摸手势交互：
/// - 单击：切换控制栏显隐
/// - 双击左半区：后退 10 秒
/// - 双击右半区：快进 10 秒
/// - 水平滑动：快速 seek
class PlayerGesture extends StatefulWidget {
  final Widget child;
  final VideoPlayerController controller;
  final VoidCallback onTap;
  final bool controlsVisible;

  const PlayerGesture({
    super.key,
    required this.child,
    required this.controller,
    required this.onTap,
    required this.controlsVisible,
  });

  @override
  State<PlayerGesture> createState() => _PlayerGestureState();
}

class _PlayerGestureState extends State<PlayerGesture> {
  // 双击检测
  DateTime? _lastTapTime;
  static const _doubleTapInterval = Duration(milliseconds: 300);

  // 跳过反馈
  bool _showSkipIndicator = false;
  String _skipText = '';
  Timer? _skipTimer;

  // 水平拖动 seek
  double? _dragStartPosition;
  Duration? _dragStartTime;

  // 垂直拖动 seek（细粒度）
  double? _verticalDragStartOffset;
  Duration? _verticalDragStartTime;
  double _accumulatedDrag = 0;
  static const double _seekPixelsPerSecond = 8.0; // 每像素对应多少毫秒的 seek

  @override
  void dispose() {
    _skipTimer?.cancel();
    super.dispose();
  }

  void _handleTapUp(TapUpDetails details) {
    final now = DateTime.now();
    if (_lastTapTime != null &&
        now.difference(_lastTapTime!) < _doubleTapInterval) {
      // 双击
      _handleDoubleTap(details);
    } else {
      // 延迟触发单击，以便区分双击
      _lastTapTime = now;
      Future.delayed(_doubleTapInterval, () {
        if (_lastTapTime == now) {
          widget.onTap();
        }
      });
    }
  }

  void _handleDoubleTap(TapUpDetails details) {
    _lastTapTime = null;
    final screenWidth = MediaQuery.of(context).size.width;
    final isRightHalf = details.globalPosition.dx > screenWidth / 2;

    final currentPos = widget.controller.value.position;
    final seekAmount = const Duration(seconds: 10);
    final newPos = isRightHalf
        ? currentPos + seekAmount
        : currentPos - seekAmount;

    final clamped = Duration(
      milliseconds: newPos.inMilliseconds.clamp(
        0,
        widget.controller.value.duration.inMilliseconds,
      ),
    );
    widget.controller.seekTo(clamped);

    // 流式代理下 seek 后可能进入 buffering 状态暂停，延迟恢复播放
    _ensurePlayAfterSeek();

    // 显示跳过提示
    _showSkipFeedback(isRightHalf);
  }

  /// seek 后确保恢复播放（流式代理下 ExoPlayer seek 后可能进入 buffering 暂停）
  void _ensurePlayAfterSeek() {
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted && !widget.controller.value.isPlaying) {
        widget.controller.play();
      }
    });
  }

  void _showSkipFeedback(bool isForward) {
    _skipTimer?.cancel();
    setState(() {
      _showSkipIndicator = true;
      _skipText = isForward ? '+10s' : '-10s';
    });
    _skipTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) {
        setState(() {
          _showSkipIndicator = false;
        });
      }
    });
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    _dragStartPosition = widget.controller.value.position.inMilliseconds.toDouble();
    _dragStartTime = widget.controller.value.position;
    _accumulatedDrag = 0;
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (_dragStartTime == null) { return; }
    _accumulatedDrag += details.primaryDelta ?? 0;
    final seekMs = (_accumulatedDrag * _seekPixelsPerSecond).round();
    final newMs = (_dragStartTime!.inMilliseconds + seekMs).clamp(
      0,
      widget.controller.value.duration.inMilliseconds,
    );
    widget.controller.seekTo(Duration(milliseconds: newMs));
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    _ensurePlayAfterSeek();
  }

  void _onVerticalDragStart(DragStartDetails details) {
    _verticalDragStartTime = widget.controller.value.position;
    _verticalDragStartOffset = details.globalPosition.dy;
    _accumulatedDrag = 0;
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (_verticalDragStartTime == null) { return; }
    _accumulatedDrag += details.primaryDelta ?? 0;
    final seekMs =
        (_accumulatedDrag * _seekPixelsPerSecond * 2).round(); // 垂直更快
    final newMs = (_verticalDragStartTime!.inMilliseconds + seekMs).clamp(
      0,
      widget.controller.value.duration.inMilliseconds,
    );
    widget.controller.seekTo(Duration(milliseconds: newMs));
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    _ensurePlayAfterSeek();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 手势层
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapUp: _handleTapUp,
          onHorizontalDragStart: _onHorizontalDragStart,
          onHorizontalDragUpdate: _onHorizontalDragUpdate,
          onHorizontalDragEnd: _onHorizontalDragEnd,
          onVerticalDragStart: _onVerticalDragStart,
          onVerticalDragUpdate: _onVerticalDragUpdate,
          onVerticalDragEnd: _onVerticalDragEnd,
          child: widget.child,
        ),

        // 跳过提示叠加层
        if (_showSkipIndicator)
          Center(
            child: AnimatedOpacity(
              opacity: _showSkipIndicator ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _skipText.startsWith('+')
                          ? Icons.fast_forward_rounded
                          : Icons.fast_rewind_rounded,
                      color: Colors.white,
                      size: 24,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _skipText,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
