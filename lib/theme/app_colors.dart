import 'package:flutter/material.dart';

/// 语义化颜色 Token
///
/// 对应 Codex UI 规范中的 B3 主题变量体系，提供统一的品牌色、状态色和
/// 背景/表面层级色。所有组件颜色引用均应先使用本文件定义。
class AppColors {
  AppColors._();

  /// 品牌主色 — Indigo 蓝紫
  static const Color brand = Color(0xFF4F46E5);

  /// 成功绿（解密导出、完成状态）
  static const Color success = Color(0xFF16A34A);

  /// 警告黄（缓存文件）
  static const Color warning = Color(0xFFF59E0B);

  /// 错误红（与 ColorScheme.error 一致，用于直接引用场景）
  static const Color error = Color(0xFFDC2626);

  /// 页面背景色（仅浅色主题使用）
  ///
  /// 深色主题的背景由 `ColorScheme.fromSeed(brightness: dark)` 提供，
  /// 故此处只保留浅色基准值。表面/文本等层级色一律走 ColorScheme，
  /// 不再维护平行的第二套固定色板（避免深色模式下失效）。
  static const Color background = Color(0xFFF8FAFC);

  /// 文件夹预设颜色列表
  static const List<String> presetFolderColors = [
    '#6750A4', // 紫
    '#FF4D4D', // 红
    '#FF9800', // 橙
    '#FFC107', // 黄
    '#4CAF50', // 绿
    '#2196F3', // 蓝
    '#00BCD4', // 青
    '#E91E63', // 粉
  ];

  // ── 主题感知的语义色 ──
  //
  // 上面的 success/warning 等是固定色值，深色背景下对比度不足。
  // 组件应优先使用下面这组方法，按当前 Brightness 解析出适配的颜色。

  /// 成功色（深色模式下用更亮的绿，保证对比度）
  static Color successOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF4ADE80)
          : success;

  /// 警告色（深色模式下用更亮的琥珀）
  static Color warningOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFFFBBF24)
          : warning;

  /// 品牌色（深色模式下用更亮的靛蓝）
  static Color brandOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF818CF8)
          : brand;

  // ── 播放器专用色 ──
  //
  // 播放页恒为深色背景（黑底视频），不受主题切换影响，
  // 故使用固定色值，但集中在此处以便统一调整。

  /// 播放器底栏遮罩底（渐变最深处）
  static const Color playerScrim = Color(0xD9000000);

  /// 播放器控制图标/文字主色
  static const Color playerOnSurface = Color(0xB3FFFFFF);

  /// 播放器次要文字（如总时长）
  static const Color playerOnSurfaceMuted = Color(0x8AFFFFFF);

  /// 播放器进度条轨道底色
  static const Color playerTrack = Color(0x26FFFFFF);

  /// 播放器已缓冲区间色
  static const Color playerBuffered = Color(0x33FFFFFF);

  /// 播放器按钮圆形底
  static const Color playerButtonFill = Color(0x26FFFFFF);

  /// 播放器弹窗（倍速选择）背景
  static const Color playerSurface = Color(0xFF1E1E2E);

  /// 播放器弹窗内的描边/分隔
  static const Color playerOutline = Color(0x1AFFFFFF);

  /// 播放器弹窗内的次级填充（未选中项底色）
  static const Color playerSurfaceVariant = Color(0x14FFFFFF);
}
