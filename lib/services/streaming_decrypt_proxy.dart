import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

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
/// 4. 仅解密请求区间的数据，256KB 块流式返回
/// 5. 同时写入磁盘缓存文件，二次播放直接从缓存加载
class StreamingDecryptProxy {
  HttpServer? _server;
  RandomAccessFile? _encFile;
  RandomAccessFile? _cacheFile;

  late EncryptedFileInfo _fileInfo;
  late Uint8List _iv;
  late Uint8List _key;
  late int _decryptedSize;

  int? _port;
  bool _stopped = false;

  /// 内存块缓存（LRU），key 为块索引
  final _BlockCache _blockCache = _BlockCache();

  /// 启动代理服务器，返回分配的端口号。
  ///
  /// [encPath] 加密文件路径
  /// [cacheFilePath] 磁盘缓存文件路径（预分配，流式写入解密数据）
  Future<int> start(String encPath, String cacheFilePath) async {
    // 1. 读取加密文件元信息
    _fileInfo = await CryptoService.getEncryptedFileInfo(encPath);
    _iv = _fileInfo.iv;
    _key = _fileInfo.key;
    _decryptedSize = _fileInfo.decryptedSize;

    // 2. 打开加密文件句柄
    _encFile = await File(encPath).open(mode: FileMode.read);

    // 3. 预分配并打开磁盘缓存文件
    final cacheParent = File(cacheFilePath).parent;
    await cacheParent.create(recursive: true);
    _cacheFile = await File(cacheFilePath).open(mode: FileMode.write);
    await _cacheFile!.setPosition(_decryptedSize - 1);
    await _cacheFile!.writeByte(0);
    await _cacheFile!.setPosition(0);

    // 4. 启动 HTTP 服务器
    _server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0, // 系统分配端口
    );
    _port = _server!.port;

    debugPrint('[SnPlayer] StreamingDecryptProxy: 启动于 '
        'http://127.0.0.1:$_port, 解密大小=${_decryptedSize}B '
        '(${(_decryptedSize / 1024 / 1024).toStringAsFixed(1)}MB)');

    // 5. 开始监听请求
    _serveRequests();

    return _port!;
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

    try {
      await _encFile?.close();
    } catch (_) {}
    _encFile = null;

    try {
      await _cacheFile?.flush();
      await _cacheFile?.close();
    } catch (_) {}
    _cacheFile = null;

    _blockCache.clear();

    debugPrint('[SnPlayer] StreamingDecryptProxy: 已停止');
  }

  // ═══════════════════════════════════════════════════════════
  // 请求处理
  // ═══════════════════════════════════════════════════════════

  void _serveRequests() {
    _server!.listen((request) {
      // 异步处理每个请求，不阻塞监听循环
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

    if (rangeHeader != null) {
      final parsed = _parseRange(rangeHeader, _decryptedSize);
      if (parsed != null) {
        rangeStart = parsed.start;
        rangeEnd = parsed.end;
      }
    }

    final contentLength = rangeEnd - rangeStart + 1;
    final isPartial = rangeHeader != null;

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

    try {
      await _decryptAndStream(
        request.response,
        rangeStart,
        contentLength,
      );
      await request.response.close();
    } catch (e) {
      debugPrint('[SnPlayer] StreamingDecryptProxy: 流式响应异常: $e');
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  /// 写入公共响应头
  void _writeCommonHeaders(HttpResponse response) {
    response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    response.headers.set(HttpHeaders.connectionHeader, 'keep-alive');
    response.headers.set('X-SnPlayer', 'streaming-decrypt-proxy');
  }

  /// 解析 HTTP Range 头
  ///
  /// 支持格式：
  /// - `bytes=0-` (从开头到末尾)
  /// - `bytes=0-1023` (指定范围)
  /// - `bytes=1024-` (从 1024 到末尾)
  _Range? _parseRange(String rangeHeader, int totalSize) {
    // 格式: bytes=start-end
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
      // bytes=-500 → 最后 500 字节
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
  /// [response] HTTP 响应对象
  /// [rangeStart] 请求范围起始字节（解密后数据中的偏移）
  /// [contentLength] 要输出的字节数
  Future<void> _decryptAndStream(
    HttpResponse response,
    int rangeStart,
    int contentLength,
  ) async {
    int remaining = contentLength;
    int currentPos = rangeStart;

    // 使用 256KB 处理块
    final buf = Uint8List(streamingChunkSize);
    final procBuf = Uint8List(streamingChunkSize);

    while (remaining > 0 && !_stopped) {
      final chunkLen = remaining < streamingChunkSize ? remaining : streamingChunkSize;

      // 先检查内存块缓存
      final blockIndex = currentPos ~/ streamingBlockSize;
      final blockOffset = currentPos % streamingBlockSize;
      final cachedBlock = _blockCache.get(blockIndex);

      if (cachedBlock != null) {
        // 缓存命中：从块中复制数据
        final copyLen = chunkLen;
        final srcStart = blockOffset;
        final srcEnd = srcStart + copyLen;
        final actualEnd = srcEnd > cachedBlock.length ? cachedBlock.length : srcEnd;
        final actualCopyLen = actualEnd - srcStart;

        if (actualCopyLen > 0) {
          response.add(cachedBlock.sublist(srcStart, actualEnd));
          remaining -= actualCopyLen;
          currentPos += actualCopyLen;
        }

        // 如果块内数据不足，继续从下一块读取
        if (actualCopyLen < copyLen) {
          continue;
        }

        // 让出事件循环
        if (remaining > 0) {
          await Future.delayed(Duration.zero);
        }
        continue;
      }

      // 缓存未命中：解密数据
      // 向下对齐到 16 字节边界
      final alignedStart = (currentPos ~/ aesBlockSize) * aesBlockSize;
      final skipBytes = currentPos - alignedStart;
      final counterOffset = alignedStart ~/ aesBlockSize;

      // 计算需要解密的总长度（含 skip 部分）
      final totalDecryptLen = skipBytes + chunkLen;

      // 创建调整后的 IV
      final adjustedIv = CryptoUtils.incrementCounter(_iv, counterOffset);
      final cipher = CryptoUtils.createCtrCipher(_key, adjustedIv);

      // 从加密文件读取对应区间
      final cipherFileOffset = headerSize + alignedStart;
      await _encFile!.setPosition(cipherFileOffset);

      final readLen = totalDecryptLen < streamingChunkSize
          ? totalDecryptLen
          : streamingChunkSize;
      final bytesRead = await _encFile!.readInto(buf, 0, readLen);

      if (bytesRead <= 0) {
        break;
      }

      // 解密
      cipher.processBytes(buf, 0, bytesRead, procBuf, 0);

      // 写入 HTTP 响应（跳过 skipBytes）
      final outputStart = skipBytes;
      final outputEnd = bytesRead;
      final outputLen = outputEnd - outputStart;

      if (outputLen > 0) {
        response.add(procBuf.sublist(outputStart, outputEnd));
      }

      // 写入磁盘缓存（按对齐偏移写入）
      if (_cacheFile != null) {
        try {
          await _cacheFile!.setPosition(alignedStart);
          await _cacheFile!.writeFrom(procBuf, 0, bytesRead);
        } catch (e) {
          debugPrint('[SnPlayer] StreamingDecryptProxy: 磁盘缓存写入失败: $e');
        }
      }

      // 更新内存块缓存（以 4MB 块为粒度）
      final currentBlockIndex = alignedStart ~/ streamingBlockSize;
      final blockStartAligned = currentBlockIndex * streamingBlockSize;
      // 如果本次解密的数据恰好覆盖了某个块的部分，缓存它
      // 简化：仅当数据从块边界开始时缓存整块
      if (alignedStart == blockStartAligned && bytesRead >= streamingBlockSize) {
        _blockCache.put(currentBlockIndex, Uint8List.fromList(procBuf.sublist(0, streamingBlockSize)));
      }

      remaining -= outputLen;
      currentPos += outputLen;

      // 让出事件循环，防止 UI 帧丢失
      if (remaining > 0) {
        await Future.delayed(Duration.zero);
      }
    }
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
