// 删除项目:卡片必须**立刻**消失,不允许闪一下"未完成"。
//
// [2026-08-08 用户实机指认] "为什么我在删除一个项目的时候,项目卡片没有直接消失,
// 而且先显示了'未完成'状态几秒,然后再消失呢?我需要直接立刻消失。"
//
// 根因是 ScanRecordStore.delete 的顺序:原先先 _deleteProjectFiles(照片 + 数据库
// + 点云,几百 MB 时要跑好几秒)、后把记录移出列表。那段窗口里记录还在,但 PLY
// 已经被删了 ⇒ badgeOf → sparseReadyAt 返回 null ⇒ 胶囊算成红色"未完成";草稿页
// 每 2 秒轮询一次,正好把这个中间态显示给用户。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/me/scan_record_store.dart';
import 'package:pocketworld_flutter/ui/scan_record.dart';

void main() {
  late Directory docs;
  late ScanRecordStore store;

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('delete_instant_');
    store = ScanRecordStore.forTesting(documentsDirectory: docs);
  });
  tearDown(() async {
    if (await docs.exists()) await docs.delete(recursive: true);
  });

  /// 造一条**有点云**的 official 记录,capture 目录里塞够多文件,让删除跨越多个
  /// 事件循环 —— 否则中间窗口一帧就过去了,采样抓不到(修复前也会假绿)。
  Future<ScanRecord> seed({int filler = 400}) async {
    final dir = await store.captureDirFor(
      'doomed',
      pipelineKind: CapturePipelineKind.official,
    );
    await dir.create(recursive: true);
    await File('${dir.path}/official_sfm_sparse.ply').writeAsString('ply\n');
    for (var i = 0; i < filler; i++) {
      await File('${dir.path}/f_$i.jpg').writeAsBytes(List<int>.filled(512, 7));
    }
    final rec = ScanRecord(
      id: 'doomed',
      name: '未命名(2)',
      createdAt: DateTime.utc(2026, 8, 8),
      pipelineKind: CapturePipelineKind.official,
      captureDir: dir.path,
    );
    await store.addOrUpdate(rec);
    // 前提:落盘的点云确实被认成"完成",否则本用例测不到"未完成"这个中间态。
    expect(
      store.badgeOf(rec),
      isNot(ScanProcessingBadge.unfinished),
      reason: 'fixture 起点就是"未完成",测不出中间态',
    );
    return rec;
  }

  test('删除进行中:记录一旦还在列表上,就绝不能被算成"未完成"', () async {
    final rec = await seed();

    final observed = <ScanProcessingBadge>[];
    var sawWhilePresent = false;

    final deleting = store.delete(rec.id);
    // 像草稿页那样反复采样(它有个 2 秒轮询 + 生命周期重绘)。
    while (true) {
      final present = store.byId(rec.id) != null;
      if (present) {
        final b = store.badgeOf(rec);
        observed.add(b);
        if (b == ScanProcessingBadge.unfinished) sawWhilePresent = true;
      }
      if (!present && observed.isNotEmpty) break;
      // 让删除推进一个事件循环。
      await Future<void>.delayed(Duration.zero);
      if (observed.length > 5000) break; // 兜底,别死循环
    }
    await deleting;

    expect(
      sawWhilePresent,
      isFalse,
      reason:
          '删除途中卡片被算成"未完成"(采样 ${observed.length} 次)⇒ 用户会看到'
          '红色"未完成"闪几秒再消失',
    );
    expect(store.byId(rec.id), isNull, reason: '删完了记录还在');
  });

  test('记录在碰任何文件之前就已消失(卡片立刻消失的充分条件)', () async {
    final rec = await seed();
    final dir = Directory(rec.captureDir!);
    expect(dir.existsSync(), isTrue);

    // 第一次观察到"记录已不在列表"时,文件应该还没开始删 —— 这正是"先移除记录,
    // 后删文件"的可观测证据。
    bool? filesStillThereWhenGone;
    final deleting = store.delete(rec.id);
    while (true) {
      if (store.byId(rec.id) == null) {
        filesStillThereWhenGone = dir.existsSync();
        break;
      }
      await Future<void>.delayed(Duration.zero);
    }
    await deleting;

    expect(
      filesStillThereWhenGone,
      isTrue,
      reason: '记录消失时文件已经删掉了 ⇒ 说明还是"先删文件后移记录"的旧顺序',
    );
    // 最终一切都清掉。
    expect(dir.existsSync(), isFalse, reason: '文件没删干净');
    expect(store.byId(rec.id), isNull);
  });

  test('墓碑仍然先于一切落盘 —— 删除中途被杀不许复活', () async {
    final rec = await seed(filler: 20);
    await store.delete(rec.id);
    // 用同一个 documents 目录重开一个 store(模拟重启),记录不许回来。
    final reopened = ScanRecordStore.forTesting(documentsDirectory: docs);
    await reopened.ensureLoaded();
    expect(
      reopened.byId(rec.id),
      isNull,
      reason: '提前移除记录破坏了墓碑保护 ⇒ orphan recovery 让项目复活了',
    );
  });
}
