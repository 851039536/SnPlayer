import 'package:flutter/material.dart';

/// 操作菜单项
class ActionSheetItem {
  final IconData icon;
  final String label;
  final Color? color;
  final VoidCallback onTap;

  const ActionSheetItem({
    required this.icon,
    required this.label,
    this.color,
    required this.onTap,
  });
}

/// 底部操作菜单组件
///
/// Material Design 3 风格的底部 ActionSheet
class ActionSheet extends StatelessWidget {
  final String? title;
  final List<ActionSheetItem> items;

  const ActionSheet({
    super.key,
    this.title,
    required this.items,
  });

  /// 显示操作菜单
  static Future<void> show(
    BuildContext context, {
    String? title,
    required List<ActionSheetItem> items,
  }) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => ActionSheet(title: title, items: items),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 拖拽指示条
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 8, bottom: 8),
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: colorScheme.onSurfaceVariant.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // 标题
            if (title != null) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Text(
                  title!,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Divider(height: 1),
            ],

            // 菜单项
            ...items.map((item) => _buildItem(context, item)),

            // 取消按钮
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('取消'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildItem(BuildContext context, ActionSheetItem item) {
    final colorScheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: () {
        Navigator.pop(context);
        item.onTap();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: (item.color ?? colorScheme.primary).withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                item.icon,
                color: item.color ?? colorScheme.primary,
                size: 22,
              ),
            ),
            const SizedBox(width: 16),
            Text(
              item.label,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: item.color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
