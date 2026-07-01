import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

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
///
/// 并发安全：每个请求独立打开加密文件句柄，磁盘缓存写入用互斥锁保护。
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

  /// 内存块缓存（LRU），key 为块索引
  final _BlockCache _blockCache = _BlockCache();

  /// 磁盘缓存写入互斥锁（多个并发请求串行写入，避免 setPosition 竞态）
  final _cacheMutex = _Mutex();
  RandomAccessFile? _cacheFile;

  /// 启动代理服务器，返回分配的端口号。
  ///
  /// [encPath] 加密文件路径
  /// [cacheFilePath] 磁盘缓存文件路径（预分配，流式写入解密数据）
  Future<int> start(String encPath, String cacheFilePath) async {
    _encPath = encPath;

    // 1. 读取加密文件元信息
    _fileInfo = await CryptoService.getEncryptedFileInfo(encPath);
    _iv = _fileInfo.iv;
    _key = _fileInfo.key;
    _decryptedSize = _fileInfo.decryptedSize;

    // 2. 推断 Content-Type（根据原始文件名扩展名）
    _contentType = _guessContentType(encPath);

    // 3. 预分配并打开磁盘缓存文件（写入用，互斥锁保护）
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
        '(${(_decryptedSize / 1024 / 1024).toStringAsFixed(1)}MB), '
        'Content-Type=$_contentType');

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

  /// 解密处理块大小（1MB）
  ///
  /// 大于 [streamingChunkSize]（256KB），减少循环次数和事件循环让出频率，
  /// 提升供数吞吐量，避免播放器缓冲区饥饿导致卡顿。
  static const int _decryptBlockSize = 1024 * 1024;

  /// 解密并流式输出指定范围的数据
  ///
  /// 每个请求独立打开加密文件句柄，消除并发 setPosition 竞态。
  /// 磁盘缓存写入采用 fire-and-forget（不阻塞响应流），保证供数连续性。
  Future<void> _decryptAndStream(
    HttpResponse response,
    int rangeStart,
    int contentLength,
  ) async {
    int remaining = contentLength;
    int currentPos = rangeStart;

    final buf = Uint8List(_decryptBlockSize);
    final procBuf = Uint8List(_decryptBlockSize);

    // 每个请求独立打开文件句柄，避免并发竞态
    final encFile = await File(_encPath).open(mode: FileMode.read);

    try {
      while (remaining > 0 && !_stopped) {
        final chunkLen =
            remaining < _decryptBlockSize ? remaining : _decryptBlockSize;

        // 先检查内存块缓存
        final blockIndex = currentPos ~/ streamingBlockSize;
        final blockOffset = currentPos % streamingBlockSize;
        final cachedBlock = _blockCache.get(blockIndex);

        if (cachedBlock != null) {
          final copyLen = chunkLen;
          final srcStart = blockOffset;
          final srcEnd = srcStart + copyLen;
          final actualEnd =
              srcEnd > cachedBlock.length ? cachedBlock.length : srcEnd;
          final actualCopyLen = actualEnd - srcStart;

          if (actualCopyLen > 0) {
            response.add(cachedBlock.sublist(srcStart, actualEnd));
            remaining -= actualCopyLen;
            currentPos += actualCopyLen;
          }

          if (actualCopyLen < copyLen) {
            continue;
          }

          // 缓存命中时每 4MB 让出一次
          if (remaining > 0 && (contentLength - remaining) % (4 * 1024 * 1024) < _decryptBlockSize) {
            await Future.delayed(Duration.zero);
          }
          continue;
        }

        // 缓存未命中：解密数据
        // 向下对齐到 16 字节边界
        final alignedStart = (currentPos ~/ aesBlockSize) * aesBlockSize;
        final skipBytes = currentPos - alignedStart;
        final counterOffset = alignedStart ~/ aesBlockSize;

        final totalDecryptLen = skipBytes + chunkLen;

        final adjustedIv = CryptoUtils.incrementCounter(_iv, counterOffset);
        final cipher = CryptoUtils.createCtrCipher(_key, adjustedIv);

        // 从加密文件读取对应区间（独立句柄，无竞态）
        final cipherFileOffset = headerSize + alignedStart;
        await encFile.setPosition(cipherFileOffset);

        final readLen = totalDecryptLen < _decryptBlockSize
            ? totalDecryptLen
            : _decryptBlockSize;
        final bytesRead = await encFile.readInto(buf, 0, readLen);

        if (bytesRead <= 0) {
          break;
        }

        // 解密
        cipher.processBytes(buf, 0, bytesRead, procBuf, 0);

        // 写入 HTTP 响应（跳过 skipBytes）— 先写响应，保证供数连续
        final outputStart = skipBytes;
        final outputEnd = bytesRead;
        final outputLen = outputEnd - outputStart;

        if (outputLen > 0) {
          response.add(procBuf.sublist(outputStart, outputEnd));
        }

        // 磁盘缓存写入 — fire-and-forget，不阻塞响应流
        // 复制数据后异步写入，避免 procBuf 被下一轮覆盖
        if (outputLen > 0) {
          final cacheData = Uint8List.fromList(procBuf.sublist(0, bytesRead));
          final cacheOffset = alignedStart;
          unawaited(_writeToCache(cacheOffset, cacheData, bytesRead));
        }

        // 更新内存块缓存
        final currentBlockIndex = alignedStart ~/ streamingBlockSize;
        final blockStartAligned = currentBlockIndex * streamingBlockSize;
        if (alignedStart == blockStartAligned &&
            bytesRead >= streamingBlockSize) {
          _blockCache.put(
            currentBlockIndex,
            Uint8List.fromList(procBuf.sublist(0, streamingBlockSize)),
          );
        }

        remaining -= outputLen;
        currentPos += outputLen;

        // 每 4MB 让出一次事件循环，平衡吞吐量和 UI 响应
        if (remaining > 0 && (contentLength - remaining) % (4 * 1024 * 1024) < _decryptBlockSize) {
          await Future.delayed(Duration.zero);
        }
      }
    } finally {
      await encFile.close();
    }
  }

  /// 互斥写入磁盘缓存
  Future<void> _writeToCache(int offset, Uint8List data, int length) async {
    if (_cacheFile == null) {
      return;
    }

    await _cacheMutex.synchronized(() async {
      if (_cacheFile == null || _stopped) {
        return;
      }
      try {
        await _cacheFile!.setPosition(offset);
        await _cacheFile!.writeFrom(data, 0, length);
      } catch (e) {
        debugPrint('[SnPlayer] StreamingDecryptProxy: 磁盘缓存写入失败: $e');
      }
    });
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

// ═══════════════════════════════════════════════════════════
// 简易互斥锁（基于 Completer 队列）
// ═══════════════════════════════════════════════════════════

class _Mutex {
  Completer<void>? _completer;

  Future<T> synchronized<T>(Future<T> Function() fn) async {
    while (_completer != null) {
      await _completer!.future;
    }
    _completer = Completer<void>();
    try {
      return await fn();
    } finally {
      _completer!.complete();
      _completer = null;
    }
  }
}

/// HTTP Range 解析结果
class _Range {
  final int start;
  final int end;
  const _Range(this.start, this.end);
}
