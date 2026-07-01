import 'package:flutter/material.dart';

import '../theme/app_spacing.dart';
import '../theme/app_radius.dart';
import '../theme/app_sizes.dart';

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
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.xxl)),
      ),
      builder: (_) => ActionSheet(title: title, items: items),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // 限制弹窗最大高度为屏幕 80%，超出部分可滚动
    final maxHeight = MediaQuery.of(context).size.height * 0.8;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: AppSpacing.spacing2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 拖拽指示条
              Center(
                child: Container(
                  margin: const EdgeInsets.only(
                    top: AppSpacing.spacing2, bottom: AppSpacing.spacing2),
                  width: 32,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // 标题
              if (title != null) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.spacing6, vertical: AppSpacing.spacing2),
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
              const SizedBox(height: AppSpacing.spacing2),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.spacing4),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        vertical: AppSpacing.spacing3),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.lg),
                      ),
                    ),
                    child: const Text('取消'),
                  ),
                ),
              ),
            ],
          ),
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
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.spacing5, vertical: AppSpacing.spacing3),
        child: Row(
          children: [
            Container(
              width: AppSizes.iconButtonSm,
              height: AppSizes.iconButtonSm,
              decoration: BoxDecoration(
                color: (item.color ?? colorScheme.primary).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Icon(
                item.icon,
                color: item.color ?? colorScheme.primary,
                size: AppSizes.iconSm,
              ),
            ),
            const SizedBox(width: AppSpacing.spacing4),
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
