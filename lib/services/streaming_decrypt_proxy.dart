import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:pointycastle/api.dart';

import '../config/crypto.dart';
import '../utils/crypto_utils.dart';
import 'crypto_service.dart';

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

  late EncryptedFileInfo _fileInfo;
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

  /// 启动代理服务器，返回分配的端口号。
  Future<int> start(String encPath) async {
    _encPath = encPath;

    // 1. 读取加密文件元信息
    _fileInfo = await CryptoService.getEncryptedFileInfo(encPath);
    _iv = _fileInfo.iv;
    _key = _fileInfo.key;
    _decryptedSize = _fileInfo.decryptedSize;

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
    _worker = await Isolate.spawn(_decryptWorkerEntry, workerReceivePort.sendPort);
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

    // 停止解密 worker Isolate
    // 注：kill(immediate) 会立即终止 Isolate，无需先 send('stop')（消息不会被处理）
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

  /// 解密块大小（512KB）
  ///
  /// 解密在 worker Isolate 中执行，主线程零同步阻塞。
  /// 512KB 平衡了 Isolate 间数据传递开销和系统调用次数。
  static const int _decryptBlockSize = 512 * 1024;

  /// 解密并流式输出指定范围的数据
  ///
  /// **架构**：解密在长驻 worker Isolate 中执行，主线程仅负责 HTTP 响应写入。
  /// 主线程事件循环零同步阻塞，播放器的并发 Range 请求（视频轨+音频轨+seek）
  /// 可即时响应，从根本上消除卡顿。
  ///
  /// **流控**：worker 每发 [_ackWindowSize] 块后等主线程 ack（ack 窗口）。
  /// 主线程 flush 完成后才发 ack，worker 才继续解密。
  /// 这天然限制了超前解密量（最多 ~1MB），无需人为节流延迟。
  ///
  /// **取消**：seek 时旧连接断开，主线程发 cancel + ack 唤醒 worker 退出。
  ///
  /// **缓存**：主线程侧 LRU 块缓存，命中时直接返回不经过 worker。
  /// worker 回传的整块数据也更新缓存。
  /// 解密并流式输出指定范围的数据
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

    response.bufferOutput = false;

    // 阶段 1：处理连续的缓存命中块（主线程直接返回，不经过 worker）
    while (remaining > 0 && !_stopped) {
      final blockIndex = currentPos ~/ _decryptBlockSize;
      final blockOffset = currentPos % _decryptBlockSize;
      final cachedBlock = _blockCache.get(blockIndex);

      if (cachedBlock == null) {
        break;
      }

      final chunkLen = remaining < _decryptBlockSize ? remaining : _decryptBlockSize;
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

// ═══════════════════════════════════════════════════════════
// 解密 Worker Isolate（长驻）
// ═══════════════════════════════════════════════════════════
//
// 解密在独立 Isolate 执行，主线程事件循环零同步阻塞。
// 主线程通过 SendPort 发送命令，worker 通过 replyPort 回传解密数据块。
//
// 命令：
// - 'init': 初始化 key/iv/encPath（只调一次）
// - 'decrypt_range': 解密指定范围，连续回传数据块
// - 'cancel': 取消当前解密任务（seek 时调用）
// - 'stop': 关闭 worker
//
// 流控：worker 每发 [ackWindowSize] 块后等主线程 ack，
// 防止超前解密导致内存积压。主线程 flush 完成后才发 ack。
//
// 并发：worker 的 async 事件循环可交替处理多个 decrypt_range 请求
// （视频轨+音频轨），各请求有独立的 replyPort 和 ackReceivePort。

/// worker 入口函数（顶层函数，Isolate.spawn 要求）
void _decryptWorkerEntry(SendPort mainPort) {
  final receivePort = ReceivePort();
  mainPort.send(receivePort.sendPort);

  Uint8List? key;
  Uint8List? iv;
  String? encPath;

  // 用 Set 跟踪被取消的 requestId，支持并发取消（视频轨+音频轨同时 seek）
  // 替代单一 int? cancelledRequestId，避免后发的 cancel 覆盖前一个
  final cancelledRequests = <int>{};

  // 每个活跃请求的 ackReceivePort.sendPort
  // cancel 时通过它发 'cancel-ack' 唤醒卡在 await ack 中的任务，避免死锁
  final requestAckPorts = <int, SendPort>{};

  receivePort.listen((message) async {
    if (message is! Map) {
      return;
    }
    final type = message['type'] as String?;

    if (type == 'init') {
      key = message['key'] as Uint8List;
      iv = message['iv'] as Uint8List;
      encPath = message['encPath'] as String;
      return;
    }

    if (type == 'cancel') {
      final rid = message['requestId'] as int;
      cancelledRequests.add(rid);
      // 唤醒可能卡在 await ackReceivePort.first 中的任务
      requestAckPorts[rid]?.send('cancel-ack');
      return;
    }

    if (type == 'stop') {
      receivePort.close();
      return;
    }

    if (type == 'decrypt_range') {
      if (key == null || iv == null || encPath == null) {
        final replyPort = message['replyPort'] as SendPort;
        replyPort.send({'type': 'error', 'message': 'worker not initialized'});
        return;
      }

      final requestId = message['requestId'] as int;
      final replyPort = message['replyPort'] as SendPort;
      try {
        await _decryptRangeInWorker(
          message['rangeStart'] as int,
          message['contentLength'] as int,
          replyPort,
          key!,
          iv!,
          encPath!,
          () => cancelledRequests.contains(requestId),
          requestId,
          requestAckPorts,
        );
      } catch (e) {
        replyPort.send({'type': 'error', 'message': e.toString()});
      } finally {
        // 清理：移除 ackPort 和取消标记，避免 Set/Map 无限增长
        requestAckPorts.remove(requestId);
        cancelledRequests.remove(requestId);
      }
    }
  });
}

/// worker 内部：解密指定范围并流式回传
///
/// 使用 ack 窗口流控（[ackWindowSize] 块等一次 ack），
/// 检查 [isCancelled] 以支持 seek 时取消旧任务。
/// cipher 复用：连续块位置无需重建 CTR cipher。
Future<void> _decryptRangeInWorker(
  int rangeStart,
  int contentLength,
  SendPort replyPort,
  Uint8List key,
  Uint8List iv,
  String encPath,
  bool Function() isCancelled,
  int requestId,
  Map<int, SendPort> requestAckPorts,
) async {
  const blockSize = 512 * 1024;
  const ackWindowSize = 4; // 每发 4 块等一次 ack，最多积压 ~2MB，减少 seek 后等待次数

  final ackReceivePort = ReceivePort();
  bool ackPortSent = false;

  // 注册 ackPort，供 cancel 回调唤醒卡在 await ack 的任务
  requestAckPorts[requestId] = ackReceivePort.sendPort;

  // 用 StreamIterator 替代 ackReceivePort.first：
  // ReceivePort 是 single-subscription stream，first 内部 listen+cancel 会关闭端口，
  // 第二次 first 再 listen 会抛 "Stream has already been listened to"。
  // StreamIterator 保持单个持久订阅，moveNext() 等待下一个事件，可多次调用。
  final ackIterator = StreamIterator(ackReceivePort);

  final encFile = await File(encPath).open(mode: FileMode.read);

  try {
    int currentPos = rangeStart;
    int remaining = contentLength;

    StreamCipher? cipher;
    int cipherPos = -1;
    int lastFilePos = -1;

    final buf = Uint8List(blockSize);
    final procBuf = Uint8List(blockSize);

    int sentSinceLastAck = 0;
    // 首块用小尺寸（64KB）快速返回，让播放器尽快开始解码（seek 后首字节延迟从
    // ~100ms 降至 ~15ms）。后续块恢复 blockSize（512KB）提升吞吐。
    bool isFirstChunk = true;
    const firstChunkSize = 64 * 1024;

    while (remaining > 0) {
      if (isCancelled()) {
        replyPort.send({'type': 'cancelled'});
        return;
      }

      // 首块小尺寸快速返回，后续块恢复 blockSize
      final currentChunkLimit = isFirstChunk ? firstChunkSize : blockSize;
      final chunkLen = remaining < currentChunkLimit ? remaining : currentChunkLimit;

      final alignedStart = (currentPos ~/ aesBlockSize) * aesBlockSize;
      final skipBytes = currentPos - alignedStart;

      // cipher 复用：连续块位置无需重建
      if (cipher == null || cipherPos != alignedStart) {
        final counterOffset = alignedStart ~/ aesBlockSize;
        final adjustedIv = CryptoUtils.incrementCounter(iv, counterOffset);
        cipher = CryptoUtils.createCtrCipher(key, adjustedIv);
      }

      final cipherFileOffset = headerSize + alignedStart;
      if (cipherFileOffset != lastFilePos) {
        await encFile.setPosition(cipherFileOffset);
      }

      final totalDecryptLen = skipBytes + chunkLen;
      final readLen = totalDecryptLen < blockSize ? totalDecryptLen : blockSize;
      final bytesRead = await encFile.readInto(buf, 0, readLen);

      if (bytesRead <= 0) {
        break;
      }

      cipher.processBytes(buf, 0, bytesRead, procBuf, 0);
      cipherPos = alignedStart + bytesRead;
      lastFilePos = cipherFileOffset + bytesRead;

      final outputStart = skipBytes;
      // 首块小尺寸时，只截取 chunkLen 长度（可能 < bytesRead）
      final outputEnd = isFirstChunk ? (skipBytes + chunkLen) : bytesRead;
      final outputLen = outputEnd - outputStart;

      if (outputLen > 0) {
        final outputData =
            Uint8List.fromList(procBuf.sublist(outputStart, outputEnd));
        final blockIndex = alignedStart ~/ blockSize;
        // 仅当 alignedStart 是 blockSize 对齐时才缓存整块。
        // 否则 blockIndex 与实际数据范围不对应（如 alignedStart=96 缓存到 blockIndex=0，
        // 但数据是明文 96-524384 而非块 0 的 0-524287），seek 回退时返回错位数据 →
        // ExoPlayer Invalid NAL length。
        final isFullBlock = skipBytes == 0 &&
            bytesRead >= blockSize &&
            alignedStart % blockSize == 0;

        final blockMsg = <String, dynamic>{
          'type': 'block',
          'data': outputData,
          'blockIndex': blockIndex,
          'isFullBlock': isFullBlock,
        };

        // 第一块附带 ackPort，主线程缓存后复用
        if (!ackPortSent) {
          blockMsg['ackPort'] = ackReceivePort.sendPort;
          ackPortSent = true;
        }

        replyPort.send(blockMsg);
        sentSinceLastAck++;

        // 窗口流控：每 ackWindowSize 块等一次 ack
        if (sentSinceLastAck >= ackWindowSize) {
          await ackIterator.moveNext();
          sentSinceLastAck = 0;
        }
      }

      remaining -= outputLen;
      currentPos += outputLen;
      isFirstChunk = false;
    }

    replyPort.send({'type': 'done'});
  } finally {
    await encFile.close();
    await ackIterator.cancel();
    ackReceivePort.close();
  }
}
