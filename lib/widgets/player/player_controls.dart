import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../theme/app_spacing.dart';
import 'player_progress_bar.dart';
import 'speed_selector.dart';

/// 播放器底部控制栏
///
/// 包含进度条、时间显示、控制按钮组，默认始终可见。
class PlayerControls extends StatefulWidget {
  final VideoPlayerController controller;
  final VoidCallback onToggleFullscreen;

  const PlayerControls({
    super.key,
    required this.controller,
    required this.onToggleFullscreen,
  });

  @override
  State<PlayerControls> createState() => _PlayerControlsState();
}

class _PlayerControlsState extends State<PlayerControls> {
  double _currentSpeed = 1.0;

  @override
  void initState() {
    super.initState();
    _currentSpeed = widget.controller.value.playbackSpeed;
  }

  void _setSpeed(double speed) {
    widget.controller.setPlaybackSpeed(speed);
    setState(() => _currentSpeed = speed);
  }

  void _showSpeedSelector() {
    SpeedSelector.show(
      context: context,
      currentSpeed: _currentSpeed,
      onSpeedSelected: _setSpeed,
    );
  }

  void _skipBack() {
    final currentPos = widget.controller.value.position;
    final newPos = currentPos - const Duration(seconds: 10);
    final clamped = Duration(
      milliseconds: newPos.inMilliseconds.clamp(
        0,
        widget.controller.value.duration.inMilliseconds,
      ),
    );
    widget.controller.seekTo(clamped);
  }

  void _skipForward() {
    final currentPos = widget.controller.value.position;
    final newPos = currentPos + const Duration(seconds: 10);
    final clamped = Duration(
      milliseconds: newPos.inMilliseconds.clamp(
        0,
        widget.controller.value.duration.inMilliseconds,
      ),
    );
    widget.controller.seekTo(clamped);
  }

  String _speedLabel() {
    if (_currentSpeed == 1.0) { return '倍速'; }
    return '${_currentSpeed}x';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            Colors.black.withValues(alpha: 0.85),
            Colors.black.withValues(alpha: 0.4),
            Colors.transparent,
          ],
        ),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).padding.bottom + AppSpacing.sm,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 进度条区域
          PlayerProgressBar(
            controller: widget.controller,
            isVisible: true,
          ),
          // 控制按钮行
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xl,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // 左侧：倍速
                _buildLeftButtons(),
                // 中间：快退 + 播放暂停 + 快进
                _buildCenterButtons(),
                // 右侧：全屏
                _buildRightButtons(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLeftButtons() {
    return _ControlButton(
      onTap: _showSpeedSelector,
      child: Text(
        _speedLabel(),
        style: TextStyle(
          color: _currentSpeed != 1.0
              ? const Color(0xFF6366F1)
              : Colors.white70,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildCenterButtons() {
    return ValueListenableBuilder(
      valueListenable: widget.controller,
      builder: (context, VideoPlayerValue value, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 快退 10s
            _ControlButton(
              onTap: _skipBack,
              child: const Text(
                '-10s',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.lg),
            // 播放/暂停
            GestureDetector(
              onTap: () {
                if (value.isPlaying) {
                  widget.controller.pause();
                } else {
                  widget.controller.play();
                }
                setState(() {});
              },
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  value.isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 28,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.lg),
            // 快进 10s
            _ControlButton(
              onTap: _skipForward,
              child: const Text(
                '+10s',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildRightButtons() {
    return _ControlButton(
      onTap: widget.onToggleFullscreen,
      icon: Icons.fullscreen_rounded,
    );
  }
}

/// 控制按钮基础组件
class _ControlButton extends StatelessWidget {
  final VoidCallback? onTap;
  final IconData? icon;
  final Widget? child;

  const _ControlButton({
    this.onTap,
    this.icon,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: child ??
            Icon(
              icon,
              color: Colors.white70,
              size: 20,
            ),
      ),
    );
  }
}
