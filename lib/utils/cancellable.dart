/// 可取消操作令牌
///
/// 用于取消正在进行的加密/解密/缩略图加载等耗时操作
class CancellationToken {
  bool _isCancelled = false;
  final List<void Function()> _onCancelCallbacks = [];

  /// 是否已取消
  bool get isCancelled => _isCancelled;

  /// 取消操作
  void cancel() {
    _isCancelled = true;
    for (final callback in _onCancelCallbacks) {
      callback();
    }
  }

  /// 注册取消回调
  void onCancel(void Function() callback) {
    _onCancelCallbacks.add(callback);
  }

  /// 重置令牌
  void reset() {
    _isCancelled = false;
    _onCancelCallbacks.clear();
  }

  /// 抛出异常如果已取消
  void throwIfCancelled() {
    if (_isCancelled) {
      throw CancelledException();
    }
  }
}

/// 取消异常
class CancelledException implements Exception {
  @override
  String toString() => 'Operation was cancelled';
}
