// lib/services/streaming_decrypt_proxy.dart — 本地 HTTP 流式解密代理（Range 按需解密 + 内存 LRU 块缓存）

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../config/crypto.dart';
import 'crypto_service.dart';
import 'streaming_decrypt_worker.dart';

/// 本地 HTTP 代理服务器，实现按需流式解密播放。
///
/// 利用 AES-256-CTR 的随机访问特性和原生播放器的 HTTP Range 请求支持，
/// 替代传统的"全量解密→文件播放"模式，实现秒级起播。
///
/// 工作原理：
/// 1. 读取 .enc 文件头获取 IV/Salt，派生密钥
/// 2. 启动 HttpServer 监听 127.0.0.1:{随机端口}
/// 3. 播放器发送 Range 请求 → 代理计算密文偏移 + 调整 IV
/// 4. 仅解密请求区间的数据，512KB 块流式返回
/// 5. 内存 LRU 块缓存加速 seek 回退和重复请求
///
/// 并发安全：每个请求独立打开加密文件句柄。
class StreamingDecryptProxy {
  HttpServer? _server;

  late Uint8List _iv;
  late Uint8List _key;
  late int _decryptedSize;
  late String _encPath;
  late String _contentType;

  int? _port;
  bool _stopped = false;

  /// 长驻解密 worker Isolate
  ///
  /// 解密在独立 Isolate 执行，主线程事件循环零同步阻塞，
  /// 播放器的并发 Range 请求（视频轨+音频轨+seek）可即时响应。
  Isolate? _worker;
  SendPort? _workerSendPort;

  /// 内存块缓存（LRU），key 为块索引
  final _BlockCache _blockCache = _BlockCache();

  /// 递增的请求 ID，用于 worker 精确取消单个 decrypt_range 请求
  ///
  /// 解决并发 Range 请求（视频轨+音频轨）时全局 cancelled 标志互相干扰的问题：
  /// 每个 decrypt_range 分配唯一 ID，cancel 携带目标 ID，worker 仅取消匹配请求。
  int _nextRequestId = 0;

  /// 活跃请求的 replyPort 集合
  ///
  /// stop() 时逐个 close：worker 被 kill 后不再回消息，
  /// 卡在 `await for (replyPort)` 的请求 Future 会永久挂起并泄漏端口。
  final Set<ReceivePort> _activeReplyPorts = {};

  /// 启动代理服务器，返回分配的端口号。
  Future<int> start(String encPath) async {
    _encPath = encPath;

    // 1. 读取加密文件元信息
    final fileInfo = await CryptoService.getEncryptedFileInfo(encPath);
    _iv = fileInfo.iv;
    _key = fileInfo.key;
    _decryptedSize = fileInfo.decryptedSize;

    // 2. 推断 Content-Type（根据原始文件名扩展名）
    _contentType = _guessContentType(encPath);

    // 3. 启动 HTTP 服务器
    _server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0, // 系统分配端口
    );
    _server!.autoCompress = false; // 本地回环不需要压缩，减少 CPU 开销
    _port = _server!.port;

    debugPrint('[SnPlayer] StreamingDecryptProxy: 启动于 '
        'http://127.0.0.1:$_port, 解密大小=${_decryptedSize}B '
        '(${(_decryptedSize / 1024 / 1024).toStringAsFixed(1)}MB), '
        'Content-Type=$_contentType');

    // 4. spawn 长驻解密 worker Isolate
    final workerReceivePort = ReceivePort();
    _worker = await Isolate.spawn(decryptWorkerEntry, workerReceivePort.sendPort);
    _workerSendPort = await workerReceivePort.first as SendPort;

    // 初始化 worker（传递 key/iv/encPath，只传一次）
    _workerSendPort!.send({
      'type': 'init',
      'key': _key,
      'iv': _iv,
      'encPath': _encPath,
    });

    debugPrint('[SnPlayer] StreamingDecryptProxy: 解密 worker Isolate 已启动');

    // 5. 开始监听请求
    _serveRequests();

    return _port!;
  }

  /// 根据加密文件名推断 MIME 类型
  ///
  /// 加密文件名格式：原始名称_yyyyMMdd.enc
  /// 从原始名称的扩展名推断视频格式。
  String _guessContentType(String encPath) {
    // 去掉 .enc 后缀，再取原始扩展名
    final baseName = p.basenameWithoutExtension(encPath);
    // 去掉日期后缀 _yyyyMMdd
    final originalName = baseName.replaceFirst(RegExp(r'_\d{8}$'), '');
    final ext = p.extension(originalName).toLowerCase();

    const mimeMap = {
      '.mp4': 'video/mp4',
      '.m4v': 'video/x-m4v',
      '.mkv': 'video/x-matroska',
      '.avi': 'video/x-msvideo',
      '.mov': 'video/quicktime',
      '.flv': 'video/x-flv',
      '.wmv': 'video/x-ms-wmv',
      '.webm': 'video/webm',
      '.3gp': 'video/3gpp',
      '.ts': 'video/mp2t',
    };

    return mimeMap[ext] ?? 'application/octet-stream';
  }

  /// 获取代理 URL（供 VideoPlayerController.networkUrl 使用）
  String get proxyUrl => 'http://127.0.0.1:$_port$streamingProxyPath';

  /// 停止代理，释放所有资源
  Future<void> stop() async {
    if (_stopped) {
      return;
    }
    _stopped = true;

    debugPrint('[SnPlayer] StreamingDecryptProxy: 停止中...');

    await _server?.close(force: true);
    _server = null;

    // 关闭活跃请求的 replyPort：worker 被 kill 后不再回消息，
    // 不关闭会让 _decryptAndStream 的 await for 永久挂起
    for (final port in _activeReplyPorts.toList()) {
      port.close();
    }
    _activeReplyPorts.clear();

    // 停止解密 worker Isolate
    // 注：kill(immediate) 会立即终止 Isolate，无需先发消息（消息不会被处理）
    _worker?.kill(priority: Isolate.immediate);
    _worker = null;
    _workerSendPort = null;

    _blockCache.clear();

    debugPrint('[SnPlayer] StreamingDecryptProxy: 已停止');
  }

  // ═══════════════════════════════════════════════════════════
  // 请求处理
  // ═══════════════════════════════════════════════════════════

  void _serveRequests() {
    _server!.listen((request) {
      _handleRequest(request).catchError((e) {
        debugPrint('[SnPlayer] StreamingDecryptProxy: 请求处理异常: $e');
        try {
          request.response.statusCode = HttpStatus.internalServerError;
          request.response.close();
        } catch (_) {}
      });
    });
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (_stopped) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }

    if (request.uri.path != streamingProxyPath) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    // 处理 HEAD 请求（播放器探测）
    if (request.method == 'HEAD') {
      _writeCommonHeaders(request.response);
      request.response.headers.contentLength = _decryptedSize;
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
      return;
    }

    if (request.method != 'GET') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }

    // 解析 Range 请求
    final rangeHeader = request.headers.value('range');
    int rangeStart = 0;
    int rangeEnd = _decryptedSize - 1;
    bool hasValidRange = false;

    if (rangeHeader != null) {
      final parsed = _parseRange(rangeHeader, _decryptedSize);
      if (parsed != null) {
        rangeStart = parsed.start;
        rangeEnd = parsed.end;
        hasValidRange = true;
      }
    }

    final contentLength = rangeEnd - rangeStart + 1;
    final isPartial = hasValidRange;

    _writeCommonHeaders(request.response);
    request.response.headers.contentLength = contentLength;

    if (isPartial) {
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $rangeStart-$rangeEnd/$_decryptedSize',
      );
    } else {
      request.response.statusCode = HttpStatus.ok;
    }

    // 立即刷新模式：每块数据写入后直接发送，不等待缓冲区满
    // 确保 seek 远距离时数据快速到达播放器解码器
    request.response.bufferOutput = false;

    try {
      final fullyWritten = await _decryptAndStream(
        request.response,
        rangeStart,
        contentLength,
      );
      if (fullyWritten) {
        await request.response.close();
      } else {
        // 提前终止（seek/取消/连接断开）：contentLength 头已发送但实际写入不足，
        // close() 会抛 HttpException。用 detachSocket + destroy 重置 TCP 连接，
        // 让播放器明确收到连接中断信号并发起新 Range 请求。
        try {
          final socket = await request.response.detachSocket();
          socket.destroy();
        } catch (_) {
          try {
            await request.response.close();
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('[SnPlayer] StreamingDecryptProxy: 请求处理异常: $e');
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  /// 写入公共响应头
  void _writeCommonHeaders(HttpResponse response) {
    response.headers.set(HttpHeaders.contentTypeHeader, _contentType);
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    response.headers.set(HttpHeaders.connectionHeader, 'keep-alive');
    response.headers.set('X-SnPlayer', 'streaming-decrypt-proxy');
  }

  /// 解析 HTTP Range 头
  _Range? _parseRange(String rangeHeader, int totalSize) {
    final parts = rangeHeader.split('=');
    if (parts.length != 2 || parts[0].trim() != 'bytes') {
      return null;
    }

    final rangeStr = parts[1].trim();
    final dashIndex = rangeStr.indexOf('-');
    if (dashIndex < 0) {
      return null;
    }

    final startStr = rangeStr.substring(0, dashIndex).trim();
    final endStr = rangeStr.substring(dashIndex + 1).trim();

    int start;
    int end;

    if (startStr.isEmpty) {
      final suffixLen = int.tryParse(endStr);
      if (suffixLen == null) {
        return null;
      }
      start = totalSize - suffixLen;
      if (start < 0) {
        start = 0;
      }
      end = totalSize - 1;
    } else {
      start = int.tryParse(startStr) ?? -1;
      if (start < 0 || start >= totalSize) {
        return null;
      }
      if (endStr.isEmpty) {
        end = totalSize - 1;
      } else {
        end = int.tryParse(endStr) ?? -1;
        if (end < start) {
          return null;
        }
        if (end >= totalSize) {
          end = totalSize - 1;
        }
      }
    }

    return _Range(start, end);
  }

  /// 解密并流式输出指定范围的数据
  ///
  /// 解密在长驻 worker Isolate 中执行（streaming_decrypt_worker.dart），
  /// 主线程仅负责 HTTP 响应写入；LRU 块缓存命中时不经过 worker；
  /// ack 窗口流控限制超前解密量；seek 时旧连接断开，发 cancel + ack 唤醒 worker 退出。
  ///
  /// 返回 true 表示完整写入了 contentLength 字节；
  /// 返回 false 表示提前终止（seek/取消/连接断开/worker 错误）。
  Future<bool> _decryptAndStream(
    HttpResponse response,
    int rangeStart,
    int contentLength,
  ) async {
    int remaining = contentLength;
    int currentPos = rangeStart;

    // 阶段 1：处理连续的缓存命中块（主线程直接返回，不经过 worker）
    while (remaining > 0 && !_stopped) {
      final blockIndex = currentPos ~/ streamingDecryptBlockSize;
      final blockOffset = currentPos % streamingDecryptBlockSize;
      final cachedBlock = _blockCache.get(blockIndex);

      if (cachedBlock == null) {
        break;
      }

      final chunkLen = remaining < streamingDecryptBlockSize
          ? remaining
          : streamingDecryptBlockSize;
      final srcEnd = blockOffset + chunkLen;
      final actualEnd = srcEnd > cachedBlock.length ? cachedBlock.length : srcEnd;
      final actualCopyLen = actualEnd - blockOffset;

      if (actualCopyLen <= 0) {
        break;
      }

      try {
        response.add(cachedBlock.sublist(blockOffset, actualEnd));
        await response.flush();
      } catch (e) {
        // 连接已断开（seek/stop），提前终止
        return false;
      }
      remaining -= actualCopyLen;
      currentPos += actualCopyLen;
    }

    if (remaining <= 0) {
      return true;
    }
    if (_stopped) {
      return false;
    }

    // 阶段 2：缓存未命中部分交给 worker Isolate 解密
    if (_workerSendPort == null) {
      debugPrint('[SnPlayer] StreamingDecryptProxy: worker 不可用，跳过');
      return false;
    }

    final replyPort = ReceivePort();
    _activeReplyPorts.add(replyPort);
    SendPort? ackPort;

    // 分配唯一 requestId，用于精确取消此请求（不影响并发的其他 decrypt_range）
    final requestId = _nextRequestId++;

    _workerSendPort!.send({
      'type': 'decrypt_range',
      'requestId': requestId,
      'rangeStart': currentPos,
      'contentLength': remaining,
      'replyPort': replyPort.sendPort,
    });

    try {
      await for (final event in replyPort) {
        if (_stopped) {
          _workerSendPort?.send({'type': 'cancel', 'requestId': requestId});
          ackPort?.send('ack');
          return false;
        }

        if (event is! Map) {
          continue;
        }
        final type = event['type'] as String?;

        if (type == 'block') {
          final data = event['data'] as Uint8List;

          // 缓存 ackPort（第一块附带）
          if (event['ackPort'] != null) {
            ackPort = event['ackPort'] as SendPort;
          }

          // 更新内存块缓存（仅整块）
          if (event['isFullBlock'] == true) {
            final blockIndex = event['blockIndex'] as int;
            _blockCache.put(blockIndex, data);
          }

          try {
            response.add(data);
            await response.flush();
          } catch (e) {
            // 连接已断开（播放器 seek/stop），取消此 requestId 对应的 worker 任务
            _workerSendPort?.send({'type': 'cancel', 'requestId': requestId});
            ackPort?.send('ack'); // 唤醒可能在等 ack 的 worker
            return false;
          }

          // 发 ack，让 worker 继续下一块
          ackPort?.send('ack');
        } else if (type == 'done') {
          return true;
        } else if (type == 'cancelled') {
          return false;
        } else if (type == 'error') {
          debugPrint('[SnPlayer] StreamingDecryptProxy: worker 错误: ${event['message']}');
          return false;
        }
      }
    } finally {
      _activeReplyPorts.remove(replyPort);
      replyPort.close();
    }

    return false;
  }
}

// ═══════════════════════════════════════════════════════════
// 内存块缓存（LRU）
// ═══════════════════════════════════════════════════════════

class _BlockCache {
  final Map<int, Uint8List> _cache = {};

  Uint8List? get(int blockIndex) {
    final data = _cache.remove(blockIndex);
    if (data != null) {
      _cache[blockIndex] = data; // 重新插入到末尾（LRU）
    }
    return data;
  }

  void put(int blockIndex, Uint8List data) {
    if (_cache.length >= streamingMaxCacheBlocks) {
      _cache.remove(_cache.keys.first); // 淘汰最久未访问
    }
    _cache[blockIndex] = data;
  }

  void clear() {
    _cache.clear();
  }
}

/// HTTP Range 解析结果
class _Range {
  final int start;
  final int end;
  const _Range(this.start, this.end);
}
