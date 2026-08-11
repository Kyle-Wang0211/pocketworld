// 拍摄退出弹窗(黑白 + 滑轴)。
//
// [2026-08-09 用户签决,附截图] 第一行滑轴:滑块只能停在左右两侧;左(默认)
// = 黑底白字"退出并保存照片",右 = 红底白字"退出并不保存照片";点文字区执行
// 当前动作。第二行"继续拍摄"。点弹窗外自动返回拍摄。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/official_capture/capture_exit_dialog.dart';

Future<CaptureExitChoice?> Function() pumpDialog(WidgetTester tester) {
  CaptureExitChoice? result;
  var closed = false;
  return () async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const ValueKey('open'),
                onPressed: () async {
                  result = await showCaptureExitDialog(ctx);
                  closed = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    return closed ? result : null;
  };
}

Finder get slider => find.byKey(const ValueKey('capture-exit-slider'));

Future<void> slideRight(WidgetTester tester) async {
  final r = tester.getRect(slider);
  await tester.dragFrom(
    Offset(r.left + 30, r.center.dy),
    Offset(r.width - 60, 0),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('默认态:滑块在左,黑底白字"退出并保存照片"', (tester) async {
    final open = pumpDialog(tester);
    await open();
    expect(find.text('退出并保存照片'), findsOneWidget);
    expect(find.text('退出并不保存照片'), findsNothing);
    final track = tester.widget<AnimatedContainer>(
      find
          .descendant(of: slider, matching: find.byType(AnimatedContainer))
          .first,
    );
    expect(
      (track.decoration as BoxDecoration?)?.color,
      Colors.black,
      reason: '默认态轨道必须是黑底(黑白弹窗,红只留给破坏态)',
    );
  });

  testWidgets('点文字区(默认左)⇒ 返回 saveExit', (tester) async {
    CaptureExitChoice? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: ElevatedButton(
              key: const ValueKey('open'),
              onPressed: () async => result = await showCaptureExitDialog(ctx),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    await tester.tap(slider);
    await tester.pumpAndSettle();
    expect(
      result,
      CaptureExitChoice.saveExit,
      reason: '默认(滑块在左)点击文字区应执行"退出并保存照片"',
    );
  });

  testWidgets('滑到右侧 ⇒ 红底 +"退出并不保存照片";再点 ⇒ discardExit', (tester) async {
    CaptureExitChoice? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: ElevatedButton(
              key: const ValueKey('open'),
              onPressed: () async => result = await showCaptureExitDialog(ctx),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    await slideRight(tester);
    expect(find.text('退出并不保存照片'), findsOneWidget);
    final track = tester.widget<AnimatedContainer>(
      find
          .descendant(of: slider, matching: find.byType(AnimatedContainer))
          .first,
    );
    expect(
      (track.decoration as BoxDecoration?)?.color,
      kCaptureExitDangerRed,
      reason: '滑到右侧轨道必须变红(破坏性状态)',
    );
    // 滑动本身不执行 —— 弹窗还在。
    expect(find.byType(CaptureExitDialog), findsOneWidget);

    await tester.tap(slider);
    await tester.pumpAndSettle();
    expect(
      result,
      CaptureExitChoice.discardExit,
      reason: '滑到右侧后点击文字区应执行"退出并不保存照片"',
    );
  });

  testWidgets('滑块只能停在左右两侧:松手在中间偏左 ⇒ 回左', (tester) async {
    final open = pumpDialog(tester);
    await open();
    final r = tester.getRect(slider);
    // 拖到 40% 处松手 ⇒ 吸回左侧,仍显示保存文案。
    await tester.dragFrom(
      Offset(r.left + 30, r.center.dy),
      Offset(r.width * 0.35, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('退出并保存照片'), findsOneWidget);
  });

  testWidgets('"继续拍摄"与点弹窗外 ⇒ 返回 null(回拍摄)', (tester) async {
    CaptureExitChoice? result = CaptureExitChoice.discardExit;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: ElevatedButton(
              key: const ValueKey('open'),
              onPressed: () async => result = await showCaptureExitDialog(ctx),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('capture-exit-continue')));
    await tester.pumpAndSettle();
    expect(result, isNull, reason: '"继续拍摄"应返回 null');

    // 再开一次,点弹窗外(barrier)。
    result = CaptureExitChoice.discardExit;
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(result, isNull, reason: '点弹窗外应自动返回拍摄(null)');
  });
}
