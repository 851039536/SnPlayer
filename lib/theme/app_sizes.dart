/// 尺寸 Design Token
///
/// 用于图标、按钮、容器等固定尺寸场景，避免在组件中直接书写像素值。
/// 注意：本文件与 AppSpacing/AppRadius 互补，只定义独立的尺寸常量。
class AppSizes {
  AppSizes._();

  /// 12px — 微型图标（如状态徽标内图标）
  static const double iconXxs = 12.0;

  /// 16px — 图标按钮内图标（Codex R6 标准）
  static const double iconXs = 16.0;

  /// 20px — 小图标/卡片内图标
  static const double iconSm = 20.0;

  /// 22px — 列表/弹窗内图标
  static const double iconMd = 22.0;

  /// 24px — 标准图标
  static const double iconLg = 24.0;

  /// 28px — 播放器内大图标
  static const double iconXl = 28.0;

  /// 40px — 占位图标/大状态图标
  static const double iconXxl = 40.0;

  /// 28px — 紧凑图标按钮容器（弹窗菜单项图标底板）
  static const double iconButtonXs = 28.0;

  /// 36px — 小图标按钮容器
  static const double iconButtonSm = 36.0;

  /// 44px — 标准图标按钮容器/播放器主按钮
  static const double iconButtonMd = 44.0;

  /// 32px — 颜色选择色块
  static const double colorSwatch = 32.0;

  /// 48px — 空状态/错误状态大图标
  static const double emptyStateIcon = 48.0;

  /// 64px — 空列表大图标
  static const double emptyListIcon = 64.0;

  // ── 视频网格布局 ──

  /// 视频网格列数
  ///
  /// 单一来源：滚动估算与 SliverGrid 必须共用，否则可见区计算会与
  /// 实际布局错位导致缩略图加载到错误的视频。
  static const int gridCrossAxisCount = 2;

  /// 视频卡片宽高比（< 1 表示竖向长卡片）
  ///
  /// 缩略图固定 16:9，信息区需容纳 3 行（标题/大小/文件夹标签）。
  /// 正方形(1.0)时信息区仅剩约 44% 高度，在窄屏临界溢出；
  /// 0.8 让缩略图约占 45%、信息区约占 55%，排版更从容。
  static const double videoCardAspectRatio = 0.8;

  /// 卡片缩略图宽高比（16:9）
  static const double videoThumbnailAspectRatio = 16 / 9;
}
