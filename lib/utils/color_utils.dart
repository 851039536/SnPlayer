import 'package:flutter/material.dart';

/// 颜色工具函数
class ColorUtils {
  /// 解析十六进制颜色字符串
  ///
  /// 支持 6 位 (#RRGGBB) 和 8 位 (#AARRGGBB) 格式
  static Color? parseHexColor(String hex) {
    try {
      final colorStr = hex.replaceAll('#', '');
      if (colorStr.length == 6) {
        return Color(int.parse('FF$colorStr', radix: 16));
      } else if (colorStr.length == 8) {
        return Color(int.parse(colorStr, radix: 16));
      }
    } catch (_) {
      // 解析失败返回 null
    }
    return null;
  }
}
