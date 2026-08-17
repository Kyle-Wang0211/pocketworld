// signup-verify
// ----------------------------------------------------------------------
// Finish a strict-confirmation signup. Client POSTs { email, otp }; we:
//
//   1. Look up the pending_signups row.
//   2. Reject if expired (410), missing (404), or attempts ≥ 5 (429).
//   3. Compare SHA-256(otp) to the stored hash. On mismatch, bump
//      attempts and return 401.
//   4. On match, call admin.createUser with email_confirm:true so the
//      user can immediately sign in with email+password from Dart.
//   5. Delete the pending row.
//
// The client follows up with supabase.auth.signInWithPassword(email,
// password) — Dart still has the password in memory, so we don't need
// to mint a token here.
//
// Required Supabase secrets:
//   • SUPABASE_URL                       (auto)
//   • SUPABASE_SERVICE_ROLE_KEY          (auto)

import { createClient } from 'jsr:@supabase/supabase-js@2';
import { corsHeaders, jsonResponse, sha256Hex } from '../_shared/cors.ts';

const MAX_ATTEMPTS = 5;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  if (req.method !== 'POST') {
    return jsonResponse({ error: 'method_not_allowed' }, 405);
  }

  let body: { email?: string; otp?: string };
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: 'invalid_json' }, 400);
  }

  const email = (body.email ?? '').trim().toLowerCase();
  const otp = (body.otp ?? '').trim();
  if (!email.includes('@') || !/^\d{4,8}$/.test(otp)) {
    return jsonResponse({ error: 'invalid_input' }, 400);
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { auth: { persistSession: false } },
  );

  // Consume one attempt ATOMICALLY, before comparing anything. The old
  // read-check-write sequence let N concurrent guesses all read
  // attempts=0 and all write back 1, so the 5-attempt cap never actually
  // advanced. See consume_signup_otp_attempt for the single-statement
  // test-and-increment that replaces it.
  const { data: consumed, error: consumeErr } = await supabase
    .rpc('consume_signup_otp_attempt', {
      p_email: email,
      p_max_attempts: MAX_ATTEMPTS,
    })
    .maybeSingle();

  if (consumeErr) {
    return jsonResponse(
      { error: 'db_error', detail: consumeErr.message },
      500,
    );
  }
  if (!consumed) {
    return jsonResponse({ error: 'not_found' }, 404);
  }
  switch (consumed.status) {
    case 'ok':
      break;
    case 'expired':
      // Cron will reap this eventually; we just refuse here.
      return jsonResponse({ error: 'expired' }, 410);
    case 'too_many_attempts':
      return jsonResponse({ error: 'too_many_attempts' }, 429);
    default:
      return jsonResponse({ error: 'not_found' }, 404);
  }

  const inputHash = await sha256Hex(otp);
  if (inputHash !== consumed.otp_hash) {
    // The attempt was already consumed above — nothing to bump here.
    return jsonResponse({ error: 'invalid_code' }, 401);
  }

  // OTP good — create the real user, pre-confirmed.
  const { data: created, error: createErr } = await supabase.auth.admin
    .createUser({
      email,
      password: consumed.password,
      email_confirm: true,
      user_metadata: {
        ...(consumed.display_name
          ? { display_name: consumed.display_name }
          : {}),
        locale: consumed.locale,
      },
    });
  if (createErr || !created.user) {
    return jsonResponse(
      { error: 'create_failed', detail: createErr?.message ?? 'no user' },
      500,
    );
  }

  // Best-effort cleanup; cron will mop up if this fails.
  await supabase.from('pending_signups').delete().eq('email', email);

  return jsonResponse({ ok: true, user_id: created.user.id });
});
