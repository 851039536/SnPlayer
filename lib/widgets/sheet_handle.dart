// lib/widgets/sheet_handle.dart — 底部弹窗拖拽指示条（统一尺寸与间距）

import 'package:flutter/material.dart';

import '../theme/app_spacing.dart';

/// 底部弹窗顶部的拖拽指示条
///
/// 原先在 folder_manage_screen / action_sheet / video_detail_sheet 三处
/// 各自硬编码 `width: 32, height: 4` 与不同的上下 margin，导致同类弹窗
/// 的视觉节奏不一致。此处收敛为单一实现。
class SheetHandle extends StatelessWidget {
  /// 指示条宽度
  static const double width = 32.0;

  /// 指示条高度
  static const double height = 4.0;

  /// 顶部间距（默认对齐 AppSpacing.sheetTop）
  final double topPadding;

  /// 底部间距
  final double bottomPadding;

  const SheetHandle({
    super.key,
    this.topPadding = AppSpacing.sheetTop,
    this.bottomPadding = AppSpacing.spacing4,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: EdgeInsets.only(top: topPadding, bottom: bottomPadding),
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Theme.of(context)
              .colorScheme
              .onSurfaceVariant
              .withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(height / 2),
        ),
      ),
    );
  }
}
