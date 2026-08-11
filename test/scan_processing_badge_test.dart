// 草稿卡片右上角的"生成中 / 完成"胶囊。
//
// [2026-08-06 用户签决] "正在训练"= 拍完后管线在生成**稀疏点云**,PLY 落盘就算
// 完成。所以状态不入库、直接探测文件系统 —— 拍摄链路一行都不用改(它正被另一条
// 线在改),断点续跑与 App 被杀重启这些情况天然都对。唯一入库的是"用户看过了没
// 有"(resultViewedAt)。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/me/scan_record_store.dart';
import 'package:pocketworld_flutter/ui/scan_record.dart';

void main() {
  ScanRecord rec({String? dir, DateTime? viewed}) => ScanRecord(
    id: 'r1',
    name: 'x',
    createdAt: DateTime(2026, 8, 6),
    captureDir: dir,
    resultViewedAt: viewed,
  );

  final ready = DateTime(2026, 8, 6, 12);

  test('没有拍摄目录 ⇒ 不显示(云端导入的老记录别冒泡)', () {
    expect(rec().badgeFor(null), ScanProcessingBadge.none);
    expect(rec().badgeFor(ready), ScanProcessingBadge.none);
  });

  test('有目录、PLY 没出来、**正在跑** ⇒ 生成中', () {
    expect(
      rec(dir: '/tmp/c1').badgeFor(null, isActivelyReconstructing: true),
      ScanProcessingBadge.generating,
    );
  });

  test('有目录、PLY 没出来、**没在跑** ⇒ 未完成(红)', () {
    // [2026-08-06 用户实机指认] 热 GPU 闪退后清后台重进,后台并没有在跑,却仍
    // 显示"生成中" —— 那时点卡片弹的是"继续重建?",状态显然不是"正在生成"。
    expect(rec(dir: '/tmp/c1').badgeFor(null), ScanProcessingBadge.unfinished);
  });

  test('PLY 出来了、没看过 ⇒ 完成', () {
    expect(rec(dir: '/tmp/c1').badgeFor(ready), ScanProcessingBadge.done);
  });

  test('看过了 ⇒ 消失', () {
    expect(
      rec(dir: '/tmp/c1', viewed: ready).badgeFor(ready),
      ScanProcessingBadge.none,
    );
    // 看得比完成还晚也算看过。
    expect(
      rec(
        dir: '/tmp/c1',
        viewed: ready.add(const Duration(hours: 1)),
      ).badgeFor(ready),
      ScanProcessingBadge.none,
    );
  });

  test('重新生成(PLY mtime 推后)⇒ 旧的"看过"失效,胶囊重新出现', () {
    // 这是把 resultViewedAt 存成**时刻**而不是 bool 的唯一理由。
    final regenerated = ready.add(const Duration(hours: 2));
    expect(
      rec(dir: '/tmp/c1', viewed: ready).badgeFor(regenerated),
      ScanProcessingBadge.done,
    );
  });

  test('copyWith 不会静默丢掉 resultViewedAt', () {
    // 加字段时最容易漏的一步:参数加了、return 里没传 ⇒ 任何一次 copyWith 都会
    // 把"看过"标记抹掉,胶囊永远消不掉。
    final r = rec(dir: '/tmp/c1', viewed: ready);
    expect(r.copyWith(name: 'renamed').resultViewedAt, ready);
    expect(r.copyWith(clearResultViewedAt: true).resultViewedAt, isNull);
  });

  group('PLY 探测(真实文件系统)', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('badge_probe');
    });
    tearDown(() => dir.delete(recursive: true));

    test('空文件不算完成 —— 落盘中途被读到会误判成"完成"', () async {
      final f = File('${dir.path}/official_sfm_sparse.ply');
      await f.writeAsBytes([]);
      expect(f.statSync().size, 0);
      // store.sparseReadyAt 对 size<=0 返回 null ⇒ 不算完成。落盘中途被读到时
      // 若判成"完成"会闪一下假绿。当前没在跑 ⇒ 未完成;在跑 ⇒ 生成中。
      expect(rec(dir: dir.path).badgeFor(null), ScanProcessingBadge.unfinished);
      expect(
        rec(dir: dir.path).badgeFor(null, isActivelyReconstructing: true),
        ScanProcessingBadge.generating,
      );
    });
  });

  group('升级不重置:历史项目不许冒出"完成"胶囊', () {
    late Directory docs;
    late ScanRecordStore store;

    setUp(() async {
      docs = await Directory.systemTemp.createTemp('badge_migrate_');
      store = ScanRecordStore.forTesting(documentsDirectory: docs);
    });
    tearDown(() async {
      if (await docs.exists()) await docs.delete(recursive: true);
    });

    /// 造一条"老数据":有 captureDir、PLY 已存在、从没标记过 resultViewedAt。
    Future<ScanRecord> seedOldRecord(String id) async {
      final capture = Directory('${docs.path}/captures_official/$id');
      await capture.create(recursive: true);
      await File(
        '${capture.path}/official_sfm_sparse.ply',
      ).writeAsString('ply\ncontent\n');
      final r = ScanRecord(
        id: id,
        name: id,
        createdAt: DateTime(2026, 8, 1),
        // captures_official/ 归 official 管线所有;写成默认的 self 会被
        // _ensureRouteOwnedPaths 拒(命名空间校验)。
        pipelineKind: CapturePipelineKind.official,
        captureDir: capture.path,
      );
      await store.addOrUpdate(r);
      return r;
    }

    test('加载完成时历史项目已被标记为"已看过" ⇒ badge = none', () async {
      await seedOldRecord('cap_old_1');
      await seedOldRecord('cap_old_2');

      // 关键:模拟**升级后重新启动** —— 换一个 store 实例重新从盘上加载。
      // [2026-08-06 用户实机指认] 迁移原先挂在草稿页 initState 里 unawaited
      // 调用,那时 _records 还是空的、整个迁移空转,于是所有历史项目都显示
      // "完成"。现在迁移在 _load() 的 _emit() 之前 await 完成。
      final reloaded = ScanRecordStore.forTesting(documentsDirectory: docs);
      await reloaded.ensureLoaded();

      expect(reloaded.records, hasLength(2));
      for (final r in reloaded.records) {
        expect(
          r.resultViewedAt,
          isNotNull,
          reason: '${r.id} 没在加载阶段被标记 ⇒ 升级后会冒出"完成"胶囊',
        );
        expect(
          reloaded.badgeOf(r),
          ScanProcessingBadge.none,
          reason: '${r.id} 升级后显示了胶囊,用户得手动点掉',
        );
      }
    });

    test('迁移只针对已有 PLY 的;没出 PLY 的按是否在跑区分未完成/生成中', () async {
      // 有目录但没 PLY ⇒ 不该被标记成已看过,否则它生成完也不会提示。
      final capture = Directory('${docs.path}/captures_official/cap_running');
      await capture.create(recursive: true);
      await store.addOrUpdate(
        ScanRecord(
          id: 'cap_running',
          name: 'running',
          createdAt: DateTime(2026, 8, 6),
          pipelineKind: CapturePipelineKind.official,
          captureDir: capture.path,
        ),
      );

      final reloaded = ScanRecordStore.forTesting(documentsDirectory: docs);
      await reloaded.ensureLoaded();
      final r = reloaded.records.single;
      expect(r.resultViewedAt, isNull, reason: '还没生成完就被标记成看过了');
      // 没有活跃重建 ⇒ 未完成(红);把它声明为活跃的那个 ⇒ 生成中(黑)。
      expect(reloaded.badgeOf(r), ScanProcessingBadge.unfinished);
      expect(
        reloaded.badgeOf(r, activeReconstructionCaptureDir: capture.path),
        ScanProcessingBadge.generating,
      );
      // ⚠️ 按目录名比而非绝对路径:iOS 容器 UUID 会变。
      expect(
        reloaded.badgeOf(
          r,
          activeReconstructionCaptureDir: '/somewhere/else/cap_running',
        ),
        ScanProcessingBadge.generating,
        reason: '容器路径变了就认不出自己在跑',
      );
      // 别的 capture 在跑 ⇒ 本条仍是未完成(不能整条管线一起误报)。
      expect(
        reloaded.badgeOf(
          r,
          activeReconstructionCaptureDir: '/x/cap_someone_else',
        ),
        ScanProcessingBadge.unfinished,
      );
    });

    test('迁移幂等:反复加载不改动已标记的记录', () async {
      await seedOldRecord('cap_idem');
      final first = ScanRecordStore.forTesting(documentsDirectory: docs);
      await first.ensureLoaded();
      final marked = first.records.single.resultViewedAt;
      expect(marked, isNotNull);

      final second = ScanRecordStore.forTesting(documentsDirectory: docs);
      await second.ensureLoaded();
      expect(second.records.single.resultViewedAt, marked, reason: '标记被重写了');
    });
  });
}
