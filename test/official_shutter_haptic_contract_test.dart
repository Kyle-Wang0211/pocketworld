import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // 2026-09-01 契约变更:震动从「快门受理」挪到「挂 AR 相框」。
  //
  // 旧契约(本测试上一版钉的)是震动发在 _admitShutterCapture 里,也就是**照片还
  // 没拍**的时刻。后果是震动会说谎:全历史 captureFailed 22 次 + 重复判决毁片
  // 80 次,每一次都先震过 —— 用户数到 30+ 次震动而相册只有 20 张。
  //
  // 新契约:震动与 addPhotoCard 在同一处、中间不隔任何 await。
  // 这兑现用户定的底线「拍照和给反馈必须同时发生」,同时让震一次 = 真有一张。
  test('震动不在受理时刻发 —— 那时照片还不存在', () {
    final source = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();

    final admissionStart = source.indexOf(
      '_ShutterAdmission _admitShutterCapture({bool automaticSelection = false})',
    );
    final admissionEnd = source.indexOf(
      'bool _enqueueShutterCapture({bool automaticSelection = false})',
      admissionStart,
    );
    expect(admissionStart, greaterThanOrEqualTo(0));
    expect(admissionEnd, greaterThan(admissionStart));

    // 只看代码,不看注释 —— 上面那段注释里就写着这个符号名。
    final admission = source
        .substring(admissionStart, admissionEnd)
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');
    expect(admission, contains('final ticket = _shutterQueue.enqueue('));
    expect(
      admission,
      isNot(contains('_triggerShutterHaptic()')),
      reason: '受理时刻震动会为失败和被拒的照片白震一次',
    );
  });

  test('震动与 AR 相框同时发出 —— 中间不得有 await', () {
    final source = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();

    final execStart = source.indexOf('Future<void> _executeShutterTicket(');
    expect(execStart, greaterThanOrEqualTo(0));
    final hapticAt = source.indexOf('_triggerShutterHaptic()', execStart);
    final cardAt = source.indexOf("'addPhotoCard'", execStart);
    expect(hapticAt, greaterThanOrEqualTo(0), reason: '震动必须在这条路径上');
    expect(cardAt, greaterThan(hapticAt), reason: '震动必须紧挨在挂相框之前');

    final between = source
        .substring(hapticAt, cardAt)
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');
    // 用词边界,不用子串 —— `unawaited(` 里就含 "await" 这四个字母。
    expect(
      RegExp(r'\bawait\b').hasMatch(between),
      isFalse,
      reason: '两者之间一旦出现 await,就不再是「同时」——那是用户定的底线',
    );

    // 且必须在 12MP 事务**之前** —— 卡片锚在调用那一刻的 currentFrame 位姿上,
    // 放到事务之后就等于钉在快门后 317ms(p90 542ms)的位姿,不是拍摄位姿。
    final completionAt = source.indexOf(
      'input = await capture.highResolutionCompletion',
      execStart,
    );
    expect(completionAt, greaterThanOrEqualTo(0));
    expect(hapticAt, lessThan(completionAt), reason: '相框必须钉在拍摄位姿上,不能等事务走完');
    expect(cardAt, lessThan(completionAt));
  });

  test('瞬时快门先挂后验 —— 失败必须摘框,不留鬼框', () {
    final source = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();
    final execStart = source.indexOf('Future<void> _executeShutterTicket(');
    final execEnd = source.indexOf(
      'void _removePhotoCardForEvidence(',
      execStart,
    );
    expect(execEnd, greaterThan(execStart));
    final body = source
        .substring(execStart, execEnd)
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');

    expect(
      body,
      contains('_removePhotoCardForEvidence(capture.evidenceJpegPath)'),
      reason: '卡片在事务确认之前就挂上了,失败路径必须回收它',
    );
    expect(
      '_removePhotoCardForEvidence('.allMatches(body).length,
      greaterThanOrEqualTo(2),
      reason: '异常路径和 _failedEvidenceJpegPaths 路径都要摘',
    );
    expect(body, contains('rethrow;'));
  });

  test('haptic is best effort and manual/auto paths do not duplicate it', () {
    final source = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();

    final helperStart = source.indexOf('void _triggerShutterHaptic()');
    final autoStart = source.indexOf('bool _onAutoCaptureStartAnchor()');
    final manualStart = source.indexOf('void _onShutterTap()');
    final admissionStart = source.indexOf(
      '_ShutterAdmission _admitShutterCapture({bool automaticSelection = false})',
    );
    expect(helperStart, greaterThanOrEqualTo(0));
    expect(autoStart, greaterThanOrEqualTo(0));
    expect(manualStart, greaterThan(autoStart));
    expect(admissionStart, greaterThan(manualStart));

    final helper = source.substring(helperStart, autoStart);
    final autoOuter = source.substring(autoStart, manualStart);
    final manualOuter = source.substring(manualStart, admissionStart);
    expect(helper, contains('HapticFeedback.heavyImpact()'));
    expect(helper, contains('.catchError('));
    expect(helper, contains('DeviceLog.log('));
    expect('HapticFeedback.heavyImpact()'.allMatches(source), hasLength(1));
    expect(source, isNot(contains('HapticFeedback.mediumImpact()')));
    expect(autoOuter, isNot(contains('HapticFeedback.')));
    expect(manualOuter, isNot(contains('HapticFeedback.')));
    expect(source, isNot(contains('SystemSound.play(')));
  });
}
