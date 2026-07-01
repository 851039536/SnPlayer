/// 字体大小 Design Token
///
/// 对应 Codex UI 规范中的 $font-size-* 体系，所有字体大小必须使用本文件
/// 定义的常量，禁止在组件中硬编码 fontSize 数值。
class AppFontSize {
  AppFontSize._();

  /// 12px — 元信息、提示、标签
  static const double xs = 12.0;

  /// 14px — 次级文本
  static const double sm = 14.0;

  /// 16px — 正文/标题
  static const double base = 16.0;

  /// 18px — 大标题（较少使用）
  static const double lg = 18.0;
}
