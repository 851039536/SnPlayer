// lib/services/permission_service.dart — 存储权限请求（MANAGE_EXTERNAL_STORAGE → storage → videos 三级回退）

import 'package:permission_handler/permission_handler.dart';

/// 权限请求服务
///
/// 处理 Android 存储权限的检测与请求
/// - API < 30：请求 WRITE_EXTERNAL_STORAGE
/// - API >= 30：请求 MANAGE_EXTERNAL_STORAGE，引导用户跳转设置页
class PermissionService {
  /// 请求存储权限
  ///
  /// 返回 true 表示权限已获取，false 表示被拒绝
  static Future<bool> requestStoragePermission() async {
    // 尝试请求 manage_external_storage
    var manageStatus = await Permission.manageExternalStorage.status;
    if (manageStatus.isGranted) {
      return true;
    }

    if (manageStatus.isPermanentlyDenied) {
      // 已被永久拒绝，引导用户去设置
      await openAppSettings();
      return false;
    }

    manageStatus = await Permission.manageExternalStorage.request();
    if (manageStatus.isGranted) {
      return true;
    }

    // 如果 manage external storage 不可用，回退到传统存储权限
    var storageStatus = await Permission.storage.status;
    if (storageStatus.isGranted) {
      return true;
    }

    storageStatus = await Permission.storage.request();
    if (storageStatus.isGranted) {
      return true;
    }

    // 尝试视频权限（Android 13+）
    var videoStatus = await Permission.videos.status;
    if (videoStatus.isGranted) {
      return true;
    }

    videoStatus = await Permission.videos.request();
    return videoStatus.isGranted;
  }
}
