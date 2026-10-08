// test/widget_test.dart — 应用冒烟测试
//
// 说明：原文件是 Flutter 默认计数器模板（引用不存在的 MyApp），一直无法编译。
// 现改为最小可用的启动冒烟测试：验证 SnPlayerApp 能构建出 MaterialApp。
// 注意：完整启动会触发权限请求与文件扫描，故此处只做类型级冒烟校验。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:sn_player/main.dart';
import 'package:sn_player/providers/folder_provider.dart';
import 'package:sn_player/providers/video_list_provider.dart';

void main() {
  testWidgets('SnPlayerApp 能构建并注入两个顶层 Provider', (tester) async {
    await tester.pumpWidget(const SnPlayerApp());

    // 顶层 Provider 已注入
    final context = tester.element(find.byType(MaterialApp));
    expect(Provider.of<FolderProvider>(context, listen: false), isNotNull);
    expect(Provider.of<VideoListProvider>(context, listen: false), isNotNull);

    // MaterialApp 已构建（标题正确）
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.title, 'SnPlayer');
    expect(app.debugShowCheckedModeBanner, isFalse);
  });
}
