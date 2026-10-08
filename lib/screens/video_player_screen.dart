// lib/screens/video_player_screen.dart — 视频播放页面（三段式降级播放 + 全量解密百分比进度）

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../services/crypto_service.dart';
import '../services/safe_delete_helper.dart';
import '../services/path_provider_service.dart';
import '../services/playback_cache_manager.dart';
import '../services/streaming_decrypt_proxy.dart';
import '../theme/app_font_size.dart';
import '../theme/app_sizes.dart';
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

  bool _isFullscreen = false;

  /// 全量解密回退的进度（0.0~1.0），null = 未进入全量解密阶段
  double? _decryptProgress;

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
          _controller = VideoPlayerController.file(File(cachedFile));
          await _controller!.initialize();
          await _controller!.play();
          _setLoading(false);
          return;
        } catch (e) {
          // 缓存文件损坏（如磁盘异常/半成品残留），删除并降级
          debugPrint('[SnPlayer] VideoPlayerScreen: 缓存播放失败，降级到流式代理: $e');
          _controller?.dispose();
          _controller = null;
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
        // 清理代理资源 + controller（_initWithProxy 内部可能已创建 controller）
        _controller?.dispose();
        _controller = null;
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

    try {
      await _controller!.initialize();
      await _controller!.play();
      _setLoading(false);
    } catch (e) {
      // initialize/play 失败时必须 dispose controller，避免 ExoPlayer 原生资源泄露
      _controller?.dispose();
      _controller = null;
      rethrow;
    }
  }

  /// 降级路径：全量解密后播放，解密进度显示在 loading 视图
  ///
  /// 解密产物写入 play_ 缓存路径并保留（二次播放阶段 1 直接命中），
  /// 生命周期交给 PlaybackCacheManager 的 3 天过期 + 500MB LRU 管理。
  Future<void> _initWithFullDecrypt(String cacheDir) async {
    debugPrint('[SnPlayer] VideoPlayerScreen: 全量解密播放');
    _tempPath = await CryptoService.decryptToTemp(
      widget.encPath,
      cacheDir,
      onProgress: _onDecryptProgress,
    );
    _controller = VideoPlayerController.file(File(_tempPath!));
    await _controller!.initialize();
    await _controller!.play();
    _setLoading(false);
  }

  /// 解密进度回调（整数百分比变化才 setState，避免高频重建）
  void _onDecryptProgress(double value) {
    final oldPercent =
        _decryptProgress == null ? -1 : (_decryptProgress! * 100).floor();
    if ((value * 100).floor() == oldPercent) { return; }
    if (mounted) {
      setState(() {
        _decryptProgress = value;
      });
    }
  }

  void _setLoading(bool loading) {
    if (mounted) {
      setState(() {
        _isLoading = loading;
      });
    }
  }

  // --- 全屏 ---

  /// 切换全屏：隐藏系统栏 + 横屏；退出时恢复系统栏 + 竖屏
  Future<void> _toggleFullscreen() async {
    final entering = !_isFullscreen;
    setState(() => _isFullscreen = entering);

    if (entering) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.edgeToEdge,
        overlays: SystemUiOverlay.values,
      );
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
    }
  }

  /// 恢复系统 UI 与方向（dispose 时必须调用，否则退出页面后仍停留在全屏态）
  Future<void> _restoreSystemUi() async {
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
      overlays: SystemUiOverlay.values,
    );
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
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
    // 退出页面时务必恢复系统栏与方向，否则会残留全屏态影响列表页
    unawaited(_restoreSystemUi());

    _controller?.dispose();

    // 停止流式解密代理（如果在用）
    // stop() 内部首行即设置 _stopped=true 阻止新请求，
    // 后续异步清理（server close、文件 flush）可以 fire-and-forget
    if (_usingProxy && _proxy != null) {
      unawaited(_proxy!.stop());
    }

    // 磁盘缓存文件（缓存命中/全量解密产物）均保留供二次播放，
    // 由 PlaybackCacheManager 的过期/LRU 清理管理生命周期；
    // 代理播放纯内存解密不落盘（_tempPath 恒为 null），无需清理

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Colors.black,
      // 全屏时隐藏 AppBar，把整屏交给视频
      appBar: _isFullscreen ? null : _buildAppBar(colorScheme),
      body: SafeArea(
        // 非全屏时 AppBar 已占据顶部，无需再让出安全区
        top: _isFullscreen,
        child: Center(
          child: _buildContent(colorScheme),
        ),
      ),
    );
  }

  PreferredSizeWidget? _buildAppBar(ColorScheme colorScheme) {
    return AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      elevation: 0,
      title: Text(
        widget.title,
        style: const TextStyle(
          color: Colors.white,
          fontSize: AppFontSize.base,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildContent(ColorScheme colorScheme) {
    if (_isLoading) {
      final progress = _decryptProgress;
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (progress == null)
            const CircularProgressIndicator(color: Colors.white70)
          else
            SizedBox(
              width: 220,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 6,
                  color: Colors.white70,
                  backgroundColor: Colors.white24,
                ),
              ),
            ),
          const SizedBox(height: AppSpacing.spacing5),
          Text(
            progress == null
                ? '准备播放...'
                : '正在解密 ${(progress * 100).floor()}%',
            style: const TextStyle(color: Colors.white70, fontSize: AppFontSize.sm),
          ),
        ],
      );
    }

    if (_error != null) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline,
              size: AppSizes.emptyStateIcon, color: Colors.white70),
          const SizedBox(height: AppSpacing.spacing5),
          Text(
            _error!,
            style: const TextStyle(color: Colors.white70, fontSize: AppFontSize.sm),
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
