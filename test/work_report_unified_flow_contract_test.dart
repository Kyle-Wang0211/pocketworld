import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('work detail routes reporting through the unified user report page', () {
    final source = File(
      'lib/ui/community/work_detail_page.dart',
    ).readAsStringSync();

    expect(source, contains("import 'user_report_page.dart';"));
    expect(source, contains('targetUserId: widget.work.userId'));
    expect(source, contains('sourceWorkId: widget.work.id'));
    expect(source, isNot(contains('class _ReportSheet')));
    expect(source, isNot(contains('service.reportWork(')));
  });

  test('production bundle carries the authoritative reporting flow marker', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    expect(
      plist,
      contains('reporting-authoritative-flow-20260906-v1'),
    );
  });
}
