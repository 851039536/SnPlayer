// lib/services/streaming_decrypt_worker.dart — 流式解密长驻 Worker Isolate（按需 Range 解密、ack 窗口流控、并发取消）

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:pointycastle/api.dart';

import '../config/crypto.dart';
import '../utils/crypto_utils.dart';

// 解密在独立 Isolate 执行，主线程事件循环零同步阻塞。
// 主线程通过 SendPort 发送命令，worker 通过 replyPort 回传解密数据块。
//
// 命令：
// - 'init': 初始化 key/iv/encPath（只调一次）
// - 'decrypt_range': 解密指定范围，连续回传数据块
// - 'cancel': 取消指定 requestId 的解密任务（seek 时调用）
//
// 注：无 'stop' 命令——代理停止时直接 kill(immediate)，消息不会被处理。
//
// 流控：worker 每发 [_ackWindowSize] 块后等主线程 ack，
// 防止超前解密导致内存积压。主线程 flush 完成后才发 ack。
//
// 并发：worker 的 async 事件循环可交替处理多个 decrypt_range 请求
// （视频轨+音频轨），各请求有独立的 replyPort 和 ackReceivePort。

/// worker 入口函数（顶层函数，Isolate.spawn 要求）
void decryptWorkerEntry(SendPort mainPort) {
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
/// 使用 ack 窗口流控（[_ackWindowSize] 块等一次 ack），
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
  const blockSize = streamingDecryptBlockSize;
  const ackWindowSize = streamingAckWindowSize; // 每窗口等一次 ack，防超前解密内存积压

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

      if (outputLen <= 0) {
        // 截断文件 + 非 16 字节对齐 seek 时，读到的数据可能不超过 skipBytes，
        // outputLen 为 0/负数；继续循环会使 remaining 反向增大导致死循环
        replyPort.send({'type': 'error', 'message': '解密数据不足（文件可能已截断）'});
        return;
      }

      // sublist 本身即返回拷贝，无需再套 Uint8List.fromList 二次拷贝
      final outputData = procBuf.sublist(outputStart, outputEnd);
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

      remaining -= outputLen;
      currentPos += outputLen;
      isFirstChunk = false;
    }

    if (remaining > 0) {
      // EOF 提前到来（文件被截断/修改）：已声明的 contentLength 未写满，
      // 发 done 会让主线程误判为完整写入并正常 close 响应
      replyPort.send({
        'type': 'error',
        'message': '文件提前结束，剩余 $remaining 字节未解密（文件可能已损坏）',
      });
      return;
    }

    replyPort.send({'type': 'done'});
  } finally {
    await encFile.close();
    await ackIterator.cancel();
    ackReceivePort.close();
  }
}
