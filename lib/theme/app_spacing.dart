/// 应用间距 Design Token
///
/// 对应 Codex UI 规范的数字后缀命名（spacing1~spacing8），覆盖所有 UI 间距场景。
/// 禁止在组件中直接书写像素值，所有内/外边距均应引用此处常量。
class AppSpacing {
  AppSpacing._();

  /// 4px — 图标紧贴、超紧凑间距
  static const double spacing1 = 4.0;

  /// 6px — 紧凑间距（图标与文字之间）
  static const double spacing2 = 6.0;

  /// 8px — 默认小块间距（卡片内元素、列表分隔）
  static const double spacing3 = 8.0;

  /// 12px — 网格/卡片内边距
  static const double spacing4 = 12.0;

  /// 16px — 标准段落间距
  static const double spacing5 = 16.0;

  /// 20px — 大块间距
  static const double spacing6 = 20.0;

  /// 24px — 区域间距
  static const double spacing7 = 24.0;

  /// 32px — 页面级间距
  static const double spacing8 = 32.0;
}
