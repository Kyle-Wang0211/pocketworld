import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const migrationPath =
      'supabase/migrations/20260829010000_social_profile_follow_safety.sql';
  late String sql;

  setUpAll(() {
    final file = File(migrationPath);
    expect(file.existsSync(), isTrue, reason: 'social migration must exist');
    sql = file.readAsStringSync().toLowerCase();
  });

  test('follow insert policy rejects blocks in either direction', () {
    expect(sql, contains('drop policy if exists follows_insert_self'));
    expect(sql, contains('create policy follows_insert_self'));
    expect(sql, contains('function app.can_current_user_follow('));
    expect(sql, contains('security definer'));
    expect(sql, contains("set search_path = ''"));
    expect(sql, contains('b.blocker_id = app.current_user_id()'));
    expect(sql, contains('b.blocked_id = p_followee_id'));
    expect(sql, contains('b.blocker_id = p_followee_id'));
    expect(sql, contains('b.blocked_id = app.current_user_id()'));
    expect(sql, contains('(select app.current_user_id()) = follower_id'));
    expect(sql, contains('app.can_current_user_follow(followee_id)'));
    expect(sql, contains('revoke all on function app.can_current_user_follow'));
    expect(
      sql,
      contains('grant execute on function app.can_current_user_follow'),
    );
    expect(sql, isNot(contains('function public.can_current_user_follow')));
  });

  test(
    'follow and block inserts serialize on the same canonical pair lock',
    () {
      expect(sql, contains('function app.lock_social_pair('));
      expect(sql, contains('pg_advisory_xact_lock'));
      expect(sql, contains('least(p_left::text, p_right::text)'));
      expect(sql, contains('greatest(p_left::text, p_right::text)'));
      expect(sql, contains('before insert on public.follows'));
      expect(sql, contains('before insert on public.blocks'));
      expect(sql, contains('social_follow_guard_ins'));
      expect(sql, contains('social_block_lock_ins'));
    },
  );

  test('legacy cleanup is serialized before rows are deleted', () {
    final blocksLock = sql.indexOf('lock table public.blocks');
    final followsLock = sql.indexOf('lock table public.follows');
    final cleanup = sql.indexOf('delete from public.follows f');
    expect(blocksLock, greaterThanOrEqualTo(0));
    expect(followsLock, greaterThan(blocksLock));
    expect(cleanup, greaterThan(followsLock));
  });

  test('table locks execute inside an explicit migration transaction', () {
    final normalized = sql.trim();
    expect(normalized, startsWith('begin;'));
    expect(normalized, endsWith('commit;'));
  });

  test('my following RPC is caller-bound, bounded, and narrowly projected', () {
    expect(sql, contains('function public.get_my_following('));
    expect(sql, contains('security definer'));
    expect(sql, contains("set search_path = ''"));
    expect(sql, contains('v_viewer := app.current_user_id()'));
    expect(sql, contains('least(greatest(p_limit, 1), 1000)'));
    expect(sql, contains('f.follower_id = v_viewer'));
    expect(sql, contains('p.id = f.followee_id'));
    expect(sql, contains(RegExp(r'\(f\.created_at,\s*f\.followee_id\)\s*<')));
    expect(sql, contains('true as is_following'));
    expect(sql, contains('f.created_at as followed_at'));
    expect(sql, contains('revoke all on function public.get_my_following'));
    expect(sql, contains('grant execute on function public.get_my_following'));
  });

  test('profile RPC keeps followed private accounts navigable', () {
    expect(sql, contains('function public.get_social_profile('));
    expect(sql, contains('security definer'));
    expect(sql, contains('p.id = p_user_id'));
    expect(sql, contains('f.follower_id = v_viewer'));
    expect(sql, contains('f.followee_id = p.id'));
    expect(sql, contains('not p.is_private'));
    expect(sql, contains('app.can_current_user_view_account(p.id)'));
    expect(sql, contains('revoke all on function public.get_social_profile'));
    expect(
      sql,
      contains('grant execute on function public.get_social_profile'),
    );
  });

  test('my blocked RPC exposes only caller-owned blocks with known state', () {
    expect(sql, contains('function public.get_my_blocked_users('));
    expect(sql, contains('b.blocker_id = v_viewer'));
    expect(sql, contains('p.id = b.blocked_id'));
    expect(sql, contains('true as is_blocked_by_viewer'));
    expect(sql, contains('b.created_at as blocked_at'));
    expect(sql, contains('revoke all on function public.get_my_blocked_users'));
    expect(
      sql,
      contains('grant execute on function public.get_my_blocked_users'),
    );
  });

  test(
    'blocked accounts are suppressed bilaterally without a block-list oracle',
    () {
      expect(sql, contains('function app.can_current_user_view_account('));
      expect(sql, contains('b.blocker_id = app.current_user_id()'));
      expect(sql, contains('b.blocked_id = p_user_id'));
      expect(sql, contains('b.blocker_id = p_user_id'));
      expect(sql, contains('b.blocked_id = app.current_user_id()'));
      expect(sql, contains('app.can_current_user_view_account(id)'));
      expect(sql, contains('app.can_current_user_view_account(user_id)'));
      expect(sql, isNot(contains('get_my_socially_hidden_user_ids')));
    },
  );

  test('works count uses the exact public-visible predicate', () {
    for (final qualifier in ['old.', 'new.', 'w.']) {
      expect(sql, contains('${qualifier}published_at is not null'));
      expect(sql, contains("${qualifier}visibility = 'public'"));
      expect(sql, contains("${qualifier}moderation_status = 'ok'"));
      expect(sql, contains('${qualifier}deleted_at is null'));
    }
    expect(
      sql,
      contains('create or replace function public.bump_profile_works_count()'),
    );
    expect(sql, contains("if tg_op <> 'insert'"));
    expect(sql, contains("if tg_op <> 'delete'"));
    expect(sql, contains('old.user_id = new.user_id'));
    expect(sql, contains('new_counted::integer - old_counted::integer'));
    expect(
      sql,
      contains(
        'after update of user_id, published_at, visibility, moderation_status, deleted_at',
      ),
    );
  });

  test('migration locks writes and backfills every profile from works', () {
    expect(sql, contains('lock table public.works'));
    expect(sql, contains('update public.profiles p'));
    expect(sql, contains('select w.user_id, count(*)::integer as works_count'));
    expect(sql, contains('coalesce(c.works_count, 0)'));
  });
}
