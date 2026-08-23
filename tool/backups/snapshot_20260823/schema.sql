


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "app";


ALTER SCHEMA "app" OWNER TO "postgres";


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "app"."assert_staging_private"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'storage', 'public', 'pg_temp'
    AS $$
begin
  if new.id in ('staging', 'quarantine') and new.public then
    raise exception
      '% 桶必须保持私有:它存放未经校验/已下架的内容,'
      '公开桶会绕过 RLS 使其可被任意下载', new.id;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "app"."assert_staging_private"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "app"."current_user_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  -- 迁移到非 Supabase 后端时,**只需要改这一行**。
  -- 例如自建 JWT 网关:
  --   select nullif(current_setting('request.jwt.claims', true)::jsonb->>'sub','')::uuid
  select auth.uid()
$$;


ALTER FUNCTION "app"."current_user_id"() OWNER TO "postgres";


COMMENT ON FUNCTION "app"."current_user_id"() IS 'Portable indirection over the auth backend. RLS policies must call this, never auth.uid() directly — swapping backends should touch only this function body.';



CREATE OR REPLACE FUNCTION "app"."purge_stale_staging"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'storage', 'public', 'pg_temp'
    AS $$
declare
  v_count integer;
begin
  -- 只删元数据行会在 S3 留下孤儿文件(官方明确:删对象应走 Storage API,
  -- 不要用 SQL)。所以这里**不删**,只把待清理的挑出来交给 Edge Function,
  -- 由它用 Storage API 真正删除。这个函数只负责回答"哪些该删"。
  select count(*) into v_count
  from storage.objects
  where bucket_id = 'staging'
    and created_at < now() - interval '24 hours';
  return v_count;
end;
$$;


ALTER FUNCTION "app"."purge_stale_staging"() OWNER TO "postgres";


COMMENT ON FUNCTION "app"."purge_stale_staging"() IS '返回超过 24h 未被提升的 staging 对象数量。刻意不做删除 —— 用 SQL 删 storage.objects 只会摘掉元数据行并在 S3 留下孤儿文件(Supabase 官方口径:删除对象必须走 Storage API)。真正的删除由 Edge Function 执行。';


SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "app"."switches" (
    "key" "text" NOT NULL,
    "enabled" boolean DEFAULT true NOT NULL,
    "reason" "text",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_by" "text"
);


ALTER TABLE "app"."switches" OWNER TO "postgres";


COMMENT ON TABLE "app"."switches" IS '紧急止血阀。enabled=false 即关闭对应能力。只有 service_role 可写 —— 客户端连读都不需要,策略通过 SECURITY DEFINER 函数读取。';



CREATE OR REPLACE FUNCTION "app"."set_switch"("p_key" "text", "p_enabled" boolean, "p_reason" "text" DEFAULT NULL::"text", "p_by" "text" DEFAULT NULL::"text") RETURNS "app"."switches"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'app', 'public', 'pg_temp'
    AS $$
declare
  v_row app.switches;
begin
  if current_user <> 'service_role' then
    raise exception 'set_switch requires service_role';
  end if;

  insert into app.switches (key, enabled, reason, updated_at, updated_by)
  values (p_key, p_enabled, p_reason, now(), p_by)
  on conflict (key) do update
    set enabled    = excluded.enabled,
        reason     = coalesce(excluded.reason, app.switches.reason),
        updated_at = now(),
        updated_by = excluded.updated_by
  returning * into v_row;

  -- 按下止血阀本身必须留痕 —— 事后要能回答"谁在什么时候关的、为什么"。
  insert into public.audit_logs (actor_id, action, target_type, target_id, metadata)
  values (
    null,
    case when p_enabled then 'admin.switch_enabled' else 'admin.switch_disabled' end,
    'switch',
    null,
    jsonb_build_object('key', p_key, 'enabled', p_enabled,
                       'reason', p_reason, 'by', p_by)
  );

  return v_row;
end;
$$;


ALTER FUNCTION "app"."set_switch"("p_key" "text", "p_enabled" boolean, "p_reason" "text", "p_by" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "app"."switch_on"("p_key" "text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'app', 'public', 'pg_temp'
    AS $$
  select coalesce((select s.enabled from app.switches s where s.key = p_key), true);
$$;


ALTER FUNCTION "app"."switch_on"("p_key" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_set_work_moderation"("p_work_id" "uuid", "p_status" "text", "p_reason" "text" DEFAULT NULL::"text", "p_actor" "uuid" DEFAULT NULL::"uuid", "p_operator" "text" DEFAULT NULL::"text", "p_ip" "text" DEFAULT NULL::"text", "p_user_agent" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_ip inet;
begin
  if p_status not in ('ok', 'under_review', 'removed') then
    raise exception 'invalid moderation status: %', p_status;
  end if;

  -- x-forwarded-for can carry a list, and a malformed value must not take
  -- the whole takedown down with it — attribution is strictly less
  -- important than the action succeeding.
  begin
    v_ip := split_part(coalesce(p_ip, ''), ',', 1)::inet;
  exception when others then
    v_ip := null;
  end;

  update public.works
     set moderation_status = p_status,
         deleted_at = case
           when p_status = 'removed' then coalesce(deleted_at, now())
           else null
         end
   where id = p_work_id;
  if not found then
    raise exception 'work % not found', p_work_id;
  end if;

  insert into public.audit_logs (
    actor_id, action, target_type, target_id, metadata, ip_address, user_agent
  )
  values (
    p_actor,
    'admin.work_moderation_set',
    'work',
    p_work_id,
    jsonb_build_object(
      'status', p_status,
      'reason', p_reason,
      -- Self-declared; see the honest-limitation note above.
      'operator', p_operator,
      'actor_kind', case when p_actor is null then 'service_role' else 'user' end
    ),
    v_ip,
    left(coalesce(p_user_agent, ''), 500)
  );
end;
$$;


ALTER FUNCTION "public"."admin_set_work_moderation"("p_work_id" "uuid", "p_status" "text", "p_reason" "text", "p_actor" "uuid", "p_operator" "text", "p_ip" "text", "p_user_agent" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."admin_set_work_moderation"("p_work_id" "uuid", "p_status" "text", "p_reason" "text", "p_actor" "uuid", "p_operator" "text", "p_ip" "text", "p_user_agent" "text") IS 'Admin takedown/restore for a work. service_role only; audit-logged with IP/UA. p_operator is self-declared and not non-repudiable.';



CREATE OR REPLACE FUNCTION "public"."bump_collection_works_count"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  if (TG_OP = 'INSERT') then
    update public.collections set works_count = works_count + 1
     where id = NEW.collection_id;
  elsif (TG_OP = 'DELETE') then
    update public.collections set works_count = greatest(0, works_count - 1)
     where id = OLD.collection_id;
  end if;
  return null;
end;
$$;


ALTER FUNCTION "public"."bump_collection_works_count"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bump_comment_likes_count"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  if (TG_OP = 'INSERT') then
    update public.comments set likes_count = likes_count + 1 where id = NEW.comment_id;
  elsif (TG_OP = 'DELETE') then
    update public.comments set likes_count = greatest(0, likes_count - 1) where id = OLD.comment_id;
  end if;
  return null;
end;
$$;


ALTER FUNCTION "public"."bump_comment_likes_count"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bump_profile_follow_counts"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  if (TG_OP = 'INSERT') then
    update public.profiles set followers_count = followers_count + 1 where id = NEW.followee_id;
    update public.profiles set following_count = following_count + 1 where id = NEW.follower_id;
  elsif (TG_OP = 'DELETE') then
    update public.profiles set followers_count = greatest(0, followers_count - 1) where id = OLD.followee_id;
    update public.profiles set following_count = greatest(0, following_count - 1) where id = OLD.follower_id;
  end if;
  return null;
end;
$$;


ALTER FUNCTION "public"."bump_profile_follow_counts"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bump_profile_works_count"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  if (TG_OP = 'INSERT') then
    update public.profiles
       set works_count = works_count + 1
     where id = NEW.user_id;
  elsif (TG_OP = 'DELETE') then
    update public.profiles
       set works_count = greatest(0, works_count - 1)
     where id = OLD.user_id;
  end if;
  return null;
end;
$$;


ALTER FUNCTION "public"."bump_profile_works_count"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bump_tag_works_count"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  if (TG_OP = 'INSERT') then
    update public.tags set works_count = works_count + 1 where id = NEW.tag_id;
  elsif (TG_OP = 'DELETE') then
    update public.tags set works_count = greatest(0, works_count - 1) where id = OLD.tag_id;
  end if;
  return null;
end;
$$;


ALTER FUNCTION "public"."bump_tag_works_count"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bump_work_bookmarks_count"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  if (TG_OP = 'INSERT') then
    update public.works set bookmarks_count = bookmarks_count + 1 where id = NEW.work_id;
  elsif (TG_OP = 'DELETE') then
    update public.works set bookmarks_count = greatest(0, bookmarks_count - 1) where id = OLD.work_id;
  end if;
  return null;
end;
$$;


ALTER FUNCTION "public"."bump_work_bookmarks_count"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bump_work_comments_count"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  if (TG_OP = 'INSERT') then
    update public.works
       set comments_count = comments_count + 1
     where id = NEW.work_id;
  elsif (TG_OP = 'DELETE') then
    update public.works
       set comments_count = greatest(0, comments_count - 1)
     where id = OLD.work_id;
  end if;
  return null;
end;
$$;


ALTER FUNCTION "public"."bump_work_comments_count"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bump_work_likes_count"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  if (TG_OP = 'INSERT') then
    update public.works set likes_count = likes_count + 1 where id = NEW.work_id;
  elsif (TG_OP = 'DELETE') then
    update public.works set likes_count = greatest(0, likes_count - 1) where id = OLD.work_id;
  end if;
  return null;
end;
$$;


ALTER FUNCTION "public"."bump_work_likes_count"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bump_work_views_count"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  update public.works set views_count = views_count + 1 where id = NEW.work_id;
  return null;
end;
$$;


ALTER FUNCTION "public"."bump_work_views_count"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cascade_block_unfollow"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  delete from public.follows
   where (follower_id = NEW.blocker_id and followee_id = NEW.blocked_id)
      or (follower_id = NEW.blocked_id and followee_id = NEW.blocker_id);
  return null;
end;
$$;


ALTER FUNCTION "public"."cascade_block_unfollow"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."consume_rate_limit"("p_key" "text", "p_limit" integer, "p_window_seconds" integer) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_hits int;
begin
  insert into public.edge_rate_limits as e (bucket_key, window_start, hit_count)
  values (p_key, now(), 1)
  on conflict (bucket_key) do update
    set hit_count = case
          when e.window_start < now() - make_interval(secs => p_window_seconds)
            then 1
          else e.hit_count + 1
        end,
        window_start = case
          when e.window_start < now() - make_interval(secs => p_window_seconds)
            then now()
          else e.window_start
        end
  returning e.hit_count into v_hits;

  return v_hits <= p_limit;
end;
$$;


ALTER FUNCTION "public"."consume_rate_limit"("p_key" "text", "p_limit" integer, "p_window_seconds" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."consume_rate_limit"("p_key" "text", "p_limit" integer, "p_window_seconds" integer) IS 'Fixed-window rate limiter. Returns true if the call is allowed. service_role only.';



CREATE OR REPLACE FUNCTION "public"."consume_reset_otp_attempt"("p_email" "text", "p_max_attempts" integer DEFAULT 5) RETURNS TABLE("status" "text", "otp_hash" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_row public.pending_password_resets%rowtype;
begin
  update public.pending_password_resets r
     set attempts = r.attempts + 1
   where r.email = p_email
     and r.attempts < p_max_attempts
     and r.expires_at > now()
  returning r.* into v_row;

  if found then
    return query select 'ok'::text, v_row.otp_hash;
    return;
  end if;

  -- Alias-qualified: the otp_hash output name shadows the column name.
  select r2.* into v_row from public.pending_password_resets r2
   where r2.email = p_email;
  if not found then
    return query select 'not_found'::text, null::text;
  elsif v_row.expires_at <= now() then
    return query select 'expired'::text, null::text;
  else
    return query select 'too_many_attempts'::text, null::text;
  end if;
end;
$$;


ALTER FUNCTION "public"."consume_reset_otp_attempt"("p_email" "text", "p_max_attempts" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."consume_reset_otp_attempt"("p_email" "text", "p_max_attempts" integer) IS 'Atomically consumes one password-reset OTP attempt. service_role only — returns the OTP hash.';



CREATE OR REPLACE FUNCTION "public"."consume_signup_otp_attempt"("p_email" "text", "p_max_attempts" integer DEFAULT 5) RETURNS TABLE("status" "text", "otp_hash" "text", "password" "text", "display_name" "text", "locale" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_row public.pending_signups%rowtype;
begin
  -- Single atomic statement: test the cap and consume in one shot.
  update public.pending_signups s
     set attempts = s.attempts + 1
   where s.email = p_email
     and s.attempts < p_max_attempts
     and s.expires_at > now()
  returning s.* into v_row;

  if found then
    return query select 'ok'::text, v_row.otp_hash, v_row.password,
                        v_row.display_name, v_row.locale;
    return;
  end if;

  -- The UPDATE matched nothing. Work out why, for an accurate status.
  -- Every column reference is alias-qualified on purpose: this function's
  -- RETURNS TABLE output names (otp_hash, password, display_name, locale)
  -- are plpgsql variables that collide with the table's column names, and
  -- an unqualified reference would be rejected as ambiguous.
  select s2.* into v_row from public.pending_signups s2 where s2.email = p_email;
  if not found then
    return query select 'not_found'::text, null::text, null::text,
                        null::text, null::text;
  elsif v_row.expires_at <= now() then
    return query select 'expired'::text, null::text, null::text,
                        null::text, null::text;
  else
    return query select 'too_many_attempts'::text, null::text, null::text,
                        null::text, null::text;
  end if;
end;
$$;


ALTER FUNCTION "public"."consume_signup_otp_attempt"("p_email" "text", "p_max_attempts" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."consume_signup_otp_attempt"("p_email" "text", "p_max_attempts" integer) IS 'Atomically consumes one signup OTP attempt. service_role only — returns the OTP hash and pending plaintext password.';



CREATE OR REPLACE FUNCTION "public"."guard_profile_identity_columns"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
begin
  if (new.display_name is distinct from old.display_name
      or new.handle is distinct from old.handle
      or new.handle_key is distinct from old.handle_key
      or new.bio is distinct from old.bio
      or new.display_name_changed_at is distinct from old.display_name_changed_at
      or new.handle_changed_at is distinct from old.handle_changed_at)
     and current_user in ('anon', 'authenticated') then  -- [PORTABLE]
    raise exception 'display_name / handle / bio are managed by the set-profile-name function'
      using errcode = '42501';  -- insufficient_privilege
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."guard_profile_identity_columns"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."guard_quarantine_stays_private"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  if new.id = 'quarantine' and new.public is true then
    raise exception
      'refusing to make the quarantine bucket public: it holds taken-down content kept as evidence'
      using errcode = '42501';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."guard_quarantine_stays_private"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."guard_work_content_columns"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
begin
  if (new.title is distinct from old.title
      or new.description is distinct from old.description
      or new.visibility is distinct from old.visibility
      or new.published_at is distinct from old.published_at
      or new.model_storage_path is distinct from old.model_storage_path
      or new.file_size_bytes is distinct from old.file_size_bytes
      or new.format is distinct from old.format
      or new.user_id is distinct from old.user_id)
     and current_user in ('anon', 'authenticated') then  -- [PORTABLE]
    raise exception 'work content fields are managed by the upload-finalize function'
      using errcode = '42501';  -- insufficient_privilege
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."guard_work_content_columns"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."guard_work_moderation_columns"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
begin
  if (new.moderation_status is distinct from old.moderation_status
      or new.deleted_at is distinct from old.deleted_at)
     and current_user in ('anon', 'authenticated') then  -- [PORTABLE]
    raise exception 'moderation fields are admin-managed'
      using errcode = '42501';  -- insufficient_privilege
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."guard_work_moderation_columns"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."guard_work_moderation_delete"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
begin
  if (old.moderation_status is distinct from 'ok' or old.deleted_at is not null)
     and current_user in ('anon', 'authenticated')  -- [PORTABLE]
     and not (old.moderation_status = 'under_review' and old.published_at is null)
  then
    raise exception 'moderated works cannot be deleted'
      using errcode = '42501';
  end if;
  return old;
end;
$$;


ALTER FUNCTION "public"."guard_work_moderation_delete"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    coalesce(
      nullif(new.raw_user_meta_data->>'display_name', ''),
      split_part(new.email, '@', 1)
    )
  )
  on conflict (id) do nothing;

  insert into public.notification_settings (user_id)
  values (new.id)
  on conflict (user_id) do nothing;

  return new;
end;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."purge_expired_audit_logs"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_deleted integer;
begin
  delete from public.audit_logs
  where created_at <
        now() - (case
          when action like 'admin.%'
            or action in ('user.account_deleted', 'work.deleted_by_author')
          then interval '730 days'
          else interval '180 days'
        end);
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;


ALTER FUNCTION "public"."purge_expired_audit_logs"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."record_work_view"("p_work_id" "uuid") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_views integer;
begin
  -- Only count views on works the caller could actually open. Mirrors
  -- works_select_visible (public + clean moderation, or owner).
  if not exists (
    select 1 from public.works w
    where w.id = p_work_id
      and w.published_at is not null
      and (
        (w.visibility = 'public'
         and w.moderation_status = 'ok'
         and w.deleted_at is null)
        or w.user_id = auth.uid()  -- [PORTABLE]
      )
  ) then
    return null;
  end if;

  insert into public.work_views (work_id, viewer_id, view_bucket)
  values (p_work_id, auth.uid(), date_trunc('hour', now()))
  on conflict do nothing;

  select views_count into v_views from public.works where id = p_work_id;
  return v_views;
end;
$$;


ALTER FUNCTION "public"."record_work_view"("p_work_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."record_work_view"("p_work_id" "uuid") IS 'Deduped view bump for a work; the only writer of work_views. Returns fresh views_count, or null when the work is not visible to the caller.';



CREATE OR REPLACE FUNCTION "public"."rls_auto_enable"() RETURNS "event_trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."rls_auto_enable"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at = now();
  return new;
end;
$$;


ALTER FUNCTION "public"."set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."touch_conversation_last_message"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  update public.conversations
     set last_message_at = NEW.created_at
   where id = NEW.conversation_id;
  return null;
end;
$$;


ALTER FUNCTION "public"."touch_conversation_last_message"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."uploads_enabled"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$ select app.switch_on('uploads') $$;


ALTER FUNCTION "public"."uploads_enabled"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."audit_logs" (
    "id" bigint NOT NULL,
    "actor_id" "uuid",
    "action" "text" NOT NULL,
    "target_type" "text",
    "target_id" "uuid",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "ip_address" "inet",
    "user_agent" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "audit_logs_action_check" CHECK (("char_length"("action") <= 80)),
    CONSTRAINT "audit_logs_target_type_check" CHECK (("target_type" = ANY (ARRAY['user'::"text", 'work'::"text", 'comment'::"text", 'project'::"text", 'report'::"text", 'system'::"text", 'scan'::"text", 'storage'::"text", 'worker'::"text"])))
);


ALTER TABLE "public"."audit_logs" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."audit_logs_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."audit_logs_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."audit_logs_id_seq" OWNED BY "public"."audit_logs"."id";



CREATE TABLE IF NOT EXISTS "public"."blocks" (
    "blocker_id" "uuid" NOT NULL,
    "blocked_id" "uuid" NOT NULL,
    "reason" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "blocks_check" CHECK (("blocker_id" <> "blocked_id")),
    CONSTRAINT "blocks_reason_check" CHECK (("char_length"("reason") <= 500))
);


ALTER TABLE "public"."blocks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."collection_works" (
    "collection_id" "uuid" NOT NULL,
    "work_id" "uuid" NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    "added_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."collection_works" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."collections" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "cover_thumbnail_url" "text",
    "visibility" "text" DEFAULT 'private'::"text" NOT NULL,
    "works_count" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "collections_description_check" CHECK (("char_length"("description") <= 2000)),
    CONSTRAINT "collections_title_check" CHECK ((("char_length"("title") >= 1) AND ("char_length"("title") <= 100))),
    CONSTRAINT "collections_visibility_check" CHECK (("visibility" = ANY (ARRAY['public'::"text", 'private'::"text"]))),
    CONSTRAINT "collections_works_count_check" CHECK (("works_count" >= 0))
);


ALTER TABLE "public"."collections" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."comment_likes" (
    "user_id" "uuid" NOT NULL,
    "comment_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."comment_likes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."comments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "work_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "parent_id" "uuid",
    "body" "text" NOT NULL,
    "likes_count" integer DEFAULT 0 NOT NULL,
    "is_pinned" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "comments_body_check" CHECK ((("char_length"("body") >= 1) AND ("char_length"("body") <= 2000))),
    CONSTRAINT "comments_likes_count_check" CHECK (("likes_count" >= 0))
);


ALTER TABLE "public"."comments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."conversation_members" (
    "conversation_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "joined_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_read_message_id" bigint
);


ALTER TABLE "public"."conversation_members" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."conversations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "type" "text" DEFAULT 'dm'::"text" NOT NULL,
    "dm_pair_key" "text",
    "title" "text",
    "created_by" "uuid",
    "last_message_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "conversations_type_check" CHECK (("type" = ANY (ARRAY['dm'::"text", 'group'::"text"])))
);


ALTER TABLE "public"."conversations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."edge_rate_limits" (
    "bucket_key" "text" NOT NULL,
    "window_start" timestamp with time zone DEFAULT "now"() NOT NULL,
    "hit_count" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."edge_rate_limits" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."follows" (
    "follower_id" "uuid" NOT NULL,
    "followee_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "follows_check" CHECK (("follower_id" <> "followee_id"))
);


ALTER TABLE "public"."follows" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."live_participants" (
    "session_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "joined_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "left_at" timestamp with time zone
);


ALTER TABLE "public"."live_participants" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."live_sessions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "host_id" "uuid" NOT NULL,
    "work_id" "uuid",
    "title" "text" NOT NULL,
    "status" "text" DEFAULT 'scheduled'::"text" NOT NULL,
    "scheduled_for" timestamp with time zone,
    "started_at" timestamp with time zone,
    "ended_at" timestamp with time zone,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "live_sessions_status_check" CHECK (("status" = ANY (ARRAY['scheduled'::"text", 'live'::"text", 'ended'::"text"]))),
    CONSTRAINT "live_sessions_title_check" CHECK ((("char_length"("title") >= 1) AND ("char_length"("title") <= 100)))
);


ALTER TABLE "public"."live_sessions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."mentions" (
    "id" bigint NOT NULL,
    "mentioned_user_id" "uuid" NOT NULL,
    "source_type" "text" NOT NULL,
    "source_id" "uuid" NOT NULL,
    "actor_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "mentions_source_type_check" CHECK (("source_type" = ANY (ARRAY['comment'::"text", 'work_description'::"text"])))
);


ALTER TABLE "public"."mentions" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."mentions_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."mentions_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."mentions_id_seq" OWNED BY "public"."mentions"."id";



CREATE TABLE IF NOT EXISTS "public"."messages" (
    "id" bigint NOT NULL,
    "conversation_id" "uuid" NOT NULL,
    "sender_id" "uuid" NOT NULL,
    "body" "text" NOT NULL,
    "attached_work_id" "uuid",
    "edited_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "messages_body_check" CHECK ((("char_length"("body") >= 1) AND ("char_length"("body") <= 5000)))
);


ALTER TABLE "public"."messages" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."messages_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."messages_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."messages_id_seq" OWNED BY "public"."messages"."id";



CREATE TABLE IF NOT EXISTS "public"."notification_settings" (
    "user_id" "uuid" NOT NULL,
    "push_enabled" boolean DEFAULT true NOT NULL,
    "email_enabled" boolean DEFAULT true NOT NULL,
    "on_work_liked" boolean DEFAULT true NOT NULL,
    "on_work_commented" boolean DEFAULT true NOT NULL,
    "on_comment_replied" boolean DEFAULT true NOT NULL,
    "on_comment_liked" boolean DEFAULT true NOT NULL,
    "on_user_followed" boolean DEFAULT true NOT NULL,
    "on_user_mentioned" boolean DEFAULT true NOT NULL,
    "on_work_published_by_followee" boolean DEFAULT true NOT NULL,
    "quiet_hours_start" integer,
    "quiet_hours_end" integer,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "notification_settings_quiet_hours_end_check" CHECK ((("quiet_hours_end" >= 0) AND ("quiet_hours_end" <= 23))),
    CONSTRAINT "notification_settings_quiet_hours_start_check" CHECK ((("quiet_hours_start" >= 0) AND ("quiet_hours_start" <= 23)))
);


ALTER TABLE "public"."notification_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notifications" (
    "id" bigint NOT NULL,
    "recipient_id" "uuid" NOT NULL,
    "actor_id" "uuid",
    "type" "text" NOT NULL,
    "target_type" "text",
    "target_id" "uuid",
    "payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "read_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "notifications_target_type_check" CHECK (("target_type" = ANY (ARRAY['work'::"text", 'comment'::"text", 'user'::"text", 'project'::"text"]))),
    CONSTRAINT "notifications_type_check" CHECK (("type" = ANY (ARRAY['work_liked'::"text", 'work_commented'::"text", 'comment_replied'::"text", 'comment_liked'::"text", 'user_followed'::"text", 'user_mentioned'::"text", 'work_published_by_followee'::"text", 'system_announcement'::"text"])))
);


ALTER TABLE "public"."notifications" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."notifications_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."notifications_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."notifications_id_seq" OWNED BY "public"."notifications"."id";



CREATE TABLE IF NOT EXISTS "public"."pending_password_resets" (
    "email" "text" NOT NULL,
    "otp_hash" "text" NOT NULL,
    "attempts" integer DEFAULT 0 NOT NULL,
    "locale" "text" DEFAULT 'en'::"text" NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."pending_password_resets" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pending_signups" (
    "email" "text" NOT NULL,
    "password" "text" NOT NULL,
    "otp_hash" "text" NOT NULL,
    "attempts" integer DEFAULT 0 NOT NULL,
    "display_name" "text",
    "locale" "text" DEFAULT 'en'::"text" NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."pending_signups" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "display_name" "text" NOT NULL,
    "avatar_url" "text",
    "banner_url" "text",
    "bio" "text",
    "location" "text",
    "website" "text",
    "is_private" boolean DEFAULT false NOT NULL,
    "followers_count" integer DEFAULT 0 NOT NULL,
    "following_count" integer DEFAULT 0 NOT NULL,
    "works_count" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "handle" "text",
    "handle_key" "text",
    "display_name_changed_at" timestamp with time zone,
    "handle_changed_at" timestamp with time zone,
    CONSTRAINT "profiles_bio_len" CHECK ((("bio" IS NULL) OR ("char_length"("bio") <= 2000))),
    CONSTRAINT "profiles_display_name_len" CHECK ((("char_length"("display_name") >= 1) AND ("char_length"("display_name") <= 200))),
    CONSTRAINT "profiles_followers_count_check" CHECK (("followers_count" >= 0)),
    CONSTRAINT "profiles_following_count_check" CHECK (("following_count" >= 0)),
    CONSTRAINT "profiles_handle_check" CHECK ((("handle" IS NULL) OR ("handle" ~ '^[a-z0-9._]{2,32}$'::"text"))),
    CONSTRAINT "profiles_location_check" CHECK (("char_length"("location") <= 100)),
    CONSTRAINT "profiles_website_check" CHECK (("char_length"("website") <= 200)),
    CONSTRAINT "profiles_works_count_check" CHECK (("works_count" >= 0))
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


COMMENT ON COLUMN "public"."profiles"."handle" IS '唯一标识,小写 ASCII a-z/0-9/./_,长度 2-32(Discord 口径)。可为 NULL=尚未设置。';



COMMENT ON COLUMN "public"."profiles"."handle_key" IS '用于唯一约束的比较键。当前恒等于 handle;放宽字符集时才会与 handle 分叉。';



CREATE TABLE IF NOT EXISTS "public"."projects" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "cover_thumbnail_url" "text",
    "visibility" "text" DEFAULT 'private'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "projects_description_check" CHECK (("char_length"("description") <= 2000)),
    CONSTRAINT "projects_title_check" CHECK ((("char_length"("title") >= 1) AND ("char_length"("title") <= 100))),
    CONSTRAINT "projects_visibility_check" CHECK (("visibility" = ANY (ARRAY['public'::"text", 'private'::"text"])))
);


ALTER TABLE "public"."projects" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."reports" (
    "id" bigint NOT NULL,
    "reporter_id" "uuid" NOT NULL,
    "target_type" "text" NOT NULL,
    "target_id" "uuid" NOT NULL,
    "reason" "text" NOT NULL,
    "detail" "text",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "admin_notes" "text",
    "resolved_by" "uuid",
    "resolved_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "reports_detail_check" CHECK (("char_length"("detail") <= 2000)),
    CONSTRAINT "reports_reason_check" CHECK (("reason" = ANY (ARRAY['spam'::"text", 'harassment'::"text", 'hate_speech'::"text", 'sexual_content'::"text", 'violence'::"text", 'copyright'::"text", 'misinformation'::"text", 'other'::"text"]))),
    CONSTRAINT "reports_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'in_review'::"text", 'actioned'::"text", 'dismissed'::"text"]))),
    CONSTRAINT "reports_target_type_check" CHECK (("target_type" = ANY (ARRAY['work'::"text", 'comment'::"text", 'user'::"text", 'project'::"text"])))
);


ALTER TABLE "public"."reports" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."reports_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."reports_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."reports_id_seq" OWNED BY "public"."reports"."id";



CREATE TABLE IF NOT EXISTS "public"."rls_policy_snapshot" (
    "id" bigint NOT NULL,
    "taken_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "reason" "text" NOT NULL,
    "schema_name" "text" NOT NULL,
    "table_name" "text" NOT NULL,
    "policy_name" "text" NOT NULL,
    "cmd" character(1) NOT NULL,
    "roles" "text"[] NOT NULL,
    "using_expr" "text",
    "check_expr" "text"
);


ALTER TABLE "public"."rls_policy_snapshot" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."rls_policy_snapshot_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."rls_policy_snapshot_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."rls_policy_snapshot_id_seq" OWNED BY "public"."rls_policy_snapshot"."id";



CREATE TABLE IF NOT EXISTS "public"."scans" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "project_id" "uuid",
    "status" "text" DEFAULT 'uploading'::"text" NOT NULL,
    "frames_count" integer DEFAULT 0 NOT NULL,
    "duration_seconds" integer DEFAULT 0 NOT NULL,
    "raw_storage_path" "text",
    "cover_thumbnail_path" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "error_message" "text",
    "training_started_at" timestamp with time zone,
    "training_completed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "upload_acknowledged_at" timestamp with time zone,
    "local_raw_deleted_at" timestamp with time zone,
    "cloud_raw_deleted_at" timestamp with time zone,
    "processing_started_at" timestamp with time zone,
    "processing_completed_at" timestamp with time zone,
    "work_id" "uuid",
    CONSTRAINT "scans_duration_seconds_check" CHECK (("duration_seconds" >= 0)),
    CONSTRAINT "scans_frames_count_check" CHECK (("frames_count" >= 0)),
    CONSTRAINT "scans_status_check" CHECK (("status" = ANY (ARRAY['uploading'::"text", 'pending'::"text", 'uploaded_acknowledged'::"text", 'queued'::"text", 'processing'::"text", 'training'::"text", 'packaging'::"text", 'artifact_ready'::"text", 'completed'::"text", 'failed'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."scans" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tags" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "works_count" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "tags_display_name_check" CHECK ((("char_length"("display_name") >= 1) AND ("char_length"("display_name") <= 50))),
    CONSTRAINT "tags_name_check" CHECK (((("char_length"("name") >= 1) AND ("char_length"("name") <= 50)) AND ("name" = "lower"("name")) AND ("name" ~ '^[a-z0-9_一-鿿]+$'::"text"))),
    CONSTRAINT "tags_works_count_check" CHECK (("works_count" >= 0))
);


ALTER TABLE "public"."tags" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."work_bookmarks" (
    "user_id" "uuid" NOT NULL,
    "work_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."work_bookmarks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."work_likes" (
    "user_id" "uuid" NOT NULL,
    "work_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."work_likes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."work_tags" (
    "work_id" "uuid" NOT NULL,
    "tag_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."work_tags" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."work_versions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "work_id" "uuid" NOT NULL,
    "version_number" integer NOT NULL,
    "format" "text" NOT NULL,
    "model_storage_path" "text" NOT NULL,
    "thumbnail_storage_path" "text",
    "file_size_bytes" bigint,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "work_versions_file_size_bytes_check" CHECK (("file_size_bytes" >= 0)),
    CONSTRAINT "work_versions_format_check" CHECK (("format" = ANY (ARRAY['glb'::"text", 'spz'::"text", 'gsplat'::"text", 'ply'::"text"]))),
    CONSTRAINT "work_versions_notes_check" CHECK (("char_length"("notes") <= 2000)),
    CONSTRAINT "work_versions_version_number_check" CHECK (("version_number" >= 1))
);


ALTER TABLE "public"."work_versions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."work_views" (
    "id" bigint NOT NULL,
    "viewer_id" "uuid",
    "work_id" "uuid" NOT NULL,
    "view_bucket" timestamp with time zone DEFAULT "date_trunc"('hour'::"text", "now"()) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."work_views" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."work_views_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."work_views_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."work_views_id_seq" OWNED BY "public"."work_views"."id";



CREATE TABLE IF NOT EXISTS "public"."works" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "scan_id" "uuid",
    "project_id" "uuid",
    "title" "text" NOT NULL,
    "description" "text",
    "format" "text" NOT NULL,
    "model_storage_path" "text" NOT NULL,
    "thumbnail_storage_path" "text",
    "preview_video_path" "text",
    "file_size_bytes" bigint,
    "visibility" "text" DEFAULT 'private'::"text" NOT NULL,
    "likes_count" integer DEFAULT 0 NOT NULL,
    "comments_count" integer DEFAULT 0 NOT NULL,
    "bookmarks_count" integer DEFAULT 0 NOT NULL,
    "views_count" integer DEFAULT 0 NOT NULL,
    "published_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "moderation_status" "text" DEFAULT 'ok'::"text" NOT NULL,
    "deleted_at" timestamp with time zone,
    CONSTRAINT "works_bookmarks_count_check" CHECK (("bookmarks_count" >= 0)),
    CONSTRAINT "works_comments_count_check" CHECK (("comments_count" >= 0)),
    CONSTRAINT "works_description_check" CHECK (("char_length"("description") <= 5000)),
    CONSTRAINT "works_description_len_30" CHECK ((("description" IS NULL) OR ("char_length"("description") <= 30))),
    CONSTRAINT "works_file_size_bytes_check" CHECK (("file_size_bytes" >= 0)),
    CONSTRAINT "works_format_check" CHECK (("format" = ANY (ARRAY['glb'::"text", 'spz'::"text", 'gsplat'::"text", 'ply'::"text"]))),
    CONSTRAINT "works_likes_count_check" CHECK (("likes_count" >= 0)),
    CONSTRAINT "works_moderation_status_check" CHECK (("moderation_status" = ANY (ARRAY['ok'::"text", 'under_review'::"text", 'removed'::"text"]))),
    CONSTRAINT "works_title_check" CHECK ((("char_length"("title") >= 1) AND ("char_length"("title") <= 100))),
    CONSTRAINT "works_views_count_check" CHECK (("views_count" >= 0)),
    CONSTRAINT "works_visibility_check" CHECK (("visibility" = ANY (ARRAY['public'::"text", 'followers'::"text", 'private'::"text"]))),
    CONSTRAINT "works_visible_needs_published_at" CHECK ((("published_at" IS NOT NULL) OR ("moderation_status" <> 'ok'::"text") OR ("visibility" <> 'public'::"text") OR ("deleted_at" IS NOT NULL)))
);


ALTER TABLE "public"."works" OWNER TO "postgres";


COMMENT ON COLUMN "public"."works"."moderation_status" IS 'ok = visible; under_review = hidden from public feed pending review; removed = taken down by admin.';



COMMENT ON COLUMN "public"."works"."deleted_at" IS 'Set when moderation_status becomes removed. Row is kept for audit/appeal; hard DELETE stays owner-only.';



COMMENT ON CONSTRAINT "works_description_len_30" ON "public"."works" IS '2026-08-23 合规收敛:描述字段收到 30 字。放宽前须重新做安全评估报送。';



ALTER TABLE ONLY "public"."audit_logs" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."audit_logs_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."mentions" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."mentions_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."messages" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."messages_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."notifications" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."notifications_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."reports" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."reports_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."rls_policy_snapshot" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."rls_policy_snapshot_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."work_views" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."work_views_id_seq"'::"regclass");



ALTER TABLE ONLY "app"."switches"
    ADD CONSTRAINT "switches_pkey" PRIMARY KEY ("key");



ALTER TABLE ONLY "public"."audit_logs"
    ADD CONSTRAINT "audit_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."blocks"
    ADD CONSTRAINT "blocks_pkey" PRIMARY KEY ("blocker_id", "blocked_id");



ALTER TABLE ONLY "public"."collection_works"
    ADD CONSTRAINT "collection_works_pkey" PRIMARY KEY ("collection_id", "work_id");



ALTER TABLE ONLY "public"."collections"
    ADD CONSTRAINT "collections_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."comment_likes"
    ADD CONSTRAINT "comment_likes_pkey" PRIMARY KEY ("user_id", "comment_id");



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."conversation_members"
    ADD CONSTRAINT "conversation_members_pkey" PRIMARY KEY ("conversation_id", "user_id");



ALTER TABLE ONLY "public"."conversations"
    ADD CONSTRAINT "conversations_dm_pair_key_key" UNIQUE ("dm_pair_key");



ALTER TABLE ONLY "public"."conversations"
    ADD CONSTRAINT "conversations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."edge_rate_limits"
    ADD CONSTRAINT "edge_rate_limits_pkey" PRIMARY KEY ("bucket_key");



ALTER TABLE ONLY "public"."follows"
    ADD CONSTRAINT "follows_pkey" PRIMARY KEY ("follower_id", "followee_id");



ALTER TABLE ONLY "public"."live_participants"
    ADD CONSTRAINT "live_participants_pkey" PRIMARY KEY ("session_id", "user_id");



ALTER TABLE ONLY "public"."live_sessions"
    ADD CONSTRAINT "live_sessions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mentions"
    ADD CONSTRAINT "mentions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."messages"
    ADD CONSTRAINT "messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notification_settings"
    ADD CONSTRAINT "notification_settings_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pending_password_resets"
    ADD CONSTRAINT "pending_password_resets_pkey" PRIMARY KEY ("email");



ALTER TABLE ONLY "public"."pending_signups"
    ADD CONSTRAINT "pending_signups_pkey" PRIMARY KEY ("email");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."projects"
    ADD CONSTRAINT "projects_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."reports"
    ADD CONSTRAINT "reports_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rls_policy_snapshot"
    ADD CONSTRAINT "rls_policy_snapshot_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."scans"
    ADD CONSTRAINT "scans_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tags"
    ADD CONSTRAINT "tags_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."tags"
    ADD CONSTRAINT "tags_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."work_bookmarks"
    ADD CONSTRAINT "work_bookmarks_pkey" PRIMARY KEY ("user_id", "work_id");



ALTER TABLE ONLY "public"."work_likes"
    ADD CONSTRAINT "work_likes_pkey" PRIMARY KEY ("user_id", "work_id");



ALTER TABLE ONLY "public"."work_tags"
    ADD CONSTRAINT "work_tags_pkey" PRIMARY KEY ("work_id", "tag_id");



ALTER TABLE ONLY "public"."work_versions"
    ADD CONSTRAINT "work_versions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."work_versions"
    ADD CONSTRAINT "work_versions_work_id_version_number_key" UNIQUE ("work_id", "version_number");



ALTER TABLE ONLY "public"."work_views"
    ADD CONSTRAINT "work_views_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."works"
    ADD CONSTRAINT "works_pkey" PRIMARY KEY ("id");



CREATE INDEX "edge_rate_limits_window_start_idx" ON "public"."edge_rate_limits" USING "btree" ("window_start");



CREATE INDEX "idx_audit_logs_action" ON "public"."audit_logs" USING "btree" ("action", "created_at" DESC);



CREATE INDEX "idx_audit_logs_actor" ON "public"."audit_logs" USING "btree" ("actor_id", "created_at" DESC) WHERE ("actor_id" IS NOT NULL);



CREATE INDEX "idx_audit_logs_created" ON "public"."audit_logs" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_audit_logs_target" ON "public"."audit_logs" USING "btree" ("target_type", "target_id");



CREATE INDEX "idx_blocks_blocked_id" ON "public"."blocks" USING "btree" ("blocked_id");



CREATE INDEX "idx_collection_works_pos" ON "public"."collection_works" USING "btree" ("collection_id", "position");



CREATE INDEX "idx_collections_user" ON "public"."collections" USING "btree" ("user_id");



CREATE INDEX "idx_collections_visibility" ON "public"."collections" USING "btree" ("visibility") WHERE ("visibility" = 'public'::"text");



CREATE INDEX "idx_comment_likes_comment_id" ON "public"."comment_likes" USING "btree" ("comment_id");



CREATE INDEX "idx_comments_parent_id" ON "public"."comments" USING "btree" ("parent_id") WHERE ("parent_id" IS NOT NULL);



CREATE INDEX "idx_comments_user_id" ON "public"."comments" USING "btree" ("user_id");



CREATE INDEX "idx_comments_work_id" ON "public"."comments" USING "btree" ("work_id", "created_at" DESC);



CREATE INDEX "idx_conversation_members_user" ON "public"."conversation_members" USING "btree" ("user_id");



CREATE INDEX "idx_conversations_last_message_at" ON "public"."conversations" USING "btree" ("last_message_at" DESC NULLS LAST);



CREATE INDEX "idx_follows_followee_id" ON "public"."follows" USING "btree" ("followee_id", "created_at" DESC);



CREATE INDEX "idx_follows_follower_id" ON "public"."follows" USING "btree" ("follower_id", "created_at" DESC);



CREATE INDEX "idx_live_participants_user" ON "public"."live_participants" USING "btree" ("user_id");



CREATE INDEX "idx_live_sessions_host" ON "public"."live_sessions" USING "btree" ("host_id");



CREATE INDEX "idx_live_sessions_status" ON "public"."live_sessions" USING "btree" ("status", "started_at" DESC);



CREATE INDEX "idx_mentions_source" ON "public"."mentions" USING "btree" ("source_type", "source_id");



CREATE INDEX "idx_mentions_user_id" ON "public"."mentions" USING "btree" ("mentioned_user_id", "created_at" DESC);



CREATE INDEX "idx_messages_conversation" ON "public"."messages" USING "btree" ("conversation_id", "created_at" DESC);



CREATE INDEX "idx_notifications_recipient" ON "public"."notifications" USING "btree" ("recipient_id", "created_at" DESC);



CREATE INDEX "idx_notifications_unread" ON "public"."notifications" USING "btree" ("recipient_id", "created_at" DESC) WHERE ("read_at" IS NULL);



CREATE INDEX "idx_projects_user_id" ON "public"."projects" USING "btree" ("user_id");



CREATE INDEX "idx_projects_visibility" ON "public"."projects" USING "btree" ("visibility") WHERE ("visibility" = 'public'::"text");



CREATE INDEX "idx_reports_reporter" ON "public"."reports" USING "btree" ("reporter_id");



CREATE INDEX "idx_reports_status_created" ON "public"."reports" USING "btree" ("status", "created_at" DESC) WHERE ("status" = 'pending'::"text");



CREATE INDEX "idx_reports_target" ON "public"."reports" USING "btree" ("target_type", "target_id");



CREATE INDEX "idx_scans_cloud_worker_queue" ON "public"."scans" USING "btree" ("created_at") WHERE ("status" = ANY (ARRAY['uploaded_acknowledged'::"text", 'queued'::"text"]));



CREATE INDEX "idx_scans_project_id" ON "public"."scans" USING "btree" ("project_id");



CREATE INDEX "idx_scans_status" ON "public"."scans" USING "btree" ("status");



CREATE INDEX "idx_scans_user_id" ON "public"."scans" USING "btree" ("user_id");



CREATE INDEX "idx_scans_work_id" ON "public"."scans" USING "btree" ("work_id");



CREATE INDEX "idx_scans_worker_queue_queued" ON "public"."scans" USING "btree" ("created_at") WHERE ("status" = 'queued'::"text");



CREATE INDEX "idx_tags_works_count" ON "public"."tags" USING "btree" ("works_count" DESC);



CREATE INDEX "idx_work_bookmarks_user_id" ON "public"."work_bookmarks" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "idx_work_likes_work_id" ON "public"."work_likes" USING "btree" ("work_id", "created_at" DESC);



CREATE INDEX "idx_work_tags_tag_id" ON "public"."work_tags" USING "btree" ("tag_id", "created_at" DESC);



CREATE INDEX "idx_work_versions_work_id" ON "public"."work_versions" USING "btree" ("work_id", "version_number" DESC);



CREATE INDEX "idx_work_views_work_id" ON "public"."work_views" USING "btree" ("work_id", "created_at" DESC);



CREATE INDEX "idx_works_hot" ON "public"."works" USING "btree" ("likes_count" DESC, "published_at" DESC) WHERE (("visibility" = 'public'::"text") AND ("published_at" IS NOT NULL));



CREATE INDEX "idx_works_model_storage_path" ON "public"."works" USING "btree" ("model_storage_path");



CREATE INDEX "idx_works_project_id" ON "public"."works" USING "btree" ("project_id");



CREATE INDEX "idx_works_published_at" ON "public"."works" USING "btree" ("published_at" DESC) WHERE (("visibility" = 'public'::"text") AND ("published_at" IS NOT NULL));



CREATE INDEX "idx_works_published_keyset" ON "public"."works" USING "btree" ("published_at" DESC, "id" DESC) WHERE (("visibility" = 'public'::"text") AND ("published_at" IS NOT NULL));



CREATE INDEX "idx_works_review_queue" ON "public"."works" USING "btree" ("created_at") WHERE (("moderation_status" = 'under_review'::"text") AND ("published_at" IS NULL));



COMMENT ON INDEX "public"."idx_works_review_queue" IS '待审队列:status 过滤 + created_at 排序。admin-approve-work 的 list 走它。';



CREATE INDEX "idx_works_user_id" ON "public"."works" USING "btree" ("user_id");



CREATE INDEX "idx_works_visibility" ON "public"."works" USING "btree" ("visibility") WHERE ("visibility" = 'public'::"text");



CREATE INDEX "pending_password_resets_expires_at_idx" ON "public"."pending_password_resets" USING "btree" ("expires_at");



CREATE INDEX "pending_signups_expires_at_idx" ON "public"."pending_signups" USING "btree" ("expires_at");



CREATE UNIQUE INDEX "uq_mentions_dedup" ON "public"."mentions" USING "btree" ("source_type", "source_id", "mentioned_user_id");



CREATE UNIQUE INDEX "uq_profiles_handle_key" ON "public"."profiles" USING "btree" ("handle_key") WHERE ("handle_key" IS NOT NULL);



CREATE UNIQUE INDEX "uq_work_views_dedup" ON "public"."work_views" USING "btree" ("work_id", COALESCE(("viewer_id")::"text", 'anon'::"text"), "view_bucket");



CREATE UNIQUE INDEX "uq_works_user_model_path" ON "public"."works" USING "btree" ("user_id", "model_storage_path") WHERE ("model_storage_path" IS NOT NULL);



COMMENT ON INDEX "public"."uq_works_user_model_path" IS '内容寻址路径的幂等键。upload-finalize 靠它把重试收敛成同一行(23505 后回读)。';



CREATE OR REPLACE TRIGGER "bump_collection_works_count_del" AFTER DELETE ON "public"."collection_works" FOR EACH ROW EXECUTE FUNCTION "public"."bump_collection_works_count"();



CREATE OR REPLACE TRIGGER "bump_collection_works_count_ins" AFTER INSERT ON "public"."collection_works" FOR EACH ROW EXECUTE FUNCTION "public"."bump_collection_works_count"();



CREATE OR REPLACE TRIGGER "bump_comment_likes_count_del" AFTER DELETE ON "public"."comment_likes" FOR EACH ROW EXECUTE FUNCTION "public"."bump_comment_likes_count"();



CREATE OR REPLACE TRIGGER "bump_comment_likes_count_ins" AFTER INSERT ON "public"."comment_likes" FOR EACH ROW EXECUTE FUNCTION "public"."bump_comment_likes_count"();



CREATE OR REPLACE TRIGGER "bump_profile_follow_counts_del" AFTER DELETE ON "public"."follows" FOR EACH ROW EXECUTE FUNCTION "public"."bump_profile_follow_counts"();



CREATE OR REPLACE TRIGGER "bump_profile_follow_counts_ins" AFTER INSERT ON "public"."follows" FOR EACH ROW EXECUTE FUNCTION "public"."bump_profile_follow_counts"();



CREATE OR REPLACE TRIGGER "bump_profile_works_count_del" AFTER DELETE ON "public"."works" FOR EACH ROW EXECUTE FUNCTION "public"."bump_profile_works_count"();



CREATE OR REPLACE TRIGGER "bump_profile_works_count_ins" AFTER INSERT ON "public"."works" FOR EACH ROW EXECUTE FUNCTION "public"."bump_profile_works_count"();



CREATE OR REPLACE TRIGGER "bump_tag_works_count_del" AFTER DELETE ON "public"."work_tags" FOR EACH ROW EXECUTE FUNCTION "public"."bump_tag_works_count"();



CREATE OR REPLACE TRIGGER "bump_tag_works_count_ins" AFTER INSERT ON "public"."work_tags" FOR EACH ROW EXECUTE FUNCTION "public"."bump_tag_works_count"();



CREATE OR REPLACE TRIGGER "bump_work_bookmarks_count_del" AFTER DELETE ON "public"."work_bookmarks" FOR EACH ROW EXECUTE FUNCTION "public"."bump_work_bookmarks_count"();



CREATE OR REPLACE TRIGGER "bump_work_bookmarks_count_ins" AFTER INSERT ON "public"."work_bookmarks" FOR EACH ROW EXECUTE FUNCTION "public"."bump_work_bookmarks_count"();



CREATE OR REPLACE TRIGGER "bump_work_comments_count_del" AFTER DELETE ON "public"."comments" FOR EACH ROW EXECUTE FUNCTION "public"."bump_work_comments_count"();



CREATE OR REPLACE TRIGGER "bump_work_comments_count_ins" AFTER INSERT ON "public"."comments" FOR EACH ROW EXECUTE FUNCTION "public"."bump_work_comments_count"();



CREATE OR REPLACE TRIGGER "bump_work_likes_count_del" AFTER DELETE ON "public"."work_likes" FOR EACH ROW EXECUTE FUNCTION "public"."bump_work_likes_count"();



CREATE OR REPLACE TRIGGER "bump_work_likes_count_ins" AFTER INSERT ON "public"."work_likes" FOR EACH ROW EXECUTE FUNCTION "public"."bump_work_likes_count"();



CREATE OR REPLACE TRIGGER "bump_work_views_count_ins" AFTER INSERT ON "public"."work_views" FOR EACH ROW EXECUTE FUNCTION "public"."bump_work_views_count"();



CREATE OR REPLACE TRIGGER "cascade_block_unfollow_ins" AFTER INSERT ON "public"."blocks" FOR EACH ROW EXECUTE FUNCTION "public"."cascade_block_unfollow"();



CREATE OR REPLACE TRIGGER "guard_profile_identity_columns" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."guard_profile_identity_columns"();



CREATE OR REPLACE TRIGGER "guard_work_content_columns" BEFORE UPDATE ON "public"."works" FOR EACH ROW EXECUTE FUNCTION "public"."guard_work_content_columns"();



CREATE OR REPLACE TRIGGER "guard_work_moderation_columns" BEFORE UPDATE ON "public"."works" FOR EACH ROW EXECUTE FUNCTION "public"."guard_work_moderation_columns"();



CREATE OR REPLACE TRIGGER "guard_work_moderation_delete" BEFORE DELETE ON "public"."works" FOR EACH ROW EXECUTE FUNCTION "public"."guard_work_moderation_delete"();



CREATE OR REPLACE TRIGGER "set_updated_at_collections" BEFORE UPDATE ON "public"."collections" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "set_updated_at_comments" BEFORE UPDATE ON "public"."comments" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "set_updated_at_live_sessions" BEFORE UPDATE ON "public"."live_sessions" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "set_updated_at_notification_settings" BEFORE UPDATE ON "public"."notification_settings" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "set_updated_at_profiles" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "set_updated_at_projects" BEFORE UPDATE ON "public"."projects" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "set_updated_at_scans" BEFORE UPDATE ON "public"."scans" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "set_updated_at_works" BEFORE UPDATE ON "public"."works" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "touch_conversation_last_message_ins" AFTER INSERT ON "public"."messages" FOR EACH ROW EXECUTE FUNCTION "public"."touch_conversation_last_message"();



ALTER TABLE ONLY "public"."blocks"
    ADD CONSTRAINT "blocks_blocked_id_fkey" FOREIGN KEY ("blocked_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."blocks"
    ADD CONSTRAINT "blocks_blocker_id_fkey" FOREIGN KEY ("blocker_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."collection_works"
    ADD CONSTRAINT "collection_works_collection_id_fkey" FOREIGN KEY ("collection_id") REFERENCES "public"."collections"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."collection_works"
    ADD CONSTRAINT "collection_works_work_id_fkey" FOREIGN KEY ("work_id") REFERENCES "public"."works"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."collections"
    ADD CONSTRAINT "collections_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comment_likes"
    ADD CONSTRAINT "comment_likes_comment_id_fkey" FOREIGN KEY ("comment_id") REFERENCES "public"."comments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comment_likes"
    ADD CONSTRAINT "comment_likes_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_parent_id_fkey" FOREIGN KEY ("parent_id") REFERENCES "public"."comments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_work_id_fkey" FOREIGN KEY ("work_id") REFERENCES "public"."works"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."conversation_members"
    ADD CONSTRAINT "conversation_members_conversation_id_fkey" FOREIGN KEY ("conversation_id") REFERENCES "public"."conversations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."conversation_members"
    ADD CONSTRAINT "conversation_members_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."conversations"
    ADD CONSTRAINT "conversations_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."follows"
    ADD CONSTRAINT "follows_followee_id_fkey" FOREIGN KEY ("followee_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."follows"
    ADD CONSTRAINT "follows_follower_id_fkey" FOREIGN KEY ("follower_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."live_participants"
    ADD CONSTRAINT "live_participants_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."live_sessions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."live_participants"
    ADD CONSTRAINT "live_participants_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."live_sessions"
    ADD CONSTRAINT "live_sessions_host_id_fkey" FOREIGN KEY ("host_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."live_sessions"
    ADD CONSTRAINT "live_sessions_work_id_fkey" FOREIGN KEY ("work_id") REFERENCES "public"."works"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."mentions"
    ADD CONSTRAINT "mentions_actor_id_fkey" FOREIGN KEY ("actor_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mentions"
    ADD CONSTRAINT "mentions_mentioned_user_id_fkey" FOREIGN KEY ("mentioned_user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."messages"
    ADD CONSTRAINT "messages_attached_work_id_fkey" FOREIGN KEY ("attached_work_id") REFERENCES "public"."works"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."messages"
    ADD CONSTRAINT "messages_conversation_id_fkey" FOREIGN KEY ("conversation_id") REFERENCES "public"."conversations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."messages"
    ADD CONSTRAINT "messages_sender_id_fkey" FOREIGN KEY ("sender_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notification_settings"
    ADD CONSTRAINT "notification_settings_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_actor_id_fkey" FOREIGN KEY ("actor_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_recipient_id_fkey" FOREIGN KEY ("recipient_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."projects"
    ADD CONSTRAINT "projects_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."reports"
    ADD CONSTRAINT "reports_reporter_id_fkey" FOREIGN KEY ("reporter_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."reports"
    ADD CONSTRAINT "reports_resolved_by_fkey" FOREIGN KEY ("resolved_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."scans"
    ADD CONSTRAINT "scans_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."scans"
    ADD CONSTRAINT "scans_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."scans"
    ADD CONSTRAINT "scans_work_id_fkey" FOREIGN KEY ("work_id") REFERENCES "public"."works"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."work_bookmarks"
    ADD CONSTRAINT "work_bookmarks_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."work_bookmarks"
    ADD CONSTRAINT "work_bookmarks_work_id_fkey" FOREIGN KEY ("work_id") REFERENCES "public"."works"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."work_likes"
    ADD CONSTRAINT "work_likes_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."work_likes"
    ADD CONSTRAINT "work_likes_work_id_fkey" FOREIGN KEY ("work_id") REFERENCES "public"."works"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."work_tags"
    ADD CONSTRAINT "work_tags_tag_id_fkey" FOREIGN KEY ("tag_id") REFERENCES "public"."tags"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."work_tags"
    ADD CONSTRAINT "work_tags_work_id_fkey" FOREIGN KEY ("work_id") REFERENCES "public"."works"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."work_versions"
    ADD CONSTRAINT "work_versions_work_id_fkey" FOREIGN KEY ("work_id") REFERENCES "public"."works"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."work_views"
    ADD CONSTRAINT "work_views_viewer_id_fkey" FOREIGN KEY ("viewer_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."work_views"
    ADD CONSTRAINT "work_views_work_id_fkey" FOREIGN KEY ("work_id") REFERENCES "public"."works"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."works"
    ADD CONSTRAINT "works_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."works"
    ADD CONSTRAINT "works_scan_id_fkey" FOREIGN KEY ("scan_id") REFERENCES "public"."scans"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."works"
    ADD CONSTRAINT "works_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE "app"."switches" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."audit_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."blocks" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "blocks_delete_self" ON "public"."blocks" FOR DELETE TO "authenticated" USING ((( SELECT "app"."current_user_id"() AS "current_user_id") = "blocker_id"));



CREATE POLICY "blocks_insert_self" ON "public"."blocks" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "app"."current_user_id"() AS "current_user_id") = "blocker_id"));



CREATE POLICY "blocks_select_blocker" ON "public"."blocks" FOR SELECT TO "authenticated" USING ((( SELECT "app"."current_user_id"() AS "current_user_id") = "blocker_id"));



ALTER TABLE "public"."collection_works" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "collection_works_owner_modify" ON "public"."collection_works" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."collections" "c"
  WHERE (("c"."id" = "collection_works"."collection_id") AND ("c"."user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id")))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."collections" "c"
  WHERE (("c"."id" = "collection_works"."collection_id") AND ("c"."user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id"))))));



CREATE POLICY "collection_works_select_visible" ON "public"."collection_works" FOR SELECT TO "authenticated", "anon" USING (((EXISTS ( SELECT 1
   FROM "public"."collections" "c"
  WHERE (("c"."id" = "collection_works"."collection_id") AND (("c"."visibility" = 'public'::"text") OR ("c"."user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id")))))) AND (EXISTS ( SELECT 1
   FROM "public"."works" "w"
  WHERE (("w"."id" = "collection_works"."work_id") AND ((("w"."visibility" = 'public'::"text") AND ("w"."moderation_status" = 'ok'::"text") AND ("w"."deleted_at" IS NULL)) OR ("w"."user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id"))))))));



ALTER TABLE "public"."collections" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "collections_delete_own" ON "public"."collections" FOR DELETE TO "authenticated" USING ((( SELECT "app"."current_user_id"() AS "current_user_id") = "user_id"));



CREATE POLICY "collections_insert_own" ON "public"."collections" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "app"."current_user_id"() AS "current_user_id") = "user_id"));



CREATE POLICY "collections_select_visible" ON "public"."collections" FOR SELECT TO "authenticated", "anon" USING ((("visibility" = 'public'::"text") OR (( SELECT "app"."current_user_id"() AS "current_user_id") = "user_id")));



CREATE POLICY "collections_update_own" ON "public"."collections" FOR UPDATE TO "authenticated" USING ((( SELECT "app"."current_user_id"() AS "current_user_id") = "user_id")) WITH CHECK ((( SELECT "app"."current_user_id"() AS "current_user_id") = "user_id"));



ALTER TABLE "public"."comment_likes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "comment_likes_delete_self" ON "public"."comment_likes" FOR DELETE TO "authenticated" USING ((( SELECT "app"."current_user_id"() AS "current_user_id") = "user_id"));



CREATE POLICY "comment_likes_insert_self" ON "public"."comment_likes" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "app"."current_user_id"() AS "current_user_id") = "user_id"));



CREATE POLICY "comment_likes_select_visible" ON "public"."comment_likes" FOR SELECT TO "authenticated", "anon" USING ((EXISTS ( SELECT 1
   FROM "public"."comments" "c"
  WHERE (("c"."id" = "comment_likes"."comment_id") AND (EXISTS ( SELECT 1
           FROM "public"."works" "w"
          WHERE (("w"."id" = "c"."work_id") AND ((("w"."visibility" = 'public'::"text") AND ("w"."moderation_status" = 'ok'::"text") AND ("w"."deleted_at" IS NULL)) OR ("w"."user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id"))))))))));



ALTER TABLE "public"."comments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "comments_delete_own_or_workowner" ON "public"."comments" FOR DELETE TO "authenticated" USING (((( SELECT "app"."current_user_id"() AS "current_user_id") = "user_id") OR (EXISTS ( SELECT 1
   FROM "public"."works" "w"
  WHERE (("w"."id" = "comments"."work_id") AND ("w"."user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id")))))));



CREATE POLICY "comments_insert_self" ON "public"."comments" FOR INSERT TO "authenticated" WITH CHECK (((( SELECT "app"."current_user_id"() AS "current_user_id") = "user_id") AND (EXISTS ( SELECT 1
   FROM "public"."works" "w"
  WHERE (("w"."id" = "comments"."work_id") AND ((("w"."visibility" = 'public'::"text") AND ("w"."moderation_status" = 'ok'::"text") AND ("w"."deleted_at" IS NULL)) OR ("w"."user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id"))))))));



CREATE POLICY "comments_select_visible" ON "public"."comments" FOR SELECT TO "authenticated", "anon" USING ((EXISTS ( SELECT 1
   FROM "public"."works" "w"
  WHERE (("w"."id" = "comments"."work_id") AND ((("w"."visibility" = 'public'::"text") AND ("w"."moderation_status" = 'ok'::"text") AND ("w"."deleted_at" IS NULL)) OR ("w"."user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id")))))));



CREATE POLICY "comments_update_own" ON "public"."comments" FOR UPDATE TO "authenticated" USING ((( SELECT "app"."current_user_id"() AS "current_user_id") = "user_id")) WITH CHECK ((( SELECT "app"."current_user_id"() AS "current_user_id") = "user_id"));



ALTER TABLE "public"."conversation_members" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "conversation_members_delete_self" ON "public"."conversation_members" FOR DELETE TO "authenticated" USING (("user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id")));



CREATE POLICY "conversation_members_insert_member" ON "public"."conversation_members" FOR INSERT TO "authenticated" WITH CHECK ((("user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id")) OR (EXISTS ( SELECT 1
   FROM "public"."conversation_members" "m"
  WHERE (("m"."conversation_id" = "conversation_members"."conversation_id") AND ("m"."user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id")))))));



CREATE POLICY "conversation_members_select_member" ON "public"."conversation_members" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."conversation_members" "m2"
  WHERE (("m2"."conversation_id" = "conversation_members"."conversation_id") AND ("m2"."user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id"))))));



CREATE POLICY "conversation_members_update_self" ON "public"."conversation_members" FOR UPDATE TO "authenticated" USING (("user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id"))) WITH CHECK (("user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id")));



ALTER TABLE "public"."conversations" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "conversations_insert_authenticated" ON "public"."conversations" FOR INSERT TO "authenticated" WITH CHECK (("created_by" = ( SELECT "app"."current_user_id"() AS "current_user_id")));



CREATE POLICY "conversations_select_member" ON "public"."conversations" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."conversation_members" "m"
  WHERE (("m"."conversation_id" = "conversations"."id") AND ("m"."user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id"))))));



CREATE POLICY "conversations_update_member" ON "public"."conversations" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."conversation_members" "m"
  WHERE (("m"."conversation_id" = "conversations"."id") AND ("m"."user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id")))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."conversation_members" "m"
  WHERE (("m"."conversation_id" = "conversations"."id") AND ("m"."user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id"))))));



ALTER TABLE "public"."edge_rate_limits" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."follows" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "follows_delete_self_or_followee" ON "public"."follows" FOR DELETE TO "authenticated" USING (((( SELECT "app"."current_user_id"() AS "current_user_id") = "follower_id") OR (( SELECT "app"."current_user_id"() AS "current_user_id") = "followee_id")));



CREATE POLICY "follows_insert_self" ON "public"."follows" FOR INSERT TO "authenticated" WITH CHECK (((( SELECT "app"."current_user_id"() AS "current_user_id") = "follower_id") AND (NOT (EXISTS ( SELECT 1
   FROM "public"."blocks" "b"
  WHERE (("b"."blocker_id" = "follows"."followee_id") AND ("b"."blocked_id" = "follows"."follower_id")))))));



CREATE POLICY "follows_select_all" ON "public"."follows" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "kill_switch_comments_write" ON "public"."comments" AS RESTRICTIVE FOR INSERT TO "authenticated" WITH CHECK (( SELECT "app"."switch_on"('social_write'::"text") AS "switch_on"));



CREATE POLICY "kill_switch_follows_write" ON "public"."follows" AS RESTRICTIVE FOR INSERT TO "authenticated" WITH CHECK (( SELECT "app"."switch_on"('social_write'::"text") AS "switch_on"));



CREATE POLICY "kill_switch_work_likes_write" ON "public"."work_likes" AS RESTRICTIVE FOR INSERT TO "authenticated" WITH CHECK (( SELECT "app"."switch_on"('social_write'::"text") AS "switch_on"));



CREATE POLICY "kill_switch_work_versions_write" ON "public"."work_versions" AS RESTRICTIVE FOR INSERT TO "authenticated" WITH CHECK (( SELECT "app"."switch_on"('uploads'::"text") AS "switch_on"));



CREATE POLICY "kill_switch_works_update" ON "public"."works" AS RESTRICTIVE FOR UPDATE TO "authenticated" USING (( SELECT "app"."switch_on"('uploads'::"text") AS "switch_on")) WITH CHECK (( SELECT "app"."switch_on"('uploads'::"text") AS "switch_on"));



CREATE POLICY "kill_switch_works_write" ON "public"."works" AS RESTRICTIVE FOR INSERT TO "authenticated" WITH CHECK (( SELECT "app"."switch_on"('uploads'::"text") AS "switch_on"));



ALTER TABLE "public"."live_participants" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "live_participants_insert_self" ON "public"."live_participants" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id")));



CREATE POLICY "live_participants_select" ON "public"."live_participants" FOR SELECT TO "authenticated" USING ((("user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id")) OR (EXISTS ( SELECT 1
   FROM "public"."live_sessions" "s"
  WHERE (("s"."id" = "live_participants"."session_id") AND ("s"."host_id" = ( SELECT "app"."current_user_id"() AS "current_user_id")))))));



CREATE POLICY "live_participants_update_self" ON "public"."live_participants" FOR UPDATE TO "authenticated" USING (("user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id"))) WITH CHECK (("user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id")));



ALTER TABLE "public"."live_sessions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "live_sessions_delete_host" ON "public"."live_sessions" FOR DELETE TO "authenticated" USING (("host_id" = ( SELECT "app"."current_user_id"() AS "current_user_id")));



CREATE POLICY "live_sessions_insert_host" ON "public"."live_sessions" FOR INSERT TO "authenticated" WITH CHECK (("host_id" = ( SELECT "app"."current_user_id"() AS "current_user_id")));



CREATE POLICY "live_sessions_select" ON "public"."live_sessions" FOR SELECT TO "authenticated", "anon" USING ((("status" = 'live'::"text") OR ("status" = 'scheduled'::"text") OR ("host_id" = ( SELECT "app"."current_user_id"() AS "current_user_id")) OR (EXISTS ( SELECT 1
   FROM "public"."live_participants" "p"
  WHERE (("p"."session_id" = "live_sessions"."id") AND ("p"."user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id")))))));



CREATE POLICY "live_sessions_update_host" ON "public"."live_sessions" FOR UPDATE TO "authenticated" USING (("host_id" = ( SELECT "app"."current_user_id"() AS "current_user_id"))) WITH CHECK (("host_id" = ( SELECT "app"."current_user_id"() AS "current_user_id")));



ALTER TABLE "public"."mentions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "mentions_insert_self" ON "public"."mentions" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "app"."current_user_id"() AS "current_user_id") = "actor_id"));



CREATE POLICY "mentions_select_party" ON "public"."mentions" FOR SELECT TO "authenticated" USING (((( SELECT "app"."current_user_id"() AS "current_user_id") = "mentioned_user_id") OR (( SELECT "app"."current_user_id"() AS "current_user_id") = "actor_id")));



ALTER TABLE "public"."messages" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "messages_delete_sender" ON "public"."messages" FOR DELETE TO "authenticated" USING (("sender_id" = ( SELECT "app"."current_user_id"() AS "current_user_id")));



CREATE POLICY "messages_insert_member" ON "public"."messages" FOR INSERT TO "authenticated" WITH CHECK ((("sender_id" = ( SELECT "app"."current_user_id"() AS "current_user_id")) AND (EXISTS ( SELECT 1
   FROM "public"."conversation_members" "m"
  WHERE (("m"."conversation_id" = "messages"."conversation_id") AND ("m"."user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id")))))));



CREATE POLICY "messages_select_member" ON "public"."messages" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."conversation_members" "m"
  WHERE (("m"."conversation_id" = "messages"."conversation_id") AND ("m"."user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id"))))));



CREATE POLICY "messages_update_sender" ON "public"."messages" FOR UPDATE TO "authenticated" USING (("sender_id" = ( SELECT "app"."current_user_id"() AS "current_user_id"))) WITH CHECK (("sender_id" = ( SELECT "app"."current_user_id"() AS "current_user_id")));



ALTER TABLE "public"."notification_settings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "notification_settings_self_all" ON "public"."notification_settings" TO "authenticated" USING ((( SELECT "app"."current_user_id"() AS "current_user_id") = "user_id")) WITH CHECK ((( SELECT "app"."current_user_id"() AS "current_user_id") = "user_id"));



ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "notifications_delete_self" ON "public"."notifications" FOR DELETE TO "authenticated" USING ((( SELECT "app"."current_user_id"() AS "current_user_id") = "recipient_id"));



CREATE POLICY "notifications_select_self" ON "public"."notifications" FOR SELECT TO "authenticated" USING ((( SELECT "app"."current_user_id"() AS "current_user_id") = "recipient_id"));



CREATE POLICY "notifications_update_self" ON "public"."notifications" FOR UPDATE TO "authenticated" USING ((( SELECT "app"."current_user_id"() AS "current_user_id") = "recipient_id")) WITH CHECK ((( SELECT "app"."current_user_id"() AS "current_user_id") = "recipient_id"));



ALTER TABLE "public"."pending_password_resets" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pending_signups" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "profiles_insert_self" ON "public"."profiles" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "app"."current_user_id"() AS "current_user_id") = "id"));



CREATE POLICY "profiles_select_public" ON "public"."profiles" FOR SELECT TO "authenticated", "anon" USING (((NOT "is_private") OR (( SELECT "app"."current_user_id"() AS "current_user_id") = "id")));



CREATE POLICY "profiles_update_self" ON "public"."profiles" FOR UPDATE TO "authenticated" USING ((( SELECT "app"."current_user_id"() AS "current_user_id") = "id")) WITH CHECK ((( SELECT "app"."current_user_id"() AS "current_user_id") = "id"));



ALTER TABLE "public"."projects" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "projects_delete_own" ON "public"."projects" FOR DELETE TO "authenticated" USING ((( SELECT "app"."current_user_id"() AS "current_user_id") = "user_id"));



CREATE POLICY "projects_insert_own" ON "public"."projects" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "app"."current_user_id"() AS "current_user_id") = "user_id"));



CREATE POLICY "projects_select_visible" ON "public"."projects" FOR SELECT TO "authenticated", "anon" USING ((("visibility" = 'public'::"text") OR (( SELECT "app"."current_user_id"() AS "current_user_id") = "user_id")));



CREATE POLICY "projects_update_own" ON "public"."projects" FOR UPDATE TO "authenticated" USING ((( SELECT "app"."current_user_id"() AS "current_user_id") = "user_id")) WITH CHECK ((( SELECT "app"."current_user_id"() AS "current_user_id") = "user_id"));



ALTER TABLE "public"."reports" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "reports_insert_self" ON "public"."reports" FOR INSERT TO "authenticated" WITH CHECK (((( SELECT "app"."current_user_id"() AS "current_user_id") = "reporter_id") AND ("admin_notes" IS NULL) AND ("resolved_by" IS NULL) AND ("resolved_at" IS NULL) AND ("status" = 'pending'::"text")));



CREATE POLICY "reports_select_self" ON "public"."reports" FOR SELECT TO "authenticated" USING ((( SELECT "app"."current_user_id"() AS "current_user_id") = "reporter_id"));



ALTER TABLE "public"."rls_policy_snapshot" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."scans" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "scans_owner_all" ON "public"."scans" TO "authenticated" USING ((( SELECT "app"."current_user_id"() AS "current_user_id") = "user_id")) WITH CHECK ((( SELECT "app"."current_user_id"() AS "current_user_id") = "user_id"));



ALTER TABLE "public"."tags" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "tags_insert_authenticated" ON "public"."tags" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "tags_select_all" ON "public"."tags" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."work_bookmarks" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "work_bookmarks_self_all" ON "public"."work_bookmarks" TO "authenticated" USING ((( SELECT "app"."current_user_id"() AS "current_user_id") = "user_id")) WITH CHECK ((( SELECT "app"."current_user_id"() AS "current_user_id") = "user_id"));



ALTER TABLE "public"."work_likes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "work_likes_delete_self" ON "public"."work_likes" FOR DELETE TO "authenticated" USING ((( SELECT "app"."current_user_id"() AS "current_user_id") = "user_id"));



CREATE POLICY "work_likes_insert_self" ON "public"."work_likes" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "app"."current_user_id"() AS "current_user_id") = "user_id"));



CREATE POLICY "work_likes_select_visible" ON "public"."work_likes" FOR SELECT TO "authenticated", "anon" USING ((EXISTS ( SELECT 1
   FROM "public"."works" "w"
  WHERE (("w"."id" = "work_likes"."work_id") AND ((("w"."visibility" = 'public'::"text") AND ("w"."moderation_status" = 'ok'::"text") AND ("w"."deleted_at" IS NULL)) OR ("w"."user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id")))))));



ALTER TABLE "public"."work_tags" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "work_tags_owner_modify" ON "public"."work_tags" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."works" "w"
  WHERE (("w"."id" = "work_tags"."work_id") AND ("w"."user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id")))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."works" "w"
  WHERE (("w"."id" = "work_tags"."work_id") AND ("w"."user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id"))))));



CREATE POLICY "work_tags_select_visible" ON "public"."work_tags" FOR SELECT TO "authenticated", "anon" USING ((EXISTS ( SELECT 1
   FROM "public"."works" "w"
  WHERE (("w"."id" = "work_tags"."work_id") AND ((("w"."visibility" = 'public'::"text") AND ("w"."moderation_status" = 'ok'::"text") AND ("w"."deleted_at" IS NULL)) OR ("w"."user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id")))))));



ALTER TABLE "public"."work_versions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "work_versions_owner_modify" ON "public"."work_versions" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."works" "w"
  WHERE (("w"."id" = "work_versions"."work_id") AND ("w"."user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id")))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."works" "w"
  WHERE (("w"."id" = "work_versions"."work_id") AND ("w"."user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id"))))));



CREATE POLICY "work_versions_select_visible" ON "public"."work_versions" FOR SELECT TO "authenticated", "anon" USING ((EXISTS ( SELECT 1
   FROM "public"."works" "w"
  WHERE (("w"."id" = "work_versions"."work_id") AND ((("w"."visibility" = 'public'::"text") AND ("w"."moderation_status" = 'ok'::"text") AND ("w"."deleted_at" IS NULL)) OR ("w"."user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id")))))));



ALTER TABLE "public"."work_views" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "work_views_select_workowner" ON "public"."work_views" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."works" "w"
  WHERE (("w"."id" = "work_views"."work_id") AND ("w"."user_id" = ( SELECT "app"."current_user_id"() AS "current_user_id"))))));



ALTER TABLE "public"."works" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "works_delete_own" ON "public"."works" FOR DELETE TO "authenticated" USING ((( SELECT "app"."current_user_id"() AS "current_user_id") = "user_id"));



CREATE POLICY "works_no_client_insert" ON "public"."works" AS RESTRICTIVE FOR INSERT TO "authenticated", "anon" WITH CHECK (false);



CREATE POLICY "works_select_visible" ON "public"."works" FOR SELECT TO "authenticated", "anon" USING (((("visibility" = 'public'::"text") AND ("moderation_status" = 'ok'::"text") AND ("deleted_at" IS NULL)) OR (( SELECT "app"."current_user_id"() AS "current_user_id") = "user_id")));



CREATE POLICY "works_update_own" ON "public"."works" FOR UPDATE TO "authenticated" USING ((( SELECT "app"."current_user_id"() AS "current_user_id") = "user_id")) WITH CHECK ((( SELECT "app"."current_user_id"() AS "current_user_id") = "user_id"));





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "app" TO "anon";
GRANT USAGE ON SCHEMA "app" TO "authenticated";
GRANT USAGE ON SCHEMA "app" TO "service_role";






GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON FUNCTION "app"."current_user_id"() TO "anon";
GRANT ALL ON FUNCTION "app"."current_user_id"() TO "authenticated";
GRANT ALL ON FUNCTION "app"."current_user_id"() TO "service_role";



REVOKE ALL ON FUNCTION "app"."purge_stale_staging"() FROM PUBLIC;
GRANT ALL ON FUNCTION "app"."purge_stale_staging"() TO "service_role";



REVOKE ALL ON FUNCTION "app"."set_switch"("p_key" "text", "p_enabled" boolean, "p_reason" "text", "p_by" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "app"."set_switch"("p_key" "text", "p_enabled" boolean, "p_reason" "text", "p_by" "text") TO "service_role";



REVOKE ALL ON FUNCTION "app"."switch_on"("p_key" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "app"."switch_on"("p_key" "text") TO "anon";
GRANT ALL ON FUNCTION "app"."switch_on"("p_key" "text") TO "authenticated";
GRANT ALL ON FUNCTION "app"."switch_on"("p_key" "text") TO "service_role";











































































































































































REVOKE ALL ON FUNCTION "public"."admin_set_work_moderation"("p_work_id" "uuid", "p_status" "text", "p_reason" "text", "p_actor" "uuid", "p_operator" "text", "p_ip" "text", "p_user_agent" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_set_work_moderation"("p_work_id" "uuid", "p_status" "text", "p_reason" "text", "p_actor" "uuid", "p_operator" "text", "p_ip" "text", "p_user_agent" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."bump_collection_works_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."bump_collection_works_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."bump_collection_works_count"() TO "service_role";



GRANT ALL ON FUNCTION "public"."bump_comment_likes_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."bump_comment_likes_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."bump_comment_likes_count"() TO "service_role";



GRANT ALL ON FUNCTION "public"."bump_profile_follow_counts"() TO "anon";
GRANT ALL ON FUNCTION "public"."bump_profile_follow_counts"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."bump_profile_follow_counts"() TO "service_role";



GRANT ALL ON FUNCTION "public"."bump_profile_works_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."bump_profile_works_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."bump_profile_works_count"() TO "service_role";



GRANT ALL ON FUNCTION "public"."bump_tag_works_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."bump_tag_works_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."bump_tag_works_count"() TO "service_role";



GRANT ALL ON FUNCTION "public"."bump_work_bookmarks_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."bump_work_bookmarks_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."bump_work_bookmarks_count"() TO "service_role";



GRANT ALL ON FUNCTION "public"."bump_work_comments_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."bump_work_comments_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."bump_work_comments_count"() TO "service_role";



GRANT ALL ON FUNCTION "public"."bump_work_likes_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."bump_work_likes_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."bump_work_likes_count"() TO "service_role";



GRANT ALL ON FUNCTION "public"."bump_work_views_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."bump_work_views_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."bump_work_views_count"() TO "service_role";



GRANT ALL ON FUNCTION "public"."cascade_block_unfollow"() TO "anon";
GRANT ALL ON FUNCTION "public"."cascade_block_unfollow"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."cascade_block_unfollow"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."consume_rate_limit"("p_key" "text", "p_limit" integer, "p_window_seconds" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."consume_rate_limit"("p_key" "text", "p_limit" integer, "p_window_seconds" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."consume_reset_otp_attempt"("p_email" "text", "p_max_attempts" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."consume_reset_otp_attempt"("p_email" "text", "p_max_attempts" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."consume_signup_otp_attempt"("p_email" "text", "p_max_attempts" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."consume_signup_otp_attempt"("p_email" "text", "p_max_attempts" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."guard_profile_identity_columns"() TO "anon";
GRANT ALL ON FUNCTION "public"."guard_profile_identity_columns"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."guard_profile_identity_columns"() TO "service_role";



GRANT ALL ON FUNCTION "public"."guard_quarantine_stays_private"() TO "anon";
GRANT ALL ON FUNCTION "public"."guard_quarantine_stays_private"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."guard_quarantine_stays_private"() TO "service_role";



GRANT ALL ON FUNCTION "public"."guard_work_content_columns"() TO "anon";
GRANT ALL ON FUNCTION "public"."guard_work_content_columns"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."guard_work_content_columns"() TO "service_role";



GRANT ALL ON FUNCTION "public"."guard_work_moderation_columns"() TO "anon";
GRANT ALL ON FUNCTION "public"."guard_work_moderation_columns"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."guard_work_moderation_columns"() TO "service_role";



GRANT ALL ON FUNCTION "public"."guard_work_moderation_delete"() TO "anon";
GRANT ALL ON FUNCTION "public"."guard_work_moderation_delete"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."guard_work_moderation_delete"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."purge_expired_audit_logs"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."purge_expired_audit_logs"() TO "service_role";



GRANT ALL ON FUNCTION "public"."record_work_view"("p_work_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."record_work_view"("p_work_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."record_work_view"("p_work_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "anon";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."touch_conversation_last_message"() TO "anon";
GRANT ALL ON FUNCTION "public"."touch_conversation_last_message"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."touch_conversation_last_message"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."uploads_enabled"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."uploads_enabled"() TO "service_role";
























GRANT ALL ON TABLE "public"."audit_logs" TO "anon";
GRANT ALL ON TABLE "public"."audit_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."audit_logs" TO "service_role";



GRANT ALL ON SEQUENCE "public"."audit_logs_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."audit_logs_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."audit_logs_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."blocks" TO "anon";
GRANT ALL ON TABLE "public"."blocks" TO "authenticated";
GRANT ALL ON TABLE "public"."blocks" TO "service_role";



GRANT ALL ON TABLE "public"."collection_works" TO "anon";
GRANT ALL ON TABLE "public"."collection_works" TO "authenticated";
GRANT ALL ON TABLE "public"."collection_works" TO "service_role";



GRANT ALL ON TABLE "public"."collections" TO "anon";
GRANT ALL ON TABLE "public"."collections" TO "authenticated";
GRANT ALL ON TABLE "public"."collections" TO "service_role";



GRANT ALL ON TABLE "public"."comment_likes" TO "anon";
GRANT ALL ON TABLE "public"."comment_likes" TO "authenticated";
GRANT ALL ON TABLE "public"."comment_likes" TO "service_role";



GRANT ALL ON TABLE "public"."comments" TO "anon";
GRANT ALL ON TABLE "public"."comments" TO "authenticated";
GRANT ALL ON TABLE "public"."comments" TO "service_role";



GRANT ALL ON TABLE "public"."conversation_members" TO "anon";
GRANT ALL ON TABLE "public"."conversation_members" TO "authenticated";
GRANT ALL ON TABLE "public"."conversation_members" TO "service_role";



GRANT ALL ON TABLE "public"."conversations" TO "anon";
GRANT ALL ON TABLE "public"."conversations" TO "authenticated";
GRANT ALL ON TABLE "public"."conversations" TO "service_role";



GRANT ALL ON TABLE "public"."edge_rate_limits" TO "anon";
GRANT ALL ON TABLE "public"."edge_rate_limits" TO "authenticated";
GRANT ALL ON TABLE "public"."edge_rate_limits" TO "service_role";



GRANT ALL ON TABLE "public"."follows" TO "anon";
GRANT ALL ON TABLE "public"."follows" TO "authenticated";
GRANT ALL ON TABLE "public"."follows" TO "service_role";



GRANT ALL ON TABLE "public"."live_participants" TO "anon";
GRANT ALL ON TABLE "public"."live_participants" TO "authenticated";
GRANT ALL ON TABLE "public"."live_participants" TO "service_role";



GRANT ALL ON TABLE "public"."live_sessions" TO "anon";
GRANT ALL ON TABLE "public"."live_sessions" TO "authenticated";
GRANT ALL ON TABLE "public"."live_sessions" TO "service_role";



GRANT ALL ON TABLE "public"."mentions" TO "anon";
GRANT ALL ON TABLE "public"."mentions" TO "authenticated";
GRANT ALL ON TABLE "public"."mentions" TO "service_role";



GRANT ALL ON SEQUENCE "public"."mentions_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."mentions_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."mentions_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."messages" TO "anon";
GRANT ALL ON TABLE "public"."messages" TO "authenticated";
GRANT ALL ON TABLE "public"."messages" TO "service_role";



GRANT ALL ON SEQUENCE "public"."messages_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."messages_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."messages_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."notification_settings" TO "anon";
GRANT ALL ON TABLE "public"."notification_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."notification_settings" TO "service_role";



GRANT ALL ON TABLE "public"."notifications" TO "anon";
GRANT ALL ON TABLE "public"."notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."notifications" TO "service_role";



GRANT ALL ON SEQUENCE "public"."notifications_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."notifications_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."notifications_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."pending_password_resets" TO "anon";
GRANT ALL ON TABLE "public"."pending_password_resets" TO "authenticated";
GRANT ALL ON TABLE "public"."pending_password_resets" TO "service_role";



GRANT ALL ON TABLE "public"."pending_signups" TO "anon";
GRANT ALL ON TABLE "public"."pending_signups" TO "authenticated";
GRANT ALL ON TABLE "public"."pending_signups" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."projects" TO "anon";
GRANT ALL ON TABLE "public"."projects" TO "authenticated";
GRANT ALL ON TABLE "public"."projects" TO "service_role";



GRANT ALL ON TABLE "public"."reports" TO "anon";
GRANT ALL ON TABLE "public"."reports" TO "authenticated";
GRANT ALL ON TABLE "public"."reports" TO "service_role";



GRANT ALL ON SEQUENCE "public"."reports_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."reports_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."reports_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."rls_policy_snapshot" TO "anon";
GRANT ALL ON TABLE "public"."rls_policy_snapshot" TO "authenticated";
GRANT ALL ON TABLE "public"."rls_policy_snapshot" TO "service_role";



GRANT ALL ON SEQUENCE "public"."rls_policy_snapshot_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."rls_policy_snapshot_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."rls_policy_snapshot_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."scans" TO "anon";
GRANT ALL ON TABLE "public"."scans" TO "authenticated";
GRANT ALL ON TABLE "public"."scans" TO "service_role";



GRANT ALL ON TABLE "public"."tags" TO "anon";
GRANT ALL ON TABLE "public"."tags" TO "authenticated";
GRANT ALL ON TABLE "public"."tags" TO "service_role";



GRANT ALL ON TABLE "public"."work_bookmarks" TO "anon";
GRANT ALL ON TABLE "public"."work_bookmarks" TO "authenticated";
GRANT ALL ON TABLE "public"."work_bookmarks" TO "service_role";



GRANT ALL ON TABLE "public"."work_likes" TO "anon";
GRANT ALL ON TABLE "public"."work_likes" TO "authenticated";
GRANT ALL ON TABLE "public"."work_likes" TO "service_role";



GRANT ALL ON TABLE "public"."work_tags" TO "anon";
GRANT ALL ON TABLE "public"."work_tags" TO "authenticated";
GRANT ALL ON TABLE "public"."work_tags" TO "service_role";



GRANT ALL ON TABLE "public"."work_versions" TO "anon";
GRANT ALL ON TABLE "public"."work_versions" TO "authenticated";
GRANT ALL ON TABLE "public"."work_versions" TO "service_role";



GRANT ALL ON TABLE "public"."work_views" TO "anon";
GRANT ALL ON TABLE "public"."work_views" TO "authenticated";
GRANT ALL ON TABLE "public"."work_views" TO "service_role";



GRANT ALL ON SEQUENCE "public"."work_views_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."work_views_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."work_views_id_seq" TO "service_role";



GRANT SELECT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."works" TO "anon";
GRANT SELECT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."works" TO "authenticated";
GRANT ALL ON TABLE "public"."works" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";



































