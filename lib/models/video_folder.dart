/// 视频文件夹数据模型
class VideoFolder {
  /// 物理目录名（folder_yyyyMMddHHmmss_guid）
  final String name;

  /// 显示名称
  String displayName;

  /// 文件夹颜色（十六进制颜色值，如 #9c27b0）
  String color;

  VideoFolder({
    required this.name,
    required this.displayName,
    required this.color,
  });

  /// 从 JSON Map 创建
  factory VideoFolder.fromJson(Map<String, dynamic> json) {
    return VideoFolder(
      name: json['Name'] as String,
      displayName: json['DisplayName'] as String? ?? '',
      color: json['Color'] as String? ?? '#6750A4',
    );
  }

  /// 转换为 JSON Map
  Map<String, dynamic> toJson() {
    return {
      'Name': name,
      'DisplayName': displayName,
      'Color': color,
    };
  }
}
