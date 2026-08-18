// admin-moderate-work
// ----------------------------------------------------------------------
// The enforcement half of content moderation: takes a work down for real,
// or restores it.
//
// Why this exists as a function instead of pure SQL:
//
//   1. Deleting/moving a storage object CANNOT be done from SQL.
//      Supabase docs: "Deleting objects should always be done via the
//      Storage API and NOT via a SQL query" — a SQL DELETE on
//      storage.objects only drops the metadata row and orphans the file
//      in S3, leaving it downloadable.
//
//   2. The `works` and `thumbnails` buckets are PUBLIC, and a public
//      bucket bypasses RLS for /object/public/ reads. So tightening the
//      `works_select_public` policy (as 20260817011000 did) does NOT
//      stop a removed work's file from resolving. The object has to
//      physically leave the public bucket. That correction is the whole
//      reason this function exists.
//
//   3. Supabase Smart CDN does not purge on token expiry or policy
//      change — "Deleting the object invalidates all cached entries for
//      that object across all tokens" is the only hard revocation.
//      Moving the object out achieves the same invalidation.
//
// Auth: service_role only. There is no admin-user concept yet, so the
// caller must present the service_role key as the bearer token. This is
// deliberately the narrowest possible gate — when an in-app admin
// console arrives, add an admins table and widen it there, not here.
//
// Deploy with --no-verify-jwt so the service_role key reaches us as a
// plain bearer token instead of being pre-validated as a user JWT.

import { createClient } from 'jsr:@supabase/supabase-js@2.112.3';
import { corsHeaders, jsonResponse, consumeRateLimit } from '../_shared/cors.ts';

const QUARANTINE_BUCKET = 'quarantine';

type AssetRef = { bucket: string; path: string };

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  if (req.method !== 'POST') {
    return jsonResponse({ error: 'method_not_allowed' }, 405);
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceKey) {
    return jsonResponse({ error: 'server_misconfigured' }, 500);
  }

  // Gate: the bearer token must BE the service_role key. Compared with a
  // constant-time-ish check to avoid leaking prefix length via timing.
  const bearer = (req.headers.get('Authorization') ?? '')
    .replace(/^Bearer\s+/i, '')
    .trim();
  if (!bearer || !timingSafeEqual(bearer, serviceKey)) {
    return jsonResponse({ error: 'forbidden' }, 403);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: 'invalid_json' }, 400);
  }

  const workId = typeof body.work_id === 'string' ? body.work_id.trim() : '';
  const status = typeof body.status === 'string' ? body.status.trim() : '';
  const reason = typeof body.reason === 'string' ? body.reason.trim() : null;

  if (!isUuid(workId)) {
    return jsonResponse({ error: 'invalid_work_id' }, 400);
  }
  if (!['ok', 'under_review', 'removed'].includes(status)) {
    return jsonResponse({ error: 'invalid_status' }, 400);
  }

  const supabase = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false },
  });

  // Rate limit even though the caller already holds the service_role key.
  // The key is a bearer secret with no identity behind it — if it ever
  // leaks, this is the difference between "someone quietly took down every
  // work in the catalogue" and "someone got 200 takedowns in before it
  // tripped". Keyed by operator when declared so one tool misbehaving
  // doesn't starve the others.
  const rlOperator = typeof body.operator === 'string' && body.operator.trim()
    ? body.operator.trim().slice(0, 60)
    : 'unknown';
  if (!await consumeRateLimit(supabase, `moderate:${rlOperator}`, 200, 3600)) {
    return jsonResponse({
      error: 'rate_limited',
      message: 'Moderation rate limit hit. If this is legitimate bulk work, raise the cap deliberately.',
    }, 429);
  }

  // ── collect every storage object this work owns ─────────────────────
  // works: model + thumbnail + preview video
  // work_versions: model + thumbnail per version
  // Buckets are inferred from the column, matching how the app writes
  // them (publish_service.dart -> 'works'; community_service.dart
  // uploadAndSetThumbnail -> 'thumbnails').
  const { data: work, error: workErr } = await supabase
    .from('works')
    .select('id, model_storage_path, thumbnail_storage_path, preview_video_path')
    .eq('id', workId)
    .maybeSingle();
  if (workErr) {
    return jsonResponse({ error: 'work_lookup_failed', detail: workErr.message }, 500);
  }
  if (!work) {
    return jsonResponse({ error: 'work_not_found' }, 404);
  }

  const { data: versions, error: verErr } = await supabase
    .from('work_versions')
    .select('model_storage_path, thumbnail_storage_path')
    .eq('work_id', workId);
  if (verErr) {
    return jsonResponse({ error: 'versions_lookup_failed', detail: verErr.message }, 500);
  }

  const assets: AssetRef[] = [];
  const push = (bucket: string, path: unknown) => {
    if (typeof path === 'string' && path.length > 0) assets.push({ bucket, path });
  };
  push('works', work.model_storage_path);
  push('thumbnails', work.thumbnail_storage_path);
  push('works', work.preview_video_path);
  for (const v of versions ?? []) {
    push('works', v.model_storage_path);
    push('thumbnails', v.thumbnail_storage_path);
  }

  // ── move objects ────────────────────────────────────────────────────
  // removed  → public bucket ..... quarantine (private, policy-less)
  // ok/review → quarantine ....... back to its public bucket
  //
  // Quarantine key embeds the source bucket so restore is unambiguous:
  //   {work_id}/{source_bucket}/{original_path}
  const moves: Array<{ asset: AssetRef; ok: boolean; detail?: string; skipped?: boolean }> = [];
  const takingDown = status === 'removed';

  for (const asset of assets) {
    const qPath = `${workId}/${asset.bucket}/${asset.path}`;
    const from = takingDown
      ? { bucket: asset.bucket, path: asset.path }
      : { bucket: QUARANTINE_BUCKET, path: qPath };
    const to = takingDown
      ? { bucket: QUARANTINE_BUCKET, path: qPath }
      : { bucket: asset.bucket, path: asset.path };

    const { error } = await supabase.storage
      .from(from.bucket)
      .move(from.path, to.path, { destinationBucket: to.bucket });

    if (!error) {
      moves.push({ asset, ok: true });
      continue;
    }
    // Idempotency: a re-run finds the object already on the far side.
    // "not found" on the source is therefore success, not failure —
    // but only if the destination actually holds it.
    const msg = error.message ?? String(error);
    if (/not.?found|does not exist|Object not found/i.test(msg)) {
      const { data: probe } = await supabase.storage
        .from(to.bucket)
        .list(dirOf(to.path), { search: baseOf(to.path), limit: 1 });
      if (probe && probe.length > 0) {
        moves.push({ asset, ok: true, skipped: true, detail: 'already moved' });
        continue;
      }
    }
    moves.push({ asset, ok: false, detail: msg });
  }

  const failed = moves.filter((m) => !m.ok);

  // 🔑 Fail closed on takedown: if any object could not be moved out of a
  // public bucket, do NOT flip the DB status. A work marked `removed`
  // whose file is still publicly downloadable is worse than a work that
  // is honestly still up — it makes the audit log lie and would let us
  // report "removed within 24h" to Apple when we hadn't.
  if (takingDown && failed.length > 0) {
    return jsonResponse({
      error: 'storage_move_failed',
      message: 'Work NOT marked removed: some assets are still public.',
      failed: failed.map((f) => ({ ...f.asset, detail: f.detail })),
    }, 502);
  }

  // ── flip DB state (also writes the audit row, in one transaction) ────
  // Attribution: the service_role key is a bearer secret, not an identity,
  // so there is no auth.uid() to record here. `operator` is whatever the
  // caller declares itself to be — useful for telling tooling apart, but
  // self-reported and therefore not non-repudiable. The IP and user agent
  // are the objective part of the trail.
  const { error: rpcErr } = await supabase.rpc('admin_set_work_moderation', {
    p_work_id: workId,
    p_status: status,
    p_reason: reason,
    p_operator: typeof body.operator === 'string'
      ? body.operator.trim().slice(0, 120)
      : null,
    p_ip: req.headers.get('x-forwarded-for'),
    p_user_agent: req.headers.get('user-agent'),
  });
  if (rpcErr) {
    return jsonResponse({
      error: 'moderation_rpc_failed',
      detail: rpcErr.message,
      // Storage already moved — surface it so the operator can reconcile
      // instead of silently diverging.
      storage_moved: moves.filter((m) => m.ok).length,
    }, 500);
  }

  // Record exactly which objects moved, so an appeal/restore is possible
  // and so the takedown is provable after the fact.
  await supabase.from('audit_logs').insert({
    // Same attribution caveat as the RPC above: no user identity behind a
    // service_role call, so IP/UA carry the objective part.
    actor_id: null,
    action: takingDown ? 'admin.work_assets_quarantined' : 'admin.work_assets_restored',
    target_type: 'work',
    target_id: workId,
    ip_address: firstIp(req.headers.get('x-forwarded-for')),
    user_agent: (req.headers.get('user-agent') ?? '').slice(0, 500) || null,
    metadata: {
      status,
      reason,
      operator: typeof body.operator === 'string'
        ? body.operator.trim().slice(0, 120)
        : null,
      assets: moves.map((m) => ({
        bucket: m.asset.bucket,
        path: m.asset.path,
        quarantine_path: `${workId}/${m.asset.bucket}/${m.asset.path}`,
        ok: m.ok,
        skipped: m.skipped ?? false,
      })),
      // Restore on appeal is possible because we keep the bytes; nothing
      // expires the quarantine bucket automatically.
      reversible: true,
    },
  });

  return jsonResponse({
    ok: true,
    work_id: workId,
    status,
    assets_moved: moves.filter((m) => m.ok && !m.skipped).length,
    assets_already_moved: moves.filter((m) => m.skipped).length,
    assets_failed: failed.length,
    failed: failed.map((f) => ({ ...f.asset, detail: f.detail })),
  });
});

function isUuid(v: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(v);
}

function dirOf(p: string): string {
  const i = p.lastIndexOf('/');
  return i < 0 ? '' : p.slice(0, i);
}

function baseOf(p: string): string {
  const i = p.lastIndexOf('/');
  return i < 0 ? p : p.slice(i + 1);
}

/// Length-independent comparison so a wrong key can't be probed by
/// measuring how early the comparison bails out.
function timingSafeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const ab = enc.encode(a);
  const bb = enc.encode(b);
  let diff = ab.length ^ bb.length;
  const n = Math.max(ab.length, bb.length);
  for (let i = 0; i < n; i++) {
    diff |= (ab[i] ?? 0) ^ (bb[i] ?? 0);
  }
  return diff === 0;
}

/// x-forwarded-for may be a comma-separated chain; the first entry is the
/// original client. Returns null for anything unparseable so a malformed
/// header can never fail the insert (attribution matters less than the
/// action being recorded at all).
function firstIp(raw: string | null): string | null {
  if (!raw) return null;
  const first = raw.split(',')[0]?.trim();
  return first && first.length > 0 ? first : null;
}
