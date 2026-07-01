import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../services/crypto_service.dart';
import '../services/safe_delete_helper.dart';
import '../services/path_provider_service.dart';
import '../services/playback_cache_manager.dart';
import '../services/streaming_decrypt_proxy.dart';
import '../theme/app_font_size.dart';
import '../theme/app_font_size.dart';
import '../theme/app_spacing.dart';
import '../widgets/player/player_gesture.dart';
import '../widgets/player/player_controls.dart';

/// 视频播放页面
///
/// 播放策略（三段式，逐级降级）：
/// 1. 磁盘缓存命中 → 直接播放缓存文件（零解密等待）
/// 2. 流式解密代理 → 按需 Range 解密，秒级起播（首次播放）
/// 3. 全量解密回退 → 代理异常时使用原有 decryptToTemp 路径
///
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

  /// 流式解密代理（仅在使用代理播放时非 null）
  StreamingDecryptProxy? _proxy;

  /// 标记当前播放源是否为代理（dispose 时需停止代理）
  bool _usingProxy = false;

  /// 标记当前播放源是否为缓存文件（dispose 时不删除）
  bool _usingCache = false;

  bool _isFullscreen = false;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    try {
      final cacheDir = await PathProviderService.getCacheDir();

      // ── 阶段 1：检查磁盘缓存 ──
      final cachedFile = await PlaybackCacheManager.getCachedFile(
        widget.encPath,
        cacheDir,
      );
      if (cachedFile != null) {
        debugPrint('[SnPlayer] VideoPlayerScreen: 磁盘缓存命中，直接播放');
        try {
          _tempPath = cachedFile;
          _usingCache = true;
          _controller = VideoPlayerController.file(File(cachedFile));
          await _controller!.initialize();
          await _controller!.play();
          _setLoading(false);
          return;
        } catch (e) {
          // 缓存文件损坏（如流式代理遗留的全零文件），删除并降级
          debugPrint('[SnPlayer] VideoPlayerScreen: 缓存播放失败，降级到流式代理: $e');
          _controller?.dispose();
          _controller = null;
          _usingCache = false;
          _tempPath = null;
          await SafeDeleteHelper.fastDelete(cachedFile);
        }
      }

      // ── 阶段 2：流式解密代理 ──
      try {
        await _initWithProxy();
        return;
      } catch (e) {
        debugPrint('[SnPlayer] VideoPlayerScreen: 流式代理失败，降级全量解密: $e');
        // 清理代理资源
        await _proxy?.stop();
        _proxy = null;
        _usingProxy = false;
      }

      // ── 阶段 3：降级全量解密 ──
      await _initWithFullDecrypt(cacheDir);
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

  /// 使用流式解密代理初始化播放器
  Future<void> _initWithProxy() async {
    _proxy = StreamingDecryptProxy();
    await _proxy!.start(widget.encPath);
    _usingProxy = true;

    debugPrint('[SnPlayer] VideoPlayerScreen: 流式代理播放 ${_proxy!.proxyUrl}');
    _controller = VideoPlayerController.networkUrl(
      Uri.parse(_proxy!.proxyUrl),
    );

    await _controller!.initialize();
    await _controller!.play();
    _setLoading(false);
  }

  /// 降级路径：全量解密后播放（原有逻辑）
  Future<void> _initWithFullDecrypt(String cacheDir) async {
    debugPrint('[SnPlayer] VideoPlayerScreen: 全量解密播放');
    _tempPath = await CryptoService.decryptToTemp(widget.encPath, cacheDir);
    _controller = VideoPlayerController.file(File(_tempPath!));
    await _controller!.initialize();
    await _controller!.play();
    _setLoading(false);
  }

  void _setLoading(bool loading) {
    if (mounted) {
      setState(() {
        _isLoading = loading;
      });
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

    // 停止流式解密代理（如果在用）
    // stop() 内部首行即设置 _stopped=true 阻止新请求，
    // 后续异步清理（server close、文件 flush）可以 fire-and-forget
    if (_usingProxy && _proxy != null) {
      _proxy!.stop();
    }

    // 清理临时文件：
    // - 缓存命中的文件不删除（保留供二次播放）
    // - 代理播放的文件不删除（流式写入的缓存，保留供二次播放）
    // - 全量解密的临时文件删除（每次重新解密）
    if (_tempPath != null && !_usingCache && !_usingProxy) {
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
      body: SafeArea(
        top: false,
        child: Center(
          child: _buildContent(colorScheme),
        ),
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
          fontSize: AppFontSize.base,
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
          SizedBox(height: AppSpacing.spacing5),
          Text(
            '准备播放...',
            style: TextStyle(color: Colors.white70, fontSize: AppFontSize.sm),
          ),
        ],
      );
    }

    if (_error != null) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, size: 48, color: Colors.white70),
          const SizedBox(height: AppSpacing.spacing5),
          Text(
            _error!,
            style: const TextStyle(color: Colors.white70, fontSize: 15),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.spacing7),
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
