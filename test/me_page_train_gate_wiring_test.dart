// 作品页长按菜单的接线契约。
//
// train_gate_test.dart 证的是判定本身对;这里证的是判定**真的接在菜单上** ——
// 纯函数写对了但没人调用,是本项目反复出现过的失败形态。
//
// 断言只打在**代码**上,不打在注释上:注释里出现 "20" 或 "开始训练" 一律不算
// 数(判据不能匹配自己刚写的注释,08-22 教训)。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final raw = File('lib/ui/me_page.dart').readAsStringSync();

  /// 去掉整行注释与行尾注释后的源码 —— 所有断言都跑在这上面。
  final code = raw
      .split('\n')
      .map((line) {
        final i = line.indexOf('//');
        return i < 0 ? line : line.substring(0, i);
      })
      .join('\n');

  test('长按菜单四栏:开始训练 / 拍摄更多照片 / 改名 / 删除', () {
    expect(code, contains("'开始训练'"));
    expect(code, contains("Text('拍摄更多照片')"));
    expect(code, contains('l.meActionRename'));
    expect(code, contains('l.meActionDelete'));
  });

  test('已出点云的卡片只给「改名/删除」', () {
    // [2026-09-08 用户裁决] 三项都删:
    //   ·「重新重建点云」—— 点云已经在那儿了,重跑是给自己找事
    //   ·「查看点云」—— 点卡片本来就开查看器,菜单里再放一个是重复
    //   · 补拍 —— 只有"未完成"的项目才需要
    expect(code, isNot(contains('重新重建点云')));
    expect(code, isNot(contains("Text('查看点云')")));
    // view_sparse 已无人发出 ⇒ 处理分支也必须删,否则是死代码。
    expect(code, isNot(contains("pop('view_sparse')")));
    expect(code, isNot(contains("action == 'view_sparse'")));
    // 但点卡片开查看器那条路**必须还在**(draft_card_action 的 openSparseCloud)。
    expect(code, contains('DraftCardAction.openSparseCloud'));
    expect(code, contains('_openSparseCloud('));
    // 开始训练/补拍只挂在"未完成"分支上。
    expect(code, contains('if (!canViewSparse) ...['));
  });

  test('张数闸真的接上了,而且是同源调用不是复制阈值', () {
    // [阴性对照 2026-09-07] 第一版只断言源码里出现过 trainGateFor( ——
    // 结果把 `trainGate = TrainGate.ready` 硬塞进去、把真调用改名成
    // unusedGate,测试照样全绿。绕过闸的最省事改法恰恰保留那个字符串。
    // 所以断言必须打在**赋值链**上:trainGate 只能来自 trainGateFor,
    // trainEnabled 只能来自 trainGate。
    expect(code, contains('final trainGate = trainGateFor('));
    expect(code, contains('final trainEnabled = trainGate == TrainGate.ready'));
    // 且全文件只有这一处 trainGate 的赋值,不许有第二个来源。
    // `=(?!=)` 才是赋值 —— 不加负向前瞻会把 `trainGate == TrainGate.ready`
    // 里的比较也数进去。
    expect(RegExp(r'trainGate\s*=(?!=)').allMatches(code).length, 1);
    expect(RegExp(r'trainEnabled\s*=(?!=)').allMatches(code).length, 1);
    expect(code, contains('photoCount: photoCount'));
    // [2026-09-08] db **在** ≠ db **能开**。闸吃的必须是"能开"(dbUsable),
    // 不是 rebuildDir != null —— 后者只回答文件在不在,正是那个 errDb
    // 红弹窗的成因。
    expect(code, contains('hasResumableData: dbUsable'));
    expect(code, isNot(contains('hasResumableData: rebuildDir != null')));
    expect(RegExp(r'dbUsable\s*=(?!=)').allMatches(code).length, 1);
    expect(code, contains('sqliteDatabaseUsable('));
    // 阈值只能来自 live_sfm_publish_policy.dart。me_page 自己写死 20 就是
    // 制造第二个真相 —— 将来改阈值必漏一边。
    expect(code, isNot(contains('>= 20')));
    expect(code, isNot(contains('< 20')));
    expect(code, isNot(contains('20;')));
  });

  test('张数以磁盘为准,不用保存时的快照', () {
    expect(code, contains('_countCapturePhotos('));
    expect(code, contains('record.photosDir'));
    // photoCount 只许当兜底(?? 后面),不许当主判据。
    expect(code, isNot(contains('photoCount: record.photoCount')));
  });

  test('置灰项仍然可点,并且点了必须有回答', () {
    // onTap 不能是 null —— 置灰但不可点 = 用户永远问不出为什么。
    expect(code, contains("'train_blocked'"));
    expect(code, contains("action == 'train_blocked'"));
    expect(code, contains('_showCenterToast('));
    expect(code, contains('_trainBlockedReason('));
  });

  test('提示落在屏幕正中、3 秒后自己消失', () {
    final start = code.indexOf('void _showCenterToast(');
    expect(start, greaterThanOrEqualTo(0));
    final body = code.substring(start, start + 1400);
    expect(body, contains('OverlayEntry('));
    expect(body, contains('Center('));
    expect(body, contains('Duration(seconds: 3)'));
    expect(body, contains('entry.remove()'));
    // SnackBar 贴底会被 tab bar 压住,这条提示必须在视线中心。
    expect(body, isNot(contains('SnackBar')));
  });

  test('「拍摄更多照片」接的是真动作,不是 toast 占位', () {
    expect(code, contains("action == 'capture_more'"));
    final start = code.indexOf("action == 'capture_more'");
    final body = code.substring(start, start + 1200);
    // 必须真的调补拍路由 —— 这条是本功能的心脏,只断言"有个 toast"会让
    // 把真动作换回占位提示的改法照样绿(第一版张数闸就是这样被变异骗过的)。
    expect(body, contains('extendRoute('));
    expect(body, contains('widget.officialExtendRoute'));
    // 四个不可用分支各自说原因,一个都不许吞。
    expect(body, contains('CapturePipelineKind.official'));
    expect(body, contains('activeReconstructionCaptureDir != null'));
    expect(body, contains('rebuildDir == null'));
    expect(
      RegExp(r'_showCenterToast\(').allMatches(body).length,
      greaterThanOrEqualTo(4),
    );
    // 补完照片要刷新卡片,否则用户看不到张数变化、闸也不会解灰。
    expect(body, contains('setState(() {})'));
  });

  test('补拍路由真的从 app_shell 注入到长按菜单', () {
    final shell = File('lib/ui/app_shell.dart').readAsStringSync();
    expect(shell, contains('officialExtendRoute: pushOfficialExtendRoute'));
    // MePage -> _MyWorksSection 的透传断了,菜单里就永远是 null。
    expect(code, contains('officialExtendRoute: widget.officialExtendRoute'));
  });

  test('🔴db 坏掉时「开始训练」改走"从照片重建",而不是置灰或续跑', () {
    // 分叉必须真的分:只要还写着无条件 _offerResume,db 坏的项目就会照旧
    // 一路走到 native 炸成 errDb(2026-09-08 真机红弹窗)。
    expect(code, contains('final trainRoute = trainRouteFor('));
    expect(code, contains('TrainRoute.resumeFromDb'));
    expect(code, contains('TrainRoute.rebuildFromArchivedPhotos'));
    expect(RegExp(r'trainRoute\s*=(?!=)').allMatches(code).length, 1);
    // [阴性对照 2026-09-08] 只断言"两个枚举名都出现过"挡不住把 switch 的
    // 主语换成常量(`switch (TrainRoute.resumeFromDb)`)—— 那一改两个名字
    // 照样在,分叉却已经死了。所以必须钉住**分的是谁**。
    expect(code, contains('switch (trainRoute) {'));
    expect(RegExp(r'switch \(trainRoute\)').allMatches(code).length, 1);
    // 闸的"还能不能重建"必须问照片,不是再问一次 db。
    expect(code, contains('canRebuildFromPhotos:'));
    expect(code, contains('archivedPhotoCount('));
    // 路由从 app_shell 注入并一路透传到长按菜单;断一节菜单里就永远是 null。
    final shell = File('lib/ui/app_shell.dart').readAsStringSync();
    expect(shell, contains('pushOfficialRebuildFromPhotosRoute'));
    expect(
      code,
      contains('officialRebuildFromPhotosRoute:\n'
          '                      widget.officialRebuildFromPhotosRoute'),
    );
    // 那条腿本身必须真的存在于 sfm_resume.dart,并且**改名**挪开死 db 而不是删。
    final resume = File(
      'lib/official_capture/sfm_resume.dart',
    ).readAsStringSync();
    final resumeCode = resume
        .split('\n')
        .map((line) {
          final i = line.indexOf('//');
          return i < 0 ? line : line.substring(0, i);
        })
        .join('\n');
    expect(resumeCode, contains('Future<ArchivedRebuildResult> '
        'rebuildFromArchivedPhotos('));
    expect(resumeCode, contains('sidelineDatabaseForFreshSession('));
    // 挪开用 rename;出现 delete 就是把用户唯一剩下的证据毁了。
    final sideStart = resumeCode.indexOf(
      'sidelineDatabaseForFreshSession(String',
    );
    expect(sideStart, greaterThanOrEqualTo(0));
    final sideBody = resumeCode.substring(sideStart, sideStart + 900);
    expect(sideBody, contains('.rename('));
    expect(sideBody, isNot(contains('.delete(')));
    // 旧的 fed_frames.jsonl 也必须一起挪:它按 frameId 追加,新旧会话撞号会
    // 让取色照着错的照片采(cap47 色彩污染同一类错配)。
    expect(sideBody, contains('official_sfm_fed_frames.jsonl'));
    // wal/shm 留一个都会被 sqlite 当成新库的日志回放。
    expect(sideBody, contains('official_sfm_live.db-wal'));
    expect(sideBody, contains('official_sfm_live.db-shm'));
  });

  test('🔴db 覆盖不全时也改走全量重喂(未命名(8) 那类项目)', () {
    // 判据必须**同时**吃两条腿:只吃 dbUsable 就会把"db 健全但只装了 6 张"
    // 的项目送去续跑 —— 那正是 2026-09-11 未命名(8) 丢掉 20 张的成因。
    expect(code, contains('official_sfm_resume.projectCoverage('));
    expect(code, contains('final dbCoversAllPhotos = coverage'));
    expect(code, contains('dbCoversAllPhotos: dbCoversAllPhotos'));
    expect(RegExp(r'dbCoversAllPhotos\s*=(?!=)').allMatches(code).length, 1);
    // 覆盖不全必须留痕,否则下次又只能靠用户肉眼看点云数量发现。
    expect(code, contains('db 覆盖不全'));
  });

  test('🔴补拍结束走整项目全量重喂,不交付本场那朵云', () {
    final arp = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();
    final arpCode = arp
        .split('\n')
        .map((line) {
          final i = line.indexOf('//');
          return i < 0 ? line : line.substring(0, i);
        })
        .join('\n');
    // 补拍分支必须真的调全量重喂 —— 这是本次修复的心脏。
    // 条件必须真的来自「这次是不是补拍」,不是一个能被改成常量的旗子。
    //
    // [阴性对照 2026-09-11] 第一版断言是"从 `final extendingProject =` 起
    // 160 字符内出现 widget.extendCaptureDir" —— 变异成
    // `final extendingProject = false; final unusedExtend = widget.extend…`
    // 照样全绿:它只证明了条件**在附近**,没证明值**来自**条件。
    // 所以要切到分号为止,并且全文只许有这一处赋值。
    final ci = arpCode.indexOf('final extendingProject =');
    expect(ci, greaterThanOrEqualTo(0));
    final rhs = arpCode.substring(
      ci + 'final extendingProject ='.length,
      arpCode.indexOf(';', ci),
    );
    expect(rhs, contains('widget.extendCaptureDir != null'));
    expect(
      RegExp(r'extendingProject\s*=(?!=)').allMatches(arpCode).length,
      1,
    );
    expect(arpCode, contains('if (extendingProject) {'));
    expect(
      arpCode,
      contains('sfm_resume.rebuildFromArchivedPhotos(captureDirForSfm)'),
    );
    // 且 recon.finalize() 只剩**非补拍**那一条路能走到。
    expect(RegExp(r'recon\.finalize\(\)').allMatches(arpCode).length, 1);
    final ei = arpCode.indexOf('if (extendingProject) {');
    final pi = arpCode.indexOf('} else if (sfmPreviewing) {', ei);
    final fi = arpCode.indexOf('recon.finalize();');
    expect(ei, greaterThanOrEqualTo(0));
    // 🔴 补拍分支必须排在 sfmPreviewing **之前**:开场已经把旧 db 挪开了,
    // 这一场哪怕只拍 1 张(够不到 offeredCount>=2 的预览门槛)也必须重喂,
    // 否则项目被留在"旧 db 已挪走、新 db 只有 1 帧、PLY 还是旧的"的更差状态。
    expect(pi, greaterThan(ei), reason: '补拍分支必须先于预览分支');
    expect(fi, greaterThan(pi), reason: 'finalize 只能落在非补拍那条路上');
    // 圈的是**补拍分支本身**,到 `} else if` 为止 —— 把后面圈进来会永远红,
    // 因为那一侧本来就该开伞(判据划错边界和判据写错一样坏)。
    final branch = arpCode.substring(ei, pi);
    // 全量重喂自带 umbrella,补拍分支再开一层就是两层伞。
    expect(branch, isNot(contains('_beginReconUmbrella')));
    // 会话必须先彻底放掉:重建资源全局独占,不 dispose 就起不来第二个。
    expect(branch, contains('recon.dispose()'));
    expect(branch, contains('rebuildFromArchivedPhotos'));
  });

  test('🔴补拍开场把旧 db 挪开(撞名会废掉整场),而且是改名不是删', () {
    final arp = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();
    final arpCode = arp
        .split('\n')
        .map((line) {
          final i = line.indexOf('//');
          return i < 0 ? line : line.substring(0, i);
        })
        .join('\n');
    final si = arpCode.indexOf('sfm_resume.sidelineDatabaseForFreshSession(');
    expect(si, greaterThanOrEqualTo(0));
    // 必须只在补拍时挪 —— 正常拍摄是全新目录,挪了等于白开一次 IO。
    final before = arpCode.substring(0, si);
    expect(before.lastIndexOf('widget.extendCaptureDir != null'),
        greaterThan(before.lastIndexOf('SfmLiveRecon.start')));
    // 且必须挪在起会话**之前**。
    final after = arpCode.substring(si);
    expect(after.indexOf('SfmLiveRecon.start'), greaterThanOrEqualTo(0));

    // 挪的动作本身:rename,绝不 delete;wal/shm/账本一个都不能落下。
    final resume = File(
      'lib/official_capture/sfm_resume.dart',
    ).readAsStringSync();
    final rCode = resume
        .split('\n')
        .map((line) {
          final i = line.indexOf('//');
          return i < 0 ? line : line.substring(0, i);
        })
        .join('\n');
    final hi = rCode.indexOf('sidelineDatabaseForFreshSession(String');
    expect(hi, greaterThanOrEqualTo(0));
    final body = rCode.substring(hi, hi + 900);
    expect(body, contains('.rename('));
    expect(body, isNot(contains('.delete(')));
    for (final n in const <String>[
      'official_sfm_live.db-wal',
      'official_sfm_live.db-shm',
      'official_sfm_fed_frames.jsonl',
    ]) {
      expect(body, contains(n));
    }
  });

  test('采集会话复用目录时绝不删,且编号接着排', () {
    final sess = File(
      'lib/official_capture/capture_session.dart',
    ).readAsStringSync();
    final sessCode = sess
        .split('\n')
        .map((line) {
          final i = line.indexOf('//');
          return i < 0 ? line : line.substring(0, i);
        })
        .join('\n');
    expect(sessCode, contains('String? extendCaptureDir'));
    // 复用分支里出现 delete = 直接毁掉用户上一次拍摄的全部照片和 db。
    // 只圈**复用**分支本身:到 `} else {` 为止。把 else 分支(新建时那句合法的
    // delete)圈进来,断言就会永远红 —— 判据划错边界和判据本身写错一样坏。
    final extStart = sessCode.indexOf('if (extending) {');
    expect(extStart, greaterThanOrEqualTo(0));
    final extEnd = sessCode.indexOf('} else {', extStart);
    expect(extEnd, greaterThan(extStart));
    final extBlock = sessCode.substring(extStart, extEnd);
    expect(extBlock, isNot(contains('delete(')));
    // 编号必须接上,归零会让新照片与老照片同名覆盖(cap47 16% 色彩污染)。
    expect(sessCode, contains('_frameSeq = maxFrameSeqInNames('));
  });
}
