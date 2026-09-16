// [BA-PROGRESS 2026-09-16] 全局 BA「迭代进度」信号的 Dart 侧契约锁。
//
// 新 C ABI(正在加进 PWOfficialSfm.framework,**机上现役包还没有**):
//   int pwofficial_finalize_progress(s, int* stage, int* round,
//                                    int* iter, int* max_iter);
// 因此这条链上唯一不可协商的性质是:**缺符号时必须与今天逐字节同行为**。
//
// 本文件钉死五件事(全部是源码锚点判据,配阳性对照):
//   ① FFI 里 pwofficial_finalize_progress 的 lookup 包在 try/catch 里,
//      结果存成**可空**字段 —— 旧包上 lookup 抛错不许冒泡;
//   ② phase-2 的 250ms 轮询里,finalizeProgress() 只在 hasFinalizeProgress
//      守卫之后调用(缺符号时每 tick 只多一次布尔判断);
//   ③ 消息只在元组**变化**时才发(`!=` 上一 tick);
//   ④ facade 的 case 'finalize_progress' 构造 SfmLiveFinalizeProgress;
//   ⑤ 阳性对照:轮询里原有的 finalizeStatus() 读取原样还在(本次是纯增量,
//      时序/事件一个都不许动)。
//
// 判据先剥注释行再**把空白归一**:dart format 随时会重排这些多行调用,
// 裸 contains 会在下一次 format 时静默变红。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 剥掉整行注释 + 把连续空白压成单空格,得到一条与排版无关的源码带。
String _norm(String path) {
  final f = File(path);
  expect(f.existsSync(), isTrue, reason: '源文件不在:$path');
  final code = f
      .readAsStringSync()
      .split('\n')
      .where(
        (l) =>
            !l.trimLeft().startsWith('//') && !l.trimLeft().startsWith('///'),
      )
      .join('\n');
  return code.replaceAll(RegExp(r'\s+'), ' ');
}

void main() {
  late String ffi;
  late String recon;

  setUpAll(() {
    ffi = _norm('lib/official_aether_sfm_ffi.dart');
    recon = _norm('lib/official_capture/sfm_live_recon.dart');
  });

  test('阳性对照:五个锚点在非注释源码里都在', () {
    // 锚点被改名 ⇒ 下面的顺序/包含判据会静默全绿,必须先在这里炸。
    expect(
      ffi.contains("'pwofficial_finalize_progress'"),
      isTrue,
      reason: 'FFI 里没有 pwofficial_finalize_progress 的 lookup',
    );
    expect(
      ffi.contains("'pwofficial_finalize_status'"),
      isTrue,
      reason: '旧的 finalize_status 绑定不见了 —— 这次是纯增量,不许动它',
    );
    expect(
      recon.contains('Timer.periodic(const Duration(milliseconds: 250)'),
      isTrue,
      reason: 'phase-2 轮询改了 —— 先修锚,别改判据',
    );
    expect(
      recon.contains("case 'finalize_progress':"),
      isTrue,
      reason: 'facade 少了 finalize_progress 分支',
    );
    expect(
      recon.contains('class SfmLiveFinalizeProgress extends SfmLiveEvent {'),
      isTrue,
      reason: '事件类不见了',
    );
    // 它必须与 phase1_done 并排声明(同一等待页的同一组信号)。
    expect(
      recon.contains('class SfmLiveFinalizePhase1Done extends SfmLiveEvent {'),
      isTrue,
    );
  });

  test('🔴 ① lookup 包在 try/catch 里,且存成可空字段', () {
    final sym = ffi.indexOf("'pwofficial_finalize_progress'");
    expect(sym, greaterThanOrEqualTo(0));

    final tryAt = ffi.lastIndexOf('try {', sym);
    expect(
      tryAt,
      greaterThanOrEqualTo(0),
      reason: 'lookup 前面没有 try —— 旧 framework 上会直接抛 ArgumentError',
    );
    final catchAt = ffi.indexOf('catch (', sym);
    expect(catchAt, greaterThan(sym));
    expect(
      catchAt - sym,
      lessThan(200),
      reason:
          'catch 离 lookup 太远 —— 很可能捕的是别的 try,'
          '这一条的失败会漏出去',
    );
    // try 与 lookup 之间不许再开一个作用域把它套进别的语句。
    expect(
      ffi.substring(tryAt, sym).contains('} catch'),
      isFalse,
      reason: 'lookup 与最近的 try 之间夹了别的 try/catch —— 包错了',
    );

    // 存成**可空**:调用点才能靠 null 判「这个包没有这个符号」。
    expect(
      ffi.contains('static final _FinalizeProgressDart? _finalizeProgress ='),
      isTrue,
      reason: '必须是可空字段;非空字段等于把"缺符号"变成崩溃',
    );
    expect(
      ffi.contains('bool get hasFinalizeProgress =>'),
      isTrue,
      reason: '轮询要靠它做每 tick 的那一次布尔判断',
    );

    // 阳性对照:其余绑定**没有**被顺手改成可空/包进 try(旧契约不许动)。
    expect(
      ffi.contains('static final _FinalizeStatusDart _finalizeStatus ='),
      isTrue,
      reason: 'finalize_status 的非空绑定被改了 —— 越界改动',
    );
  });

  test('🔴 ① finalizeProgress() 非 0 返回 null,且四个 int 一定被释放', () {
    final m = ffi.indexOf(
      '({int stage, int round, int iter, int maxIter})? finalizeProgress()',
    );
    expect(m, greaterThanOrEqualTo(0), reason: '方法签名改了 —— 先修锚');
    final body = ffi.substring(m, m + 900);
    expect(
      body.contains('if (fn == null) return null;'),
      isTrue,
      reason: '缺符号必须返回 null,不许调 null',
    );
    expect(
      body.contains('if (rc != 0) return null;'),
      isTrue,
      reason: 'native 非 0 = 不可用,必须返回 null',
    );
    expect(body.contains('} finally {'), isTrue, reason: '必须 finally 释放');
    for (final v in ['stage', 'round', 'iter', 'maxIter']) {
      expect(
        body.contains('calloc.free($v);'),
        isTrue,
        reason: '$v 没释放 —— 250ms 一 tick 的泄漏',
      );
    }
  });

  test('🔴 ② 轮询里 finalizeProgress() 只在 hasFinalizeProgress 守卫之后调用', () {
    final poll = recon.indexOf(
      'Timer.periodic(const Duration(milliseconds: 250)',
    );
    expect(poll, greaterThanOrEqualTo(0));

    final guard = recon.indexOf('if (s.hasFinalizeProgress) {', poll);
    final call = recon.indexOf('s.finalizeProgress()', poll);
    expect(guard, greaterThan(poll), reason: '守卫不在轮询里 —— 缺符号的包上每 tick 会多做事');
    expect(call, greaterThan(guard), reason: '调用跑到守卫前面去了');
    expect(call - guard, lessThan(120), reason: '调用离守卫太远,中间夹了别的语句 —— 守的可能不是它');

    // 全文件只许有这一处调用(别处再摸一次就绕开了守卫)。
    expect(
      recon.indexOf('s.finalizeProgress()'),
      call,
      reason: '守卫之外还有一处 finalizeProgress() 调用',
    );
    expect(
      recon.indexOf(
        '.finalizeProgress()',
        call + 's.finalizeProgress()'.length,
      ),
      -1,
      reason: 'finalizeProgress() 被调了不止一次',
    );
  });

  test('🔴 ③ 只在元组变化时才发消息', () {
    final poll = recon.indexOf(
      'Timer.periodic(const Duration(milliseconds: 250)',
    );
    // 上一 tick 的元组必须是可空记录,且声明在 timer 之前。
    final last = recon.indexOf(
      '({int stage, int round, int iter, int maxIter})? lastProgress;',
    );
    expect(last, greaterThanOrEqualTo(0), reason: '没有"上一 tick"的记忆');
    expect(last, lessThan(poll), reason: 'lastProgress 声明在 timer 里面会每 tick 归零');

    final changed = recon.indexOf('pg != lastProgress', poll);
    expect(
      changed,
      greaterThan(poll),
      reason: '没有跟上一 tick 比 —— 会变成 250ms 一条的洪水',
    );
    expect(
      recon.contains('if (pg != null && pg != lastProgress) {'),
      isTrue,
      reason: 'null(不可用)与"没变"必须都被挡住',
    );

    final assign = recon.indexOf('lastProgress = pg;', changed);
    final send = recon.indexOf("'evt': 'finalize_progress',", changed);
    expect(assign, greaterThan(changed), reason: '没更新上一 tick ⇒ 每 tick 都会发');
    expect(send, greaterThan(changed), reason: '发送必须在变化判据之内');
    expect(
      recon.substring(changed, send).contains('boot.reply.send('),
      isTrue,
      reason: '走的不是 worker→facade 的那条 reply port',
    );
    for (final k in [
      "'stage': pg.stage,",
      "'round': pg.round,",
      "'iter': pg.iter,",
      "'max_iter': pg.maxIter,",
    ]) {
      expect(recon.contains(k), isTrue, reason: '消息少了字段:$k');
    }
  });

  test('🔴 ④ facade 的 case 构造 SfmLiveFinalizeProgress', () {
    final c = recon.indexOf("case 'finalize_progress':");
    expect(c, greaterThanOrEqualTo(0));
    final body = recon.substring(c, c + 400);
    expect(
      body.contains('_events.add( SfmLiveFinalizeProgress(') ||
          body.contains('_events.add(SfmLiveFinalizeProgress('),
      isTrue,
      reason: 'case 没有把事件推进 _events',
    );
    expect(body.contains("stage: msg['stage']"), isTrue);
    expect(body.contains("round: msg['round']"), isTrue);
    expect(body.contains("iter: msg['iter']"), isTrue);
    expect(
      body.contains("maxIter: msg['max_iter']"),
      isTrue,
      reason: "worker 发的 key 是 snake_case 的 'max_iter'",
    );

    // 事件类字段齐全(等待页要靠这四个数算百分比)。
    final k = recon.indexOf(
      'class SfmLiveFinalizeProgress extends SfmLiveEvent {',
    );
    final decl = recon.substring(k, k + 400);
    for (final f in [
      'final int stage;',
      'final int round;',
      'final int iter;',
      'final int maxIter;',
    ]) {
      expect(decl.contains(f), isTrue, reason: '事件类少了字段:$f');
    }
  });

  test('🔴 ⑤ 阳性对照:轮询原有的 finalizeStatus() 读取与终态分支原样还在', () {
    final poll = recon.indexOf(
      'Timer.periodic(const Duration(milliseconds: 250)',
    );
    final status = recon.indexOf('final st = s.finalizeStatus();', poll);
    expect(
      status,
      greaterThan(poll),
      reason: '轮询不再读 finalizeStatus() —— refined 永远不会被发现',
    );
    final refined = recon.indexOf(
      'if (st == AetherSfmFinalizeStatus.refined) {',
      status,
    );
    expect(refined, greaterThan(status), reason: 'refined 分支没了');
    expect(
      recon.indexOf(
        '} else if (st == AetherSfmFinalizeStatus.error) {',
        refined,
      ),
      greaterThan(refined),
      reason: 'error 分支没了',
    );
    // 新逻辑必须夹在 status 读取与终态判决之间,不许改动轮询周期。
    final guard = recon.indexOf('if (s.hasFinalizeProgress) {', poll);
    expect(guard, greaterThan(status));
    expect(guard, lessThan(refined));
    expect(
      recon.contains('Timer.periodic(const Duration(milliseconds: 250)'),
      isTrue,
      reason: '轮询周期被改了 —— 本次改动不许碰时序',
    );
  });
}
