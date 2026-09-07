import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String console;
  late String endpoint;

  setUpAll(() {
    console = File('tool/moderation_console.html').readAsStringSync();
    endpoint = File(
      'supabase/functions/admin-reports/index.ts',
    ).readAsStringSync();
  });

  test(
    'console uses an ordinary moderator session and never asks for service role',
    () {
      expect(console, contains('/auth/v1/token?grant_type=password'));
      expect(console, contains('pw_moderator_token'));
      expect(console, contains("action:'whoami'"));
      expect(console, isNot(contains('pw_secret')));
      expect(console, isNot(contains('service secret')));
      expect(console, isNot(contains('service_role')));
      expect(console, isNot(contains('.innerHTML')));
    },
  );

  test('endpoint enforces role, claim, feedback, and an event trail', () {
    expect(endpoint, contains('authenticateModerator'));
    expect(endpoint, contains('insufficient_moderator_role'));
    expect(endpoint, contains('claimed_by'));
    expect(endpoint, contains('reporter_feedback_required'));
    expect(endpoint, contains('report_moderation_events'));
    expect(endpoint, contains('priority'));
    expect(endpoint, contains('due_at'));
  });
}
