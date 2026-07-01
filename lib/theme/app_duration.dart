/// 动画时长 Design Token
///
/// 对应 Codex UI 规范中"所有交互过渡统一使用 0.12s"的要求。
/// 进度条填充等需要更平滑视觉反馈的场景可例外使用 slow。
class AppDuration {
  AppDuration._();

  /// 标准交互过渡时长 — 120ms（Codex 0.12s）
  static const Duration standard = Duration(milliseconds: 120);

  /// 较慢/特殊动画时长 — 300ms
  ///
  /// 用于进度条填充、需要更平滑视觉反馈的场景。
  static const Duration slow = Duration(milliseconds: 300);
}
