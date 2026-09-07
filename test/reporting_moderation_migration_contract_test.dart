import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const path =
      'supabase/migrations/20260906010000_complete_reporting_moderation_loop.sql';

  test('migration defines two tiers and server-owned limits', () {
    final sql = File(path).readAsStringSync();
    expect(sql.trim().toLowerCase(), startsWith('begin;'));
    expect(sql.trim().toLowerCase(), endsWith('commit;'));
    expect(sql, contains("kind text not null default 'standard'"));
    expect(sql, contains("kind in ('standard', 'rights')"));
    expect(
      sql,
      contains("NEW.kind = 'standard' and char_length(NEW.detail) > 50"),
    );
    expect(
      sql,
      contains("NEW.kind = 'rights' and char_length(NEW.detail) > 500"),
    );
    expect(sql, contains("NEW.reason in ('impersonation', 'privacy_ip')"));
  });

  test(
    'migration rejects self work reports and validates source ownership',
    () {
      final sql = File(path).readAsStringSync();
      expect(sql, contains('reject_self_or_mismatched_report'));
      expect(sql, contains('w.user_id = NEW.reporter_id'));
      expect(sql, contains('w.user_id <> NEW.target_id'));
      expect(sql, contains('source work does not belong to reported user'));
    },
  );

  test('priority and due time are deterministic server fields', () {
    final sql = File(path).readAsStringSync();
    expect(sql, contains('priority smallint'));
    expect(sql, contains('due_at timestamptz'));
    expect(sql, contains("when 'minor_safety' then 100"));
    expect(sql, contains("when 'sexual_content' then 80"));
    expect(sql, contains("interval '24 hours'"));
    expect(sql, contains('priority desc, due_at asc, created_at asc'));
  });

  test('reporter history is a narrow security-definer projection', () {
    final sql = File(path).readAsStringSync();
    expect(sql, contains('function public.get_my_reports'));
    expect(sql, contains('security definer'));
    expect(sql, contains('reporter_feedback'));
    expect(sql, isNot(contains('returns table(admin_notes')));
    expect(sql, contains('grant execute on function public.get_my_reports'));
  });

  test('moderator roles and typed evidence are private', () {
    final sql = File(path).readAsStringSync();
    expect(
      sql,
      contains('create table if not exists public.moderator_accounts'),
    );
    expect(sql, contains("role in ('reviewer', 'lead')"));
    expect(sql, contains('revoke all on public.moderator_accounts'));
    expect(sql, contains('evidence_kind text'));
    expect(sql, contains("'identity', 'ownership', 'authorization'"));
    expect(sql, contains('idx_reports_moderation_queue'));
    expect(sql, contains('idx_reports_duplicate_window'));
  });

  test(
    'legacy installed work-report clients remain temporarily compatible',
    () {
      final sql = File(path).readAsStringSync();
      expect(sql, contains('create policy reports_insert_legacy_work'));
      expect(sql, contains("target_type = 'work'"));
      expect(sql, contains('app.current_user_id() = reporter_id'));
    },
  );
}
