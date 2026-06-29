import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 路径管理服务
///
/// 提供统一的目录路径获取和文件路径构建能力
class PathProviderService {
  static String? _downloadDir;
  static String? _cacheDir;

  /// 获取 /sdcard/Download/ 目录路径
  static Future<String> getDownloadDir() async {
    if (_downloadDir != null) {
      return _downloadDir!;
    }
    // Android 上的 Download 目录路径
    _downloadDir = '/storage/emulated/0/Download';
    final dir = Directory(_downloadDir!);
    if (!await dir.exists()) {
      // 回退：使用应用外部存储目录
      final extDir = await getExternalStorageDirectory();
      if (extDir != null) {
        final parentDir = p.dirname(p.dirname(p.dirname(extDir.path)));
        _downloadDir = p.join(parentDir, 'Download');
      }
    }
    return _downloadDir!;
  }

  /// 获取加密视频存储根目录
  static Future<String> getLockVideoDir() async {
    final download = await getDownloadDir();
    return p.join(download, lockVideoDirName);
  }

  /// 获取解密导出目录
  static Future<String> getUnlockVideoDir() async {
    final download = await getDownloadDir();
    return p.join(download, unlockVideoDirName);
  }

  /// 获取应用缓存目录（用于存储临时播放文件）
  static Future<String> getCacheDir() async {
    if (_cacheDir != null) {
      return _cacheDir!;
    }
    final appCache = await getTemporaryDirectory();
    _cacheDir = p.join(appCache.path, playCacheDirName);
    return _cacheDir!;
  }
}
