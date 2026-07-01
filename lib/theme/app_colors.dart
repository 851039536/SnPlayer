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

  /// 页面/卡片背景色（B3 --b3-theme-background）
  static const Color background = Color(0xFFF8FAFC);

  /// 区块/表面背景色（B3 --b3-theme-surface）
  static const Color surface = Color(0xFFFFFFFF);

  /// 更浅的悬浮表面色（B3 --b3-theme-surface-lighter）
  static const Color surfaceLighter = Color(0xFFF1F5F9);

  /// 背景上的主文本色（B3 --b3-theme-on-background）
  static const Color onBackground = Color(0xFF0F172A);

  /// 表面上的主文本色（B3 --b3-theme-on-surface）
  static const Color onSurface = Color(0xFF1E293B);

  /// 表面上的三级/提示文本色（B3 --b3-theme-on-surface-light）
  static const Color onSurfaceLight = Color(0xFF64748B);

  /// 主色最浅的聚焦环/高亮色（B3 --b3-theme-primary-lightest）
  static const Color brandLightest = Color(0xFFE0E7FF);

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
}
