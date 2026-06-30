import 'package:flutter/material.dart';

/// 语义化颜色常量（非 ColorScheme 覆盖的固定色值）
class AppColors {
  AppColors._();

  /// 成功绿（解密导出、完成状态）
  static const Color success = Color(0xFF16A34A);

  /// 警告黄（缓存文件）
  static const Color warning = Color(0xFFF59E0B);

  /// 错误红（与 ColorScheme.error 一致，用于直接引用场景）
  static const Color error = Color(0xFFDC2626);

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

/// 统一 ThemeData 配置
///
/// 现代简约风：Indigo 蓝紫主色 + Slate 灰白底 + Light/Dark 双主题
class AppTheme {
  AppTheme._();

  /// 品牌色 seed color — Indigo 蓝紫
  static const Color _seedColor = Color(0xFF4F46E5);

  /// 浅色主题
  static ThemeData get light {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: _seedColor,
      brightness: Brightness.light,
    );

    return ThemeData(
      colorScheme: colorScheme,
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xFFF8FAFC), // slate-50

      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
      ),

      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: colorScheme.outlineVariant.withOpacity(0.5)),
        ),
        margin: EdgeInsets.zero,
      ),

      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
      ),
    );
  }

  /// 深色主题
  static ThemeData get dark {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: _seedColor,
      brightness: Brightness.dark,
    );

    return ThemeData(
      colorScheme: colorScheme,
      useMaterial3: true,

      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
      ),

      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: colorScheme.outlineVariant.withOpacity(0.3)),
        ),
        margin: EdgeInsets.zero,
      ),

      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
      ),
    );
  }
}
