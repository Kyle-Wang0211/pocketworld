-- Auth hardening: atomic OTP attempt accounting + a generic rate limiter.
--
-- Why: the verify functions did
--     SELECT ... ; if (attempts >= 5) reject; UPDATE SET attempts = <read value> + 1
-- which is a read-modify-write race. N concurrent requests all read
-- attempts=0, all pass the cap check, and all write back 1 (last write
-- wins), so the "5 attempts" cap never advanced past 1. With a 900k OTP
-- space, an uncapped `-start` endpoint to re-open the window, and no
-- rate limit anywhere, that made anonymous password-reset OTP
-- brute-force — i.e. account takeover — practical.
--
-- The fix has to be a single statement that both tests and increments,
-- because PostgREST runs one statement per request and cannot hold a
-- transaction across the read and the write. `UPDATE ... WHERE attempts
-- < cap RETURNING` does exactly that: the row lock serialises concurrent
-- writers, each one sees the previous increment, and the WHERE clause
-- stops handing out attempts once the cap is reached.
--
-- Callers are the Edge Functions only (service_role). EXECUTE is revoked
-- from anon/authenticated because these functions return the OTP hash
-- and, for signup, the pending plaintext password.
--
-- Depends on: 20260429000000_pending_signups.sql
--             20260429010000_pending_password_resets.sql

-- ── OTP attempt consumption ──────────────────────────────────────────
-- Returns exactly one row. `status` is the decision the Edge Function
-- must act on:
--   not_found          — no pending row for this email
--   expired            — TTL elapsed
--   too_many_attempts  — cap already reached (attempt NOT consumed)
--   ok                 — one attempt consumed; compare otp_hash yourself
-- The attempt is consumed BEFORE the hash comparison, deliberately: a
-- wrong guess and a right guess must cost the same, or a racing attacker
-- gets free guesses again.

create or replace function public.consume_signup_otp_attempt(
  p_email text,
  p_max_attempts int default 5
)
returns table (
  status text,
  otp_hash text,
  password text,
  display_name text,
  locale text
)
language plpgsql
security definer
set search_path = public
as $$
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

comment on function public.consume_signup_otp_attempt(text, int) is
  'Atomically consumes one signup OTP attempt. service_role only — returns the OTP hash and pending plaintext password.';

revoke execute on function public.consume_signup_otp_attempt(text, int)
  from public, anon, authenticated;
grant execute on function public.consume_signup_otp_attempt(text, int)
  to service_role;

create or replace function public.consume_reset_otp_attempt(
  p_email text,
  p_max_attempts int default 5
)
returns table (
  status text,
  otp_hash text
)
language plpgsql
security definer
set search_path = public
as $$
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

comment on function public.consume_reset_otp_attempt(text, int) is
  'Atomically consumes one password-reset OTP attempt. service_role only — returns the OTP hash.';

revoke execute on function public.consume_reset_otp_attempt(text, int)
  from public, anon, authenticated;
grant execute on function public.consume_reset_otp_attempt(text, int)
  to service_role;

-- ── generic fixed-window rate limiter ────────────────────────────────
-- Backs the `-start` endpoints, which were completely uncapped: they are
-- deployed with --no-verify-jwt (no credential needed at all), send a
-- Resend email per call, and reset the OTP attempt counter — so they
-- were simultaneously a free mail cannon and the reload lever for the
-- brute-force above.

create table if not exists public.edge_rate_limits (
  bucket_key text primary key,
  window_start timestamptz not null default now(),
  hit_count int not null default 0
);

alter table public.edge_rate_limits enable row level security;
-- No policies: service_role only (it bypasses RLS). Clients must never
-- read this table — it would leak which emails are being used.

create index if not exists edge_rate_limits_window_start_idx
  on public.edge_rate_limits (window_start);

-- Atomic fixed-window consume. Returns true when the call is ALLOWED.
-- The whole decision is one INSERT ... ON CONFLICT DO UPDATE, so
-- concurrent callers serialise on the row lock rather than racing.
create or replace function public.consume_rate_limit(
  p_key text,
  p_limit int,
  p_window_seconds int
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
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

comment on function public.consume_rate_limit(text, int, int) is
  'Fixed-window rate limiter. Returns true if the call is allowed. service_role only.';

revoke execute on function public.consume_rate_limit(text, int, int)
  from public, anon, authenticated;
grant execute on function public.consume_rate_limit(text, int, int)
  to service_role;

-- Sweep stale buckets. pg_cron is already enabled by the pending_signups
-- migration.
do $$
begin
  perform cron.unschedule('cleanup-edge-rate-limits');
exception when others then
  null;
end $$;

select cron.schedule(
  'cleanup-edge-rate-limits',
  '17 * * * *',
  $$delete from public.edge_rate_limits where window_start < now() - interval '1 day'$$
);
