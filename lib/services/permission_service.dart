import 'package:permission_handler/permission_handler.dart';

/// 权限请求服务
///
/// 处理 Android 存储权限的检测与请求
/// - API < 30：请求 WRITE_EXTERNAL_STORAGE
/// - API >= 30：请求 MANAGE_EXTERNAL_STORAGE，引导用户跳转设置页
class PermissionService {
  /// 检查是否拥有存储权限
  static Future<bool> hasStoragePermission() async {
    // Android 13+ (API 33) 使用细粒度媒体权限
    // Android 11-12 (API 30-32) 使用 MANAGE_EXTERNAL_STORAGE
    // Android 10 及以下使用 WRITE_EXTERNAL_STORAGE

    // 先尝试检查 manage external storage
    final manageStatus = await Permission.manageExternalStorage.status;
    if (manageStatus.isGranted) {
      return true;
    }

    // 检查传统存储权限
    final storageStatus = await Permission.storage.status;
    if (storageStatus.isGranted) {
      return true;
    }

    // Android 13+ 使用细粒度权限
    final videoStatus = await Permission.videos.status;
    return videoStatus.isGranted;
  }

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

  /// 请求媒体访问权限（用于从相册选取视频）
  static Future<bool> requestMediaPermission() async {
    var status = await Permission.videos.status;
    if (status.isGranted) {
      return true;
    }
    status = await Permission.videos.request();
    return status.isGranted;
  }
}
