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

  /// 36px — 小图标按钮容器
  static const double iconButtonSm = 36.0;

  /// 44px — 标准图标按钮容器/播放器主按钮
  static const double iconButtonMd = 44.0;
}
