import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../services/crypto_service.dart';
import '../services/safe_delete_helper.dart';
import '../services/path_provider_service.dart';
import '../config/crypto.dart';
import '../theme/app_spacing.dart';

/// 视频播放页面
///
/// 内置播放器，解密到临时缓存后播放，退出时 30s 自动清理
class VideoPlayerScreen extends StatefulWidget {
  final String encPath;
  final String title;

  const VideoPlayerScreen({
    super.key,
    required this.encPath,
    required this.title,
  });

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  VideoPlayerController? _controller;
  bool _isLoading = true;
  String? _error;
  String? _tempPath;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    try {
      final cacheDir = await PathProviderService.getCacheDir();
      _tempPath = await CryptoService.decryptToTemp(widget.encPath, cacheDir);

      _controller = VideoPlayerController.file(
        File(_tempPath!),
      );

      await _controller!.initialize();
      await _controller!.play();

      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }

      // 30 秒后自动删除临时文件
      if (mounted) {
        Future.delayed(
          Duration(milliseconds: playCacheDeleteDelayMs),
          () {
            if (_tempPath != null) {
              SafeDeleteHelper.safeDelete(_tempPath!);
            }
          },
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = '播放失败: $e';
        });
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    // 离开页面时立即清理临时文件
    if (_tempPath != null) {
      SafeDeleteHelper.safeDelete(_tempPath!);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: colorScheme.surface.withOpacity(0.85),
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
        title: Text(
          widget.title,
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      ),
      body: Center(
        child: _buildContent(colorScheme),
      ),
    );
  }

  Widget _buildContent(ColorScheme colorScheme) {
    if (_isLoading) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(
            color: colorScheme.onSurface.withOpacity(0.7)),
          SizedBox(height: AppSpacing.xl),
          Text(
            '正在解密视频...',
            style: TextStyle(
              color: colorScheme.onSurface.withOpacity(0.7)),
          ),
        ],
      );
    }

    if (_error != null) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 48, color: colorScheme.error),
          SizedBox(height: AppSpacing.xl),
          Text(
            _error!,
            style: TextStyle(
              color: colorScheme.onSurface.withOpacity(0.7)),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: AppSpacing.xxxl),
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('返回'),
          ),
        ],
      );
    }

    if (_controller != null && _controller!.value.isInitialized) {
      return GestureDetector(
        onTap: () {
          if (_controller!.value.isPlaying) {
            _controller!.pause();
          } else {
            _controller!.play();
          }
          setState(() {});
        },
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 视频
            Center(
              child: AspectRatio(
                aspectRatio: _controller!.value.aspectRatio,
                child: VideoPlayer(_controller!),
              ),
            ),

            // 播放/暂停控制
            if (!_controller!.value.isPlaying)
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: colorScheme.surface.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(32),
                ),
                child: Icon(
                  Icons.play_arrow_rounded,
                  color: colorScheme.onSurface,
                  size: 40,
                ),
              ),

            // 底部进度条
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: _buildProgressBar(),
            ),
          ],
        ),
      );
    }

    return const SizedBox.shrink();
  }

  Widget _buildProgressBar() {
    if (_controller == null) { return const SizedBox.shrink(); }

    return ValueListenableBuilder(
      valueListenable: _controller!,
      builder: (context, VideoPlayerValue value, child) {
        final duration = value.duration.inMilliseconds.toDouble();
        final position = value.position.inMilliseconds.toDouble();
        final progress = duration > 0 ? position / duration : 0.0;
        final colorScheme = Theme.of(context).colorScheme;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: colorScheme.onSurface,
                inactiveTrackColor: colorScheme.onSurface.withOpacity(0.15),
                thumbColor: colorScheme.onSurface,
              ),
              child: Slider(
                value: progress.clamp(0.0, 1.0),
                onChanged: (v) {
                  final newPosition =
                      Duration(milliseconds: (v * duration).round());
                  _controller!.seekTo(newPosition);
                },
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                AppSpacing.xl, 0, AppSpacing.xl, AppSpacing.md),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _formatDuration(value.position),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurface.withOpacity(0.7),
                    ),
                  ),
                  Text(
                    _formatDuration(value.duration),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurface.withOpacity(0.7),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
