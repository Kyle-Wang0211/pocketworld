// Shared CORS headers for PocketWorld Edge Functions. Permissive by
// design — the Flutter client may run on iOS, macOS, or Android, so
// origin-locking adds noise without security upside (the anon key is
// already public). Service-role-only checks live inside each function.

export const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

export function jsonResponse(
  body: Record<string, unknown>,
  status = 200,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

export async function sha256Hex(input: string): Promise<string> {
  const data = new TextEncoder().encode(input);
  const hash = await crypto.subtle.digest('SHA-256', data);
  return Array.from(new Uint8Array(hash))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

/// Six-digit OTP from the CSPRNG. Rejection-samples so every code in
/// [100000, 999999] is equally likely — taking `% 900000` of a raw
/// 32-bit draw would bias the low end.
export function generateOtp(): string {
  const span = 900000;
  const limit = Math.floor(0xffffffff / span) * span;
  const buf = new Uint32Array(1);
  let draw: number;
  do {
    crypto.getRandomValues(buf);
    draw = buf[0];
  } while (draw >= limit);
  return (100000 + (draw % span)).toString();
}

/// Fixed-window rate limit via the consume_rate_limit RPC. Returns true
/// when the call is allowed.
///
/// Fails OPEN on infrastructure error: a limiter that is itself broken
/// must not lock every user out of signing up or resetting a password.
/// The abuse ceiling this protects is a cost/brute-force concern, not a
/// data-integrity one, so availability wins that trade.
export async function consumeRateLimit(
  // deno-lint-ignore no-explicit-any
  supabase: any,
  key: string,
  limit: number,
  windowSeconds: number,
): Promise<boolean> {
  try {
    const { data, error } = await supabase.rpc('consume_rate_limit', {
      p_key: key,
      p_limit: limit,
      p_window_seconds: windowSeconds,
    });
    if (error) {
      console.warn('rate limit rpc failed', key, error.message);
      return true;
    }
    return data !== false;
  } catch (e) {
    console.warn('rate limit rpc threw', key, String(e));
    return true;
  }
}
