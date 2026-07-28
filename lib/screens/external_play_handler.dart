// lib/screens/external_play_handler.dart — 第三方播放器打开逻辑（缓存直开/流式代理/全量解密降级 + 进度对话框）

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/video_item.dart';
import '../services/crypto_service.dart';
import '../services/path_provider_service.dart';
import '../services/playback_cache_manager.dart';
import '../services/streaming_decrypt_proxy.dart';
import '../widgets/crypto_progress_dialog.dart';

/// 第三方播放器打开处理器
///
/// 三级策略：磁盘缓存直开 → 流式解密代理 URL → 全量解密降级。
/// 持有流式代理实例（第三方播放期间需保持运行），
/// 宿主页面 dispose 时必须调用 [dispose] 停止代理。
class ExternalPlayHandler {
  static const _fileChannel = MethodChannel('com.snplayer.sn_player/file');

  /// 第三方播放器使用的流式解密代理（页面存活期间保持）
  StreamingDecryptProxy? _proxy;

  /// 用第三方播放器打开加密视频
  Future<void> play(BuildContext context, VideoItem video) async {
    // 进度对话框是否已弹出（catch 中据此决定是否 pop，防止误弹出页面）
    bool dialogShown = false;
    CryptoProgressController? controller;

    void closeDialog() {
      if (dialogShown && context.mounted) {
        Navigator.pop(context);
      }
      dialogShown = false;
      controller?.dispose();
      controller = null;
    }

    try {
      final cacheDir = await PathProviderService.getCacheDir();

      // ── 阶段 1：磁盘缓存命中 → 直接打开缓存文件（零解密） ──
      final cachedFile = await PlaybackCacheManager.getCachedFile(
        video.encPath, cacheDir,
      );
      if (cachedFile != null) {
        debugPrint('[SnPlayer] ExternalPlayHandler: 磁盘缓存命中，直接打开');
        await _fileChannel.invokeMethod('openFile', {'path': cachedFile});
        return;
      }

      // ── 阶段 2：流式解密代理 → HTTP URL 打开第三方播放器 ──
      if (!context.mounted) { return; }
      controller = CryptoProgressController(
        label: '正在启动流式播放',
        fileName: video.displayName,
      );
      CryptoProgressDialog.show(context, controller!);
      dialogShown = true;

      // 停止上一次的代理（如有）
      await _proxy?.stop();
      _proxy = null;

      _proxy = StreamingDecryptProxy();
      await _proxy!.start(video.encPath);

      closeDialog();

      debugPrint('[SnPlayer] ExternalPlayHandler: 流式代理 ${_proxy!.proxyUrl}');
      await _fileChannel.invokeMethod('openUrl', {
        'url': _proxy!.proxyUrl,
      });
      // 代理在页面存活期间保持运行，宿主 dispose 时自动停止
    } on PlatformException catch (e) {
      closeDialog();
      debugPrint('[SnPlayer] ExternalPlayHandler.play PlatformException: code=${e.code}, msg=${e.message}');

      if (e.code == 'NO_PLAYER') {
        // 清理已启动的代理资源（openUrl 失败，代理仍在运行）
        await _proxy?.stop();
        _proxy = null;
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('没有找到可播放视频的应用，请安装 MX Player 或 VLC')),
          );
        }
        return;
      }

      // 其他错误尝试降级全量解密
      if (context.mounted) {
        await _playFallback(context, video);
      }
    } catch (e) {
      closeDialog();
      debugPrint('[SnPlayer] ExternalPlayHandler.play: $e，降级全量解密');
      if (context.mounted) {
        await _playFallback(context, video);
      }
    }
  }

  /// 降级路径：全量解密（带百分比进度对话框）后用原生 openFile 打开
  Future<void> _playFallback(BuildContext context, VideoItem video) async {
    final controller = CryptoProgressController(
      label: '正在解密',
      fileName: video.displayName,
      progress: 0.0,
    );
    bool dialogShown = false;

    void closeDialog() {
      if (dialogShown && context.mounted) {
        Navigator.pop(context);
      }
      dialogShown = false;
    }

    try {
      CryptoProgressDialog.show(context, controller);
      dialogShown = true;

      // 停止代理（全量解密不需要代理）
      await _proxy?.stop();
      _proxy = null;

      final unlockDir = await PathProviderService.getUnlockVideoDir();
      await Directory(unlockDir).create(recursive: true);
      final tempPath = '$unlockDir/${video.displayName}.mp4';
      await CryptoService.decryptFile(
        video.encPath,
        tempPath,
        onProgress: controller.updateProgress,
      );

      closeDialog();

      await _fileChannel.invokeMethod('openFile', {'path': tempPath});
    } on PlatformException catch (e) {
      closeDialog();
      debugPrint('[SnPlayer] ExternalPlayHandler._playFallback PlatformException: code=${e.code}, msg=${e.message}');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_errorMessage(e.code, e.message))),
        );
      }
    } catch (e) {
      closeDialog();
      debugPrint('[SnPlayer] ExternalPlayHandler._playFallback: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('打开失败，请检查是否安装了播放器')),
        );
      }
    } finally {
      controller.dispose();
    }
  }

  /// 将原生错误码转为用户可读的错误提示
  String _errorMessage(String code, String? message) {
    switch (code) {
      case 'NO_PLAYER':
        return '没有找到可播放视频的应用，请安装 MX Player 或 VLC';
      case 'FILE_NOT_FOUND':
        return '解密文件不存在，请重试';
      case 'SECURITY':
        return '缺少文件访问权限，请在系统设置中开启「允许管理所有文件」';
      case 'NO_PATH':
        return '文件路径为空，请联系开发者';
      default:
        return '播放失败（$code）${message ?? ""}';
    }
  }

  /// 停止流式解密代理（宿主页面 dispose 时调用）
  Future<void> dispose() async {
    await _proxy?.stop();
    _proxy = null;
  }
}
