import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String migration;
  late String uploadFunction;
  late String submitFunction;
  late String adminFunction;
  late String deleteAccountFunction;
  late String deleteWorkFunction;

  setUpAll(() {
    migration = File(
      'supabase/migrations/20260829020000_user_report_evidence.sql',
    ).readAsStringSync();
    uploadFunction = File(
      'supabase/functions/report-evidence-upload/index.ts',
    ).readAsStringSync();
    submitFunction = File(
      'supabase/functions/submit-user-report/index.ts',
    ).readAsStringSync();
    adminFunction = File(
      'supabase/functions/admin-reports/index.ts',
    ).readAsStringSync();
    deleteAccountFunction = File(
      'supabase/functions/delete-account/index.ts',
    ).readAsStringSync();
    deleteWorkFunction = File(
      'supabase/functions/delete-work/index.ts',
    ).readAsStringSync();
  });

  test('migration aligns all nine stable reason codes and source work', () {
    for (final code in const [
      'impersonation',
      'harassment_threat',
      'spam_fraud',
      'minor_safety',
      'sexual_content',
      'violence_illegal',
      'misinformation',
      'privacy_ip',
      'other',
    ]) {
      expect(migration, contains("'$code'"));
    }
    expect(migration, contains('source_work_id uuid'));
    expect(migration, contains('source_work_snapshot jsonb'));
    expect(migration, contains('report_source_assets'));
    expect(migration, contains('references public.works(id)'));
    expect(
      migration,
      contains("target_type <> 'user' or target_id <> reporter_id"),
    );
    expect(migration, contains('normalize_legacy_report_reason'));
    expect(migration, contains("when 'spam' then 'spam_fraud'"));
    expect(migration, contains("when 'harassment' then 'harassment_threat'"));
    expect(migration, contains("when 'copyright' then 'privacy_ip'"));
    expect(migration, contains('reject_self_user_report'));
    expect(
      migration,
      contains('update of reporter_id, target_type, target_id'),
    );
    expect(migration, contains('enforce_user_report_source_work'));
    expect(migration.toLowerCase(), contains('w.user_id <> new.target_id'));
  });

  test(
    'report table lock executes inside an explicit migration transaction',
    () {
      final normalized = migration.trim().toLowerCase();
      expect(normalized, startsWith('begin;'));
      expect(normalized, endsWith('commit;'));
    },
  );

  test('sensitive preservation and author deletion share an atomic claim', () {
    expect(migration, contains('work_deletion_claims'));
    expect(migration, contains('function public.claim_work_deletion'));
    expect(migration, contains('for key share'));
    expect(migration, contains('guard_work_delete_for_report_preservation'));
    expect(deleteWorkFunction, contains('"claim_work_deletion"'));
    expect(deleteWorkFunction, contains('"work_preservation_in_progress"'));
    expect(
      migration,
      contains('function public.claim_account_content_deletion'),
    );
    expect(deleteAccountFunction, contains('"claim_account_content_deletion"'));
    expect(
      deleteAccountFunction,
      contains('"safety_preservation_in_progress"'),
    );
    expect(migration, contains('r.source_work_id is not null'));
    expect(deleteAccountFunction, contains('retryPendingSourcePreservation'));
    expect(deleteAccountFunction, contains('report_source_assets'));
    expect(migration, contains("'released'"));
    expect(migration, contains('preservation_attempts'));
    expect(
      migration,
      contains('function public.claim_report_preservation_retry'),
    );
    expect(migration, contains('preservation_lease_until'));
    expect(
      deleteAccountFunction,
      contains('"claim_report_preservation_retry"'),
    );
    expect(migration, contains('drop policy if exists "works_delete_self"'));
    expect(
      migration,
      contains('drop policy if exists "thumbnails_delete_self"'),
    );
    expect(migration, contains('works_no_client_delete'));
    expect(migration, contains('thumbnails_no_client_delete'));
    expect(
      deleteAccountFunction,
      contains('report.preservation_released_for_erasure'),
    );
  });

  test('account deletion sweeps private report evidence before cascade', () {
    expect(deleteAccountFunction, contains('"report-evidence"'));
    expect(deleteAccountFunction, contains('USER_PREFIXED_BUCKETS'));
  });

  test('evidence storage is private, server-owned, and capped at three', () {
    expect(migration, contains("'report-evidence'"));
    expect(migration, contains('public, file_size_limit, allowed_mime_types'));
    expect(migration, contains('false, 5242880'));
    expect(migration, contains('ordinal smallint'));
    expect(migration, contains('check (ordinal between 0 and 2)'));
    expect(migration, contains('unique (report_id, ordinal)'));
    expect(migration, contains('enable row level security'));
    expect(migration, isNot(contains('report_evidence_insert')));
  });

  test('upload endpoint binds evidence to the authenticated reporter', () {
    expect(uploadFunction, contains('admin.auth.getUser'));
    expect(uploadFunction, contains('.eq("reporter_id", user.id)'));
    expect(uploadFunction, contains('.eq("target_type", "user")'));
    expect(uploadFunction, contains('.eq("status", "pending")'));
    expect(uploadFunction, contains('"minor_safety"'));
    expect(uploadFunction, contains('"sexual_content"'));
    expect(uploadFunction, contains('evidence_not_allowed'));
    expect(uploadFunction, contains('crypto.randomUUID()'));
    expect(uploadFunction, isNot(contains('original_filename')));
  });

  test(
    'user report endpoint validates source ownership and preserves sensitive content',
    () {
      expect(submitFunction, contains('admin.auth.getUser'));
      expect(submitFunction, contains('.eq("user_id", targetUserId)'));
      expect(submitFunction, contains('source_work_mismatch'));
      expect(submitFunction, contains('report-source-evidence'));
      expect(submitFunction, contains('.copy('));
      expect(submitFunction, contains('destinationBucket: SOURCE_BUCKET'));
      expect(submitFunction, contains('report_source_assets'));
      expect(submitFunction, contains('preservation_state'));
    },
  );

  test('admin list attaches short-lived private evidence links', () {
    expect(adminFunction, contains('.from("report_evidence")'));
    expect(adminFunction, contains('requestPath("report-evidence"'));
    expect(adminFunction, contains('300'));
    expect(adminFunction, contains('source_work_id'));
    expect(adminFunction, contains('report_source_assets'));
    expect(adminFunction, contains('createSignedUrls'));
  });
}
