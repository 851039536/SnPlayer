import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_duration.dart';
import '../../theme/app_font_size.dart';
import '../../theme/app_radius.dart';
import '../../theme/app_spacing.dart';

/// 倍速选择底部弹窗
///
/// 显示 6 档播放速度选项（0.5x ~ 2.0x），当前速度高亮。
class SpeedSelector extends StatelessWidget {
  final double currentSpeed;
  final ValueChanged<double> onSpeedSelected;

  static const List<double> _speeds = [
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    2.0,
  ];

  const SpeedSelector({
    super.key,
    required this.currentSpeed,
    required this.onSpeedSelected,
  });

  /// 显示倍速选择器
  static Future<void> show({
    required BuildContext context,
    required double currentSpeed,
    required ValueChanged<double> onSpeedSelected,
  }) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black38,
      builder: (_) => SpeedSelector(
        currentSpeed: currentSpeed,
        onSpeedSelected: onSpeedSelected,
      ),
    );
  }

  String _speedLabel(double speed) {
    if (speed == 1.0) { return '正常'; }
    return '${speed}x';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.spacing6),
      decoration: const BoxDecoration(
        color: AppColors.playerSurface,
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
        border: Border(
          top: BorderSide(
            color: AppColors.playerOutline,
            width: 1,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题
            const Center(
              child: Text(
                '播放速度',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: AppFontSize.base,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.spacing5),
            // 速度网格：3 列等分，用 LayoutBuilder 实测宽度避免魔法数字
            LayoutBuilder(
              builder: (context, constraints) {
                const columns = 3;
                const gap = AppSpacing.spacing4;
                final itemWidth =
                    (constraints.maxWidth - gap * (columns - 1)) / columns;

                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  alignment: WrapAlignment.center,
                  children: _speeds.map((speed) {
                    final isSelected = currentSpeed == speed;
                    return GestureDetector(
                      onTap: () {
                        onSpeedSelected(speed);
                        Navigator.pop(context);
                      },
                      child: AnimatedContainer(
                        duration: AppDuration.standard,
                        width: itemWidth,
                        padding: const EdgeInsets.symmetric(
                            vertical: AppSpacing.spacing4),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? AppColors.brand
                              : AppColors.playerSurfaceVariant,
                          borderRadius: BorderRadius.circular(AppRadius.lg),
                          border: isSelected
                              ? null
                              : Border.all(color: AppColors.playerOutline),
                        ),
                        child: Text(
                          _speedLabel(speed),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: isSelected
                                ? Colors.white
                                : AppColors.playerOnSurface,
                            fontSize: AppFontSize.sm,
                            fontWeight:
                                isSelected ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
            const SizedBox(height: AppSpacing.spacing3),
          ],
        ),
      ),
    );
  }
}
