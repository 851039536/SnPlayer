// test/video_list_provider_test.dart — VideoListProvider 筛选与可见区索引逻辑单元测试
//
// 重点覆盖两个曾出错的点：
// 1. getVideosInFolder 的筛选正确性，以及同一筛选下返回同一列表实例（供 Selector 去重）
// 2. 可见区间索引必须基于筛选后的列表，避免缩略图加载错位

import 'package:flutter_test/flutter_test.dart';
import 'package:sn_player/models/video_item.dart';
import 'package:sn_player/providers/video_list_provider.dart';

/// 构造测试用 VideoItem
VideoItem _video(String id, {String? folder}) {
  return VideoItem(
    id: id,
    encPath: '/tmp/$id.enc',
    thumbPath: '/tmp/$id.tenc',
    displayName: id,
    folderName: folder,
    fileSize: 1024,
    encryptedAt: DateTime(2026, 1, 1),
  );
}

void main() {
  group('getVideosInFolder', () {
    test('根目录返回全量列表且为同一实例', () {
      final provider = VideoListProvider();
      final videos = [_video('a', folder: 'f1'), _video('b')];
      provider.debugSetVideos(videos);

      final result = provider.getVideosInFolder(null);

      expect(result, same(videos), reason: '根目录应直接复用 _videos，避免无谓复制');
    });

    test('按 folderName 正确筛选', () {
      final provider = VideoListProvider();
      provider.debugSetVideos([
        _video('a', folder: 'f1'),
        _video('b', folder: 'f2'),
        _video('c', folder: 'f1'),
      ]);

      final f1 = provider.getVideosInFolder('f1');

      expect(f1.map((v) => v.id), ['a', 'c']);
    });

    test('同一筛选条件重复调用返回同一实例（Selector 去重依赖此性质）', () {
      final provider = VideoListProvider();
      provider.debugSetVideos([_video('a', folder: 'f1')]);

      final first = provider.getVideosInFolder('f1');
      final second = provider.getVideosInFolder('f1');

      expect(second, same(first), reason: '同一筛选下必须是同一列表实例，否则 sliver 每次都会重建');
    });

    test('列表变更后缓存失效，返回新内容', () {
      final provider = VideoListProvider();
      provider.debugSetVideos([_video('a', folder: 'f1')]);
      expect(provider.getVideosInFolder('f1').length, 1);

      // 模拟重新扫描后内容变化
      provider.debugSetVideos([
        _video('a', folder: 'f1'),
        _video('b', folder: 'f1'),
      ]);

      expect(provider.getVideosInFolder('f1').length, 2);
    });
  });

  group('可见区索引（P0 回归防护）', () {
    test('筛选后的列表索引与全量列表索引不同 —— 证明必须传筛选列表', () {
      final provider = VideoListProvider();
      // 全量：f1 的 'b' 在全量中索引为 3
      provider.debugSetVideos([
        _video('a', folder: 'f2'),
        _video('b', folder: 'f1'),
        _video('c', folder: 'f2'),
        _video('d', folder: 'f1'),
      ]);

      final all = provider.getVideosInFolder(null);
      final f1 = provider.getVideosInFolder('f1');

      // 全量中 'd' 在索引 3；筛选后 'd' 在索引 1
      expect(all.indexWhere((v) => v.id == 'd'), 3);
      expect(f1.indexWhere((v) => v.id == 'd'), 1);

      // 这正是原实现传全量列表导致加载错位的根因：
      // 以筛选列表算出的索引 1 去索引全量列表会取到 'b'，属于另一个文件夹的视频
      expect(all[1].id, 'b');
      expect(f1[1].id, 'd');
    });

    test('筛选列表是子序列且保持原有相对顺序', () {
      final provider = VideoListProvider();
      provider.debugSetVideos([
        _video('a', folder: 'f1'),
        _video('b', folder: 'f2'),
        _video('c', folder: 'f1'),
      ]);

      final all = provider.getVideosInFolder(null);
      final f1 = provider.getVideosInFolder('f1');

      expect(f1.map((v) => v.id), ['a', 'c']);
      // 相对顺序与全量一致
      final allIds = all.map((v) => v.id).toList();
      final f1Ids = f1.map((v) => v.id).toList();
      expect(f1Ids, allIds.where(f1Ids.contains).toList());
    });
  });
}
