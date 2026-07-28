// lib/widgets/crypto_progress_dialog.dart — 加解密模态进度对话框（批量文件计数 + 百分比进度条）

import 'package:flutter/material.dart';

import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';

/// 加解密进度控制器
///
/// 持有当前操作的标签/文件名/批量计数/进度值，供 [CryptoProgressDialog] 监听。
/// 进度更新按整数百分比节流：只有百分比整数位变化才 notifyListeners，
/// 避免 Isolate 高频进度回调导致对话框每帧重建。
class CryptoProgressController extends ChangeNotifier {
  String _label;
  String _fileName;
  int _current;
  int _total;
  double? _progress;

  CryptoProgressController({
    required String label,
    String fileName = '',
    int current = 0,
    int total = 0,
    double? progress,
  })  : _label = label,
        _fileName = fileName,
        _current = current,
        _total = total,
        _progress = progress;

  String get label => _label;
  String get fileName => _fileName;

  /// 批量场景的当前序号（1 起）；total <= 1 时对话框不显示计数
  int get current => _current;
  int get total => _total;

  /// 0.0 ~ 1.0，null 表示不定进度（转圈样式的线性条）
  double? get progress => _progress;

  /// 切换到下一个文件（批量场景），进度归零
  void nextFile({required String fileName, required int current, required int total}) {
    _fileName = fileName;
    _current = current;
    _total = total;
    _progress = 0.0;
    notifyListeners();
  }

  /// 更新标签（如从"正在解密"切到"正在生成缩略图"），进度转为不定态
  void setLabel(String label, {bool indeterminate = false}) {
    _label = label;
    if (indeterminate) {
      _progress = null;
    }
    notifyListeners();
  }

  /// 更新进度值（整数百分比变化才通知）
  void updateProgress(double value) {
    final oldPercent = _progress == null ? -1 : (_progress! * 100).floor();
    final newPercent = (value * 100).floor();
    _progress = value;
    if (newPercent != oldPercent) {
      notifyListeners();
    }
  }
}

/// 模态进度对话框
///
/// 不可点击遮罩关闭；调用方负责在操作结束后 Navigator.pop 关闭。
/// 用法：
/// ```dart
/// final controller = CryptoProgressController(label: '正在加密');
/// CryptoProgressDialog.show(context, controller); // 不 await
/// try { await doWork(controller); } finally {
///   if (mounted) { Navigator.pop(context); }
///   controller.dispose();
/// }
/// ```
class CryptoProgressDialog extends StatelessWidget {
  final CryptoProgressController controller;

  const CryptoProgressDialog({super.key, required this.controller});

  static void show(BuildContext context, CryptoProgressController controller) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false, // 屏蔽返回键，防止操作中途对话框被关闭导致 pop 栈错乱
        child: CryptoProgressDialog(controller: controller),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.xl)),
      content: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final progress = controller.progress;
          final percentText =
              progress == null ? '' : '${(progress * 100).floor()}%';
          final countText = controller.total > 1
              ? '（${controller.current}/${controller.total}）'
              : '';

          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${controller.label}$countText',
                style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              if (controller.fileName.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.spacing2),
                Text(
                  controller.fileName,
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: AppSpacing.spacing4),
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                child: LinearProgressIndicator(value: progress, minHeight: 6),
              ),
              if (percentText.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.spacing2),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    percentText,
                    style: textTheme.labelMedium?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
