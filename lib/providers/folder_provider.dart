// lib/providers/folder_provider.dart — 文件夹状态管理（增删改查/选中筛选，元数据操作委托 StorageService）

import 'package:flutter/material.dart';

import '../models/video_folder.dart';
import '../services/storage_service.dart';

/// 文件夹状态管理
///
/// 管理文件夹列表的 CRUD 操作
/// 提供文件夹筛选功能
class FolderProvider extends ChangeNotifier {
  List<VideoFolder> _folders = [];
  String? _selectedFolder; // null = 全部

  List<VideoFolder> get folders => _folders;
  String? get selectedFolder => _selectedFolder;

  /// 加载文件夹列表
  Future<void> loadFolders() async {
    _folders = await StorageService.loadFolders();
    notifyListeners();
  }

  /// 选中文件夹
  void selectFolder(String? folderName) {
    _selectedFolder = folderName;
    notifyListeners();
  }

  /// 创建文件夹（返回新建的文件夹，失败返回 null）
  Future<VideoFolder?> createFolder(String displayName, String color) async {
    final folder = await StorageService.createFolder(displayName, color);
    if (folder != null) {
      _folders.add(folder);
      notifyListeners();
    }
    return folder;
  }

  /// 重命名文件夹
  Future<bool> renameFolder(String folderName, String newDisplayName) async {
    return _mutateFolders((folders) {
      final index = folders.indexWhere((f) => f.name == folderName);
      if (index == -1) { return null; }
      folders[index].displayName = newDisplayName;
      return folders;
    });
  }

  /// 修改文件夹颜色
  Future<bool> recolorFolder(String folderName, String newColor) async {
    return _mutateFolders((folders) {
      final index = folders.indexWhere((f) => f.name == folderName);
      if (index == -1) { return null; }
      folders[index].color = newColor;
      return folders;
    });
  }

  /// 串行执行一次元数据变更
  ///
  /// 基于磁盘最新内容做修改再落盘，避免与 StorageService 的并发操作互相覆盖。
  /// [mutator] 返回 null 表示目标不存在（不做保存）。
  Future<bool> _mutateFolders(
    List<VideoFolder>? Function(List<VideoFolder> folders) mutator,
  ) async {
    final success = await StorageService.mutateFolders((folders) async {
      final result = mutator(folders);
      if (result == null) { return false; }
      _folders = result;
      return true;
    });
    if (success) {
      notifyListeners();
    } else {
      // 保存失败或目标不存在：以磁盘为准回滚内存状态
      await loadFolders();
    }
    return success;
  }

  /// 删除文件夹（仅空文件夹可删，非空由 StorageService 拒绝）
  Future<DeleteFolderResult> deleteFolder(String folderName) async {
    final result = await StorageService.deleteFolder(folderName);
    if (result == DeleteFolderResult.success) {
      _folders.removeWhere((f) => f.name == folderName);
      if (_selectedFolder == folderName) {
        _selectedFolder = null;
      }
      notifyListeners();
    }
    return result;
  }
}
