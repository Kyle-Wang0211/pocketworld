import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 快门反馈(震动 + 黑相框)必须发在**「这一张已经拍下」**那一刻,
/// 不能等我们自己的编码/落盘。
///
/// 三端官方各自有明文规定,措辞几乎一样:
///   iOS       `AVCapturePhotoCaptureDelegate.photoOutput(_:willCapturePhotoFor:)`
///             —— "delivered right when the photo is being taken … if you want to
///                perform a shutter animation, this is the appropriate time to do it";
///                处理完成是另一个更晚的 `didFinishProcessingPhoto`。
///   Android   CameraX `ImageCapture.OnImageCapturedCallback.onCaptureStarted`
///             —— "recommended to play the shutter sound or the shutter animation
///                at this point";底层 Camera2
///                `CameraCaptureSession.CaptureCallback.onCaptureStarted`。
///   HarmonyOS `photoOutput.on('captureStartWithInfo')`(带 captureId),
///             处理完成是另一个 `photoAvailable`。
///
/// 策略只有一份、放在 Dart 里三端共用;各端适配层只负责在自己那个回调上发事件。
/// iOS 走 ARKit `captureHighResolutionFrame`,没有 willCapture 那种更早的挂点,
/// 所以本端绑在 ARFrame 到手那一刻 —— 本端能拿到的最早且诚实的信号。
///
/// 2026-09-07 未命名(25) 实测(n=20):12MP 事务中位 **702 ms**、最长 1567 ms,
/// 而反馈一直等到事务返回 ⇒ 用户报"检测和快门之间还是有零点几秒的延迟"。
/// 队列等待只有 2.89 ms,所以延迟全在这一段。
void main() {
  final page = File('lib/ui/official_capture/ar_capture_page.dart');
  final plugin = File('ios/Runner/OfficialAetherARKitPlugin.swift');

  String stripComments(String src) => src
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//') && !l.trimLeft().startsWith('///'))
      .join('\n');

  test('原生在 ARFrame 到手那一刻发「已经拍下」信号', () {
    expect(plugin.existsSync(), isTrue);
    final swift = stripComments(plugin.readAsStringSync());
    final signal = swift.indexOf('"highResFrameCaptured"');
    final encode = swift.indexOf('jpegEncodeQueue.async', swift.indexOf('captureHighResolutionFrame {'));
    expect(signal, greaterThan(0), reason: '原生没有发「已经拍下」信号');
    expect(
      signal,
      lessThan(encode),
      reason: '信号必须发在 JPEG 编码/落盘**之前** —— 编码是我们自己的处理,'
          '属于三端规矩里 didFinishProcessing 那一半,不该让用户等',
    );
  });

  test('Dart 侧接住信号,并且反馈只有这一个入口', () {
    expect(page.existsSync(), isTrue);
    final code = stripComments(page.readAsStringSync());
    expect(code.contains("setMethodCallHandler(_handleNativeCall)"), isTrue);
    expect(code.contains("'highResFrameCaptured'"), isTrue);
    // 震动只许由 _fireShutterFeedback 发起(它按证据路径去重 ⇒ 每张正好一次)。
    // 只数**调用**,不数声明(`void _triggerShutterHaptic() {`)。
    final hapticCalls =
        RegExp(r'(?<!void )_triggerShutterHaptic\(\);').allMatches(code).length;
    expect(
      hapticCalls,
      1,
      reason: '_triggerShutterHaptic 只能有一个调用点(在 _fireShutterFeedback 里),'
          '否则「震动次数 = 照片数」这条不变量会被绕过;实测 $hapticCalls 处',
    );
  });

  test('反馈不再排在 highResolutionCompletion 的 await 之后', () {
    final code = stripComments(page.readAsStringSync());
    final feedback = code.indexOf('_fireShutterFeedback(');
    final awaitCompletion = code.indexOf('await capture.highResolutionCompletion');
    expect(feedback, greaterThan(0));
    expect(awaitCompletion, greaterThan(0));
    expect(
      feedback,
      lessThan(awaitCompletion),
      reason: '反馈的定义必须在事务 await 之前就可用;await 之后那一处只是兜底',
    );
  });
}
