/// 应用圆角 Design Token
///
/// 对齐 Codex UI 规范：使用 sm/base/md/lg/full 五级命名，并保留 xl/xxl
/// 作为扩展以满足弹窗顶部、大卡片等场景。
class AppRadius {
  AppRadius._();

  /// 4px — 标签/徽章（Codex $radius-sm）
  static const double sm = 4.0;

  /// 6px — 控件/输入框（Codex $radius-base）
  static const double base = 6.0;

  /// 8px — 小卡片/区块（Codex $radius-md）
  static const double md = 8.0;

  /// 12px — 标准卡片（Codex $radius-lg）
  static const double lg = 12.0;

  /// 14px — 大卡片/容器扩展
  static const double xl = 14.0;

  /// 20px — 弹窗/Sheet 顶部圆角扩展
  static const double xxl = 20.0;

  /// 9999px — 胶囊/药丸形状（Codex $radius-full）
  static const double full = 9999.0;
}
