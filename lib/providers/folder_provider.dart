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

  /// 创建文件夹
  Future<bool> createFolder(String displayName, String color) async {
    final folder = await StorageService.createFolder(displayName, color);
    if (folder != null) {
      _folders.add(folder);
      notifyListeners();
      return true;
    }
    return false;
  }

  /// 重命名文件夹
  Future<bool> renameFolder(String folderName, String newDisplayName) async {
    final index = _folders.indexWhere((f) => f.name == folderName);
    if (index == -1) { return false; }

    _folders[index].displayName = newDisplayName;
    final success = await StorageService.saveFolders(_folders);
    if (success) {
      notifyListeners();
      return true;
    } else {
      // 回滚
      await loadFolders();
      return false;
    }
  }

  /// 修改文件夹颜色
  Future<bool> recolorFolder(String folderName, String newColor) async {
    final index = _folders.indexWhere((f) => f.name == folderName);
    if (index == -1) { return false; }

    _folders[index].color = newColor;
    final success = await StorageService.saveFolders(_folders);
    if (success) {
      notifyListeners();
      return true;
    } else {
      await loadFolders();
      return false;
    }
  }

  /// 删除文件夹
  Future<bool> deleteFolder(String folderName) async {
    // 检查文件夹是否为空
    final success = await StorageService.deleteFolder(folderName);
    if (success) {
      _folders.removeWhere((f) => f.name == folderName);
      if (_selectedFolder == folderName) {
        _selectedFolder = null;
      }
      notifyListeners();
      return true;
    }
    return false;
  }

  /// 获取当前选中的文件夹名称
  String? get currentFolder => _selectedFolder;

  /// 是否在"全部"视图
  bool get isAllSelected => _selectedFolder == null;
}
