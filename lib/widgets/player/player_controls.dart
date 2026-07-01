import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_font_size.dart';
import '../../theme/app_sizes.dart';
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
  Timer? _playAfterSeekTimer;
  Timer? _playRetryTimer;

  @override
  void initState() {
    super.initState();
    _currentSpeed = widget.controller.value.playbackSpeed;
  }

  @override
  void dispose() {
    _playAfterSeekTimer?.cancel();
    _playRetryTimer?.cancel();
    super.dispose();
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
    _ensurePlayAfterSeek();
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
    _ensurePlayAfterSeek();
  }

  /// seek 后确保恢复播放
  void _ensurePlayAfterSeek() {
    _playAfterSeekTimer?.cancel();
    _playAfterSeekTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted && !widget.controller.value.isPlaying) {
        widget.controller.play();
      }
    });
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
        bottom: MediaQuery.of(context).padding.bottom + AppSpacing.spacing2,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PlayerProgressBar(
            controller: widget.controller,
            isVisible: true,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.spacing5,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _buildLeftButtons(),
                _buildCenterButtons(),
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
              ? AppColors.brand
              : Colors.white70,
          fontSize: AppFontSize.xs,
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
            _ControlButton(
              onTap: _skipBack,
              child: const Text(
                '-10s',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: AppFontSize.xs,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.spacing4),
            GestureDetector(
              onTap: () {
                if (value.isPlaying) {
                  widget.controller.pause();
                } else {
                  widget.controller.play();
                  _playRetryTimer?.cancel();
                  _playRetryTimer = Timer(const Duration(milliseconds: 500), () {
                    if (mounted && !widget.controller.value.isPlaying) {
                      widget.controller.play();
                    }
                  });
                }
                setState(() {});
              },
              child: Container(
                width: AppSizes.iconButtonMd,
                height: AppSizes.iconButtonMd,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  value.isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: AppSizes.iconXl,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.spacing4),
            _ControlButton(
              onTap: _skipForward,
              child: const Text(
                '+10s',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: AppFontSize.xs,
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
        padding: const EdgeInsets.all(AppSpacing.spacing3),
        child: child ??
            Icon(
              icon,
              color: Colors.white70,
              size: AppSizes.iconSm,
            ),
      ),
    );
  }
}
