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

  // 2026-09-08 契约**搬家(不是放宽)**:「照片确认存在」的锚点从
  // 「我们的 12MP 事务返回」换成「平台报告这一张已经拍下」。
  //
  // 起因:未命名(25) 实测事务中位 702 ms、最长 1567 ms,而队列等待只有
  // 2.89 ms —— 用户报"检测和快门之间还是有零点几秒的延迟"。原来把反馈压到
  // 事务返回,是在等我们自己的 JPEG 编码/落盘/派生灰度,不是在等照片存在。
  //
  // 三端官方对这件事各自有明文规定,措辞几乎一样,都要求发在「拍下」那一刻:
  //   iOS       willCapturePhotoFor(处理完成是另一个 didFinishProcessingPhoto)
  //   Android   CameraX onCaptureStarted / Camera2 CaptureCallback.onCaptureStarted
  //   HarmonyOS photoOutput.on('captureStartWithInfo')(处理完成是 photoAvailable)
  //
  // 底线一个字没松:反馈仍然只在照片**物理上已经存在**之后发(ARFrame 到手),
  // 仍然震一次 = 真有一张(按证据路径去重),两者之间仍然不隔任何 await。
  test('震动与 AR 相框同时发出 —— 中间不得有 await', () {
    final source = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();

    // 反馈现在只有一个入口:_fireShutterFeedback。
    final fnStart = source.indexOf('  void _fireShutterFeedback({');
    expect(fnStart, greaterThanOrEqualTo(0), reason: '反馈入口不存在了');
    final fnEnd = source.indexOf('\n  }\n', fnStart);
    final body = source.substring(fnStart, fnEnd);

    final hapticAt = body.indexOf('_triggerShutterHaptic()');
    final cardAt = body.indexOf("'addPhotoCard'");
    expect(hapticAt, greaterThanOrEqualTo(0), reason: '震动必须在这条路径上');
    expect(cardAt, greaterThan(hapticAt), reason: '震动必须紧挨在挂相框之前');

    final between = body
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
  });

  test('反馈只能由「照片已经存在」的两个来源触发,别处一律不许发', () {
    final source = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();
    final code = source
        .split('\n')
        .where((l) =>
            !l.trimLeft().startsWith('//') && !l.trimLeft().startsWith('///'))
        .join('\n');

    // 唯一的震动调用点在 _fireShutterFeedback 里(声明不算)。
    expect(
      RegExp(r'(?<!void )_triggerShutterHaptic\(\);').allMatches(code),
      hasLength(1),
      reason: '多一个调用点,「震动次数 = 照片数」这条不变量就被绕过了',
    );

    // 去重:同一张照片只反馈一次。
    expect(
      code.contains('_feedbackFiredEvidencePaths.add('),
      isTrue,
      reason: '没有去重的话,早信号 + 兜底会震两次',
    );

    // 两个来源,一个都不能少、一个都不能多。
    final sources = RegExp(r"source: '([a-z_]+)'").allMatches(code)
        .map((m) => m.group(1)!)
        .toSet();
    expect(
      sources,
      {'captured_signal', 'transaction_complete_fallback'},
      reason: '反馈来源只许是「原生说已经拍下」与「事务返回兜底」,'
          '两者都在照片物理存在之后;实测来源集合 = $sources',
    );
  });

  test('haptic is best effort and manual/auto paths do not duplicate it', () {
    final source = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();

    // [2026-09-11] 本 route 现在有**两个**震动事件,各自一个具名 helper:
    //   · _triggerShutterHaptic    —— 平台说"已经拍下"那一刻
    //   · _triggerCompletionHaptic —— 重建到终态那一刻(用户 09-10 令)
    // 本条契约要挡的从来不是"只许震一种事",而是**手动/自动两条快门路径各喊
    // 一次**。所以判据从"全文只许出现 1 次 heavyImpact"收紧成"每个具名
    // helper 里恰好 1 次、全文恰好 2 次、两条快门路径自己一次都不喊"。
    final completionStart = source.indexOf('void _triggerCompletionHaptic()');
    expect(completionStart, greaterThanOrEqualTo(0));
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

    expect(
      helperStart,
      greaterThan(completionStart),
      reason: '两个 helper 相邻,顺序变了下面的切片就切错了',
    );
    final completionHelper = source.substring(completionStart, helperStart);
    final helper = source.substring(helperStart, autoStart);
    final autoOuter = source.substring(autoStart, manualStart);
    final manualOuter = source.substring(manualStart, admissionStart);
    expect(helper, contains('HapticFeedback.heavyImpact()'));
    expect(helper, contains('.catchError('));
    expect(helper, contains('DeviceLog.log('));
    expect(
      'HapticFeedback.heavyImpact()'.allMatches(completionHelper),
      hasLength(1),
      reason: '完成震动也必须收在自己的 helper 里,与快门同一种强度',
    );
    expect(
      'HapticFeedback.heavyImpact()'.allMatches(helper),
      hasLength(1),
    );
    expect(
      'HapticFeedback.heavyImpact()'.allMatches(source),
      hasLength(2),
      reason: '只许这两个 helper 各一次 —— 多出来的就是散落的临时调用',
    );
    expect(source, isNot(contains('HapticFeedback.mediumImpact()')));
    expect(autoOuter, isNot(contains('HapticFeedback.')));
    expect(manualOuter, isNot(contains('HapticFeedback.')));
    expect(source, isNot(contains('SystemSound.play(')));
  });
}
