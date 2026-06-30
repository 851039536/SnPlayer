import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../services/crypto_service.dart';
import '../services/safe_delete_helper.dart';
import '../services/path_provider_service.dart';
import '../theme/app_spacing.dart';
import '../widgets/player/player_gesture.dart';
import '../widgets/player/player_controls.dart';

/// 视频播放页面
///
/// 内置播放器，解密到临时缓存后播放，退出页面时自动清理临时文件。
/// 大文件（≥64MB）自动启用并行分块解密加速。
/// 支持手势控制（双击跳过、滑动 seek）、控制按钮、倍速等功能。
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

  bool _isFullscreen = false;

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
    } catch (e) {
      debugPrint('[SnPlayer] VideoPlayerScreen._initPlayer: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = '播放失败: $e';
        });
      }
    }
  }

  // --- 全屏 ---

  void _toggleFullscreen() {
    setState(() => _isFullscreen = !_isFullscreen);
  }

  // --- 手势回调 ---

  void _onGestureTap() {
    if (_controller == null) { return; }
    if (_controller!.value.isPlaying) {
      _controller!.pause();
    } else {
      _controller!.play();
    }
    setState(() {});
  }

  @override
  void dispose() {
    _controller?.dispose();
    // 离开页面时立即清理临时文件
    if (_tempPath != null) {
      SafeDeleteHelper.fastDelete(_tempPath!);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: _buildAppBar(colorScheme),
      body: Center(
        child: _buildContent(colorScheme),
      ),
    );
  }

  PreferredSizeWidget? _buildAppBar(ColorScheme colorScheme) {
    return AppBar(
      backgroundColor: Colors.black.withValues(alpha: 0.6),
      foregroundColor: Colors.white,
      elevation: 0,
      title: Text(
        widget.title,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
        ),
      ),
    );
  }

  Widget _buildContent(ColorScheme colorScheme) {
    if (_isLoading) {
      return const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: Colors.white70),
          SizedBox(height: AppSpacing.xl),
          Text(
            '正在解密视频...',
            style: TextStyle(color: Colors.white70, fontSize: 15),
          ),
        ],
      );
    }

    if (_error != null) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 48, color: Colors.white70),
          const SizedBox(height: AppSpacing.xl),
          Text(
            _error!,
            style: const TextStyle(color: Colors.white70, fontSize: 15),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.xxxl),
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('返回'),
          ),
        ],
      );
    }

    if (_controller != null && _controller!.value.isInitialized) {
      return _buildPlayer(colorScheme);
    }

    return const SizedBox.shrink();
  }

  Widget _buildPlayer(ColorScheme colorScheme) {
    return PlayerGesture(
      controller: _controller!,
      onTap: _onGestureTap,
      controlsVisible: true,
      child: Stack(
        fit: StackFit.expand,
        alignment: Alignment.center,
        children: [
          // 视频画面
          Center(
            child: AspectRatio(
              aspectRatio: _controller!.value.aspectRatio,
              child: VideoPlayer(_controller!),
            ),
          ),

          // 底部控制栏
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: PlayerControls(
              controller: _controller!,
              onToggleFullscreen: _toggleFullscreen,
            ),
          ),
        ],
      ),
    );
  }
}
