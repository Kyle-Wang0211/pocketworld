// password-reset-verify
// ----------------------------------------------------------------------
// Finish a strict-OTP password reset. Client POSTs { email, otp,
// new_password }; we:
//
//   1. Look up pending_password_resets row.
//   2. Reject if expired (410), missing (404), or attempts ≥ 5 (429).
//   3. Compare SHA-256(otp). On mismatch bump attempts, return 401.
//   4. On match, look up user_id via admin.listUsers, then call
//      admin.updateUserById(user_id, { password: new_password }) to
//      rotate the password.
//   5. Delete the pending row.
//
// The client follows up with supabase.auth.signInWithPassword(email,
// new_password) — yields a real session. No need for us to mint one
// here.

import { createClient } from 'jsr:@supabase/supabase-js@2';
import { corsHeaders, jsonResponse, sha256Hex } from '../_shared/cors.ts';

const MAX_ATTEMPTS = 5;
const MIN_PASSWORD_LENGTH = 8;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  if (req.method !== 'POST') {
    return jsonResponse({ error: 'method_not_allowed' }, 405);
  }

  let body: { email?: string; otp?: string; new_password?: string };
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: 'invalid_json' }, 400);
  }

  const email = (body.email ?? '').trim().toLowerCase();
  const otp = (body.otp ?? '').trim();
  const newPassword = body.new_password ?? '';

  if (!email.includes('@') || !/^\d{4,8}$/.test(otp)) {
    return jsonResponse({ error: 'invalid_input' }, 400);
  }
  if (newPassword.length < MIN_PASSWORD_LENGTH) {
    return jsonResponse({ error: 'weak_password' }, 400);
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { auth: { persistSession: false } },
  );

  // Consume one attempt ATOMICALLY, before comparing anything. The old
  // code read the row, checked the cap, then wrote back attempts+1 from
  // the value it had read — so N concurrent guesses all saw attempts=0,
  // all passed the cap, and all wrote 1. The cap never advanced and the
  // OTP was brute-forceable (= account takeover). The RPC does the test
  // and the increment in one UPDATE ... WHERE attempts < cap RETURNING,
  // so concurrent callers serialise on the row lock.
  const { data: consumed, error: consumeErr } = await supabase
    .rpc('consume_reset_otp_attempt', {
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

  // OTP good — find user_id, rotate password.
  let userId: string | null = null;
  try {
    const { data: list, error } = await supabase.auth.admin.listUsers({
      page: 1,
      perPage: 1000,
    });
    if (error) throw error;
    const found = list.users.find(
      (u) => (u.email ?? '').toLowerCase() === email,
    );
    userId = found?.id ?? null;
  } catch (e) {
    return jsonResponse(
      { error: 'admin_lookup_failed', detail: String(e) },
      500,
    );
  }
  if (!userId) {
    // Edge case: user existed at start time, deleted before verify.
    return jsonResponse({ error: 'not_found' }, 404);
  }

  const { error: updateErr } = await supabase.auth.admin.updateUserById(
    userId,
    { password: newPassword },
  );
  if (updateErr) {
    return jsonResponse(
      { error: 'update_failed', detail: updateErr.message },
      500,
    );
  }

  // Best-effort cleanup; cron will mop up if this fails.
  await supabase.from('pending_password_resets').delete().eq('email', email);

  return jsonResponse({ ok: true });
});
