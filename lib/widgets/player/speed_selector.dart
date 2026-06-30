import 'package:flutter/material.dart';

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
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E2E),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(
          top: BorderSide(
            color: Colors.white.withValues(alpha: 0.1),
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
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 16),
            // 速度网格
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: _speeds.map((speed) {
                final isSelected = currentSpeed == speed;
                return GestureDetector(
                  onTap: () {
                    onSpeedSelected(speed);
                    Navigator.pop(context);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: (MediaQuery.of(context).size.width - 88) / 3,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFF6366F1)
                          : Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: isSelected
                          ? null
                          : Border.all(
                              color: Colors.white.withValues(alpha: 0.1),
                            ),
                    ),
                    child: Text(
                      _speedLabel(speed),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: isSelected ? Colors.white : Colors.white70,
                        fontSize: 15,
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
