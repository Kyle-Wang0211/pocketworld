// delete-account
// ----------------------------------------------------------------------
// App Store Guideline 5.1.1(v): "If your app supports account creation,
// you must also offer account deletion within the app". Apple further
// requires that it not be a mere deactivation ("people should be able to
// delete the account along with their personal data") and that apps
// outside highly-regulated industries must NOT push users through a
// phone call / email / support flow. So this has to be a real, callable,
// in-app-initiated deletion — which is what this function provides.
//
// Auth, two accepted callers:
//   • the user's own JWT      → deletes that user (the in-app path)
//   • the service_role key + target_user_id → deletes anyone
//     (for GDPR/PIPL erasure requests arriving out-of-band)
//
// ORDER IS LOAD-BEARING. Deleting auth.users cascades to every business
// table (profiles, works, work_versions, scans, comments, likes, blocks,
// follows, …) because they all declare `references auth.users(id) on
// delete cascade`. Storage objects have NO such link and a SQL delete
// would only orphan them. Therefore we must enumerate every storage path
// BEFORE deleting the user — once the cascade fires, the paths are gone
// and the files become unreachable garbage that still counts against
// quota and could still be served from a public bucket.
//
// FAIL POLICY — deliberately the OPPOSITE of admin-moderate-work:
//   admin-moderate-work is fail-CLOSED (if an asset can't leave the
//   public bucket, don't mark the work removed — never let the audit log
//   claim a takedown that didn't happen).
//   delete-account is fail-OPEN on storage (best-effort file removal,
//   but the user IS deleted regardless). Rationale: Apple mandates that
//   the user be able to delete their account; letting one stuck object
//   block that forever would be a worse failure than a leftover file.
//   Every failure is recorded in audit_logs for manual sweeping.

import { createClient } from 'jsr:@supabase/supabase-js@2';
import { corsHeaders, jsonResponse } from '../_shared/cors.ts';

// Buckets whose layout is `{user_id}/...` and can be swept by prefix.
const USER_PREFIXED_BUCKETS = ['avatars', 'works', 'thumbnails', 'scans'];

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
  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false },
  });

  const bearer = (req.headers.get('Authorization') ?? '')
    .replace(/^Bearer\s+/i, '')
    .trim();
  if (!bearer) {
    return jsonResponse({ error: 'missing_authorization' }, 401);
  }

  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch {
    // Body is optional for the self-serve path.
  }

  // ── resolve who is being deleted ─────────────────────────────────────
  let targetUserId: string;
  let viaServiceRole = false;

  if (timingSafeEqual(bearer, serviceKey)) {
    viaServiceRole = true;
    const t = typeof body.target_user_id === 'string' ? body.target_user_id.trim() : '';
    if (!isUuid(t)) {
      return jsonResponse({ error: 'target_user_id_required' }, 400);
    }
    targetUserId = t;
  } else {
    // getUser() validates the token against GoTrue (signature, expiry,
    // revocation) rather than decoding it locally.
    const { data, error } = await admin.auth.getUser(bearer);
    if (error || !data.user) {
      return jsonResponse({ error: 'unauthorized' }, 401);
    }
    targetUserId = data.user.id;
    // Explicit confirmation for the self-serve path so a stray call
    // can't nuke an account. The UI must send this.
    if (body.confirm !== true) {
      return jsonResponse({
        error: 'confirmation_required',
        message: 'Send {"confirm": true} to proceed. This is irreversible.',
      }, 400);
    }
  }

  // ── 1. enumerate EVERY storage object, before touching the user ─────
  const assets: AssetRef[] = [];
  const seen = new Set<string>();
  const push = (bucket: string, raw: unknown) => {
    const path = normalizeStoragePath(raw, bucket);
    if (!path) return;
    const k = `${bucket}::${path}`;
    if (seen.has(k)) return;
    seen.add(k);
    assets.push({ bucket, path });
  };

  // 1a. rows that name their own paths
  const { data: works } = await admin
    .from('works')
    .select('id, model_storage_path, thumbnail_storage_path, preview_video_path')
    .eq('user_id', targetUserId);
  for (const w of works ?? []) {
    push('works', w.model_storage_path);
    push('thumbnails', w.thumbnail_storage_path);
    push('works', w.preview_video_path);
  }

  const workIds = (works ?? []).map((w) => w.id as string);
  if (workIds.length > 0) {
    const { data: versions } = await admin
      .from('work_versions')
      .select('model_storage_path, thumbnail_storage_path')
      .in('work_id', workIds);
    for (const v of versions ?? []) {
      push('works', v.model_storage_path);
      push('thumbnails', v.thumbnail_storage_path);
    }
  }

  const { data: scans } = await admin
    .from('scans')
    .select('raw_storage_path, cover_thumbnail_path')
    .eq('user_id', targetUserId);
  for (const s of scans ?? []) {
    push('scans', s.raw_storage_path);
    push('scans', s.cover_thumbnail_path);
  }

  const { data: profile } = await admin
    .from('profiles')
    .select('avatar_url, banner_url')
    .eq('id', targetUserId)
    .maybeSingle();
  if (profile) {
    push('avatars', profile.avatar_url);
    push('avatars', profile.banner_url);
  }

  // 1b. prefix sweep — catches orphans the DB never knew about (failed
  // publishes, abandoned uploads, files whose row was already deleted).
  for (const bucket of USER_PREFIXED_BUCKETS) {
    for (const p of await listAllUnder(admin, bucket, targetUserId)) {
      push(bucket, p);
    }
  }

  // 1c. quarantine bucket is keyed by {work_id}/{bucket}/{path}, NOT by
  // user id — so it must be swept per work, which is only possible while
  // the works rows still exist. Includes already-removed works.
  for (const wid of workIds) {
    for (const p of await listAllUnder(admin, 'quarantine', wid)) {
      push('quarantine', p);
    }
  }

  // ── 2. delete the files (batched per bucket) ────────────────────────
  const failures: Array<AssetRef & { detail: string }> = [];
  let deletedCount = 0;

  const byBucket = new Map<string, string[]>();
  for (const a of assets) {
    if (!byBucket.has(a.bucket)) byBucket.set(a.bucket, []);
    byBucket.get(a.bucket)!.push(a.path);
  }
  for (const [bucket, paths] of byBucket) {
    for (let i = 0; i < paths.length; i += 100) {
      const chunk = paths.slice(i, i + 100);
      const { error } = await admin.storage.from(bucket).remove(chunk);
      if (error) {
        const detail = error.message ?? String(error);
        for (const p of chunk) failures.push({ bucket, path: p, detail });
      } else {
        deletedCount += chunk.length;
      }
    }
  }

  // ── 3. audit BEFORE the cascade wipes the identity ──────────────────
  // audit_logs intentionally has no FK to auth.users precisely so this
  // row survives the deletion. Only the UUID is retained — no email, no
  // display name — so the record is anonymised by construction while
  // still supporting "was this erasure actually performed?".
  await admin.from('audit_logs').insert({
    // Self-serve deletion has a real identity behind it — record it. Only
    // a service_role-initiated erasure (an out-of-band GDPR/PIPL request)
    // genuinely has no user to attribute to.
    actor_id: viaServiceRole ? null : targetUserId,
    action: 'user.account_deleted',
    target_type: 'user',
    target_id: targetUserId,
    ip_address: firstIp(req.headers.get('x-forwarded-for')),
    user_agent: (req.headers.get('user-agent') ?? '').slice(0, 500) || null,
    metadata: {
      via: viaServiceRole ? 'service_role' : 'self_serve',
      storage_objects_found: assets.length,
      storage_objects_deleted: deletedCount,
      storage_failures: failures,
      works_count: workIds.length,
      // Fail-open on storage is deliberate; see the header comment.
      note: failures.length > 0
        ? 'Account deleted despite storage failures — sweep these manually.'
        : null,
    },
  });

  // ── 4. delete the user; cascades across every business table ────────
  const { error: delErr } = await admin.auth.admin.deleteUser(targetUserId);
  if (delErr) {
    return jsonResponse({
      error: 'user_delete_failed',
      detail: delErr.message,
      // Files are already gone — surface it so this isn't silently
      // half-applied.
      storage_objects_deleted: deletedCount,
    }, 500);
  }

  return jsonResponse({
    ok: true,
    deleted_user_id: targetUserId,
    storage_objects_found: assets.length,
    storage_objects_deleted: deletedCount,
    storage_failures: failures.length,
    failures,
  });
});

/// Recursively list every object under `prefix` in `bucket`.
/// Supabase's list() is single-level and paginated, so directories are
/// walked explicitly. Returns full paths.
async function listAllUnder(
  admin: ReturnType<typeof createClient>,
  bucket: string,
  prefix: string,
): Promise<string[]> {
  const out: string[] = [];
  const queue: string[] = [prefix];
  // Bound the walk: a pathological tree shouldn't hang the function.
  let guard = 0;
  while (queue.length > 0 && guard < 500) {
    guard++;
    const dir = queue.shift()!;
    let offset = 0;
    while (true) {
      const { data, error } = await admin.storage
        .from(bucket)
        .list(dir, { limit: 100, offset });
      if (error || !data || data.length === 0) break;
      for (const entry of data) {
        const full = `${dir}/${entry.name}`;
        // A folder placeholder has no id/metadata.
        if (entry.id === null || entry.id === undefined) {
          queue.push(full);
        } else {
          out.push(full);
        }
      }
      if (data.length < 100) break;
      offset += data.length;
    }
  }
  return out;
}

/// Accepts either a bare storage path (`uid/file.ply`) or a full public
/// URL (what getPublicUrl returns, which is what some columns hold) and
/// returns the bucket-relative path.
function normalizeStoragePath(raw: unknown, bucket: string): string | null {
  if (typeof raw !== 'string') return null;
  const s = raw.trim();
  if (s.length === 0) return null;
  if (!s.startsWith('http')) {
    return s.replace(/^\/+/, '');
  }
  // .../storage/v1/object/public/<bucket>/<path>  (or /sign/, /authenticated/)
  const m = s.match(
    new RegExp(`/storage/v1/object/(?:public|sign|authenticated)/${bucket}/(.+?)(?:\\?|$)`),
  );
  if (!m) return null;
  try {
    return decodeURIComponent(m[1]);
  } catch {
    return m[1];
  }
}

function isUuid(v: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(v);
}

function timingSafeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const ab = enc.encode(a);
  const bb = enc.encode(b);
  let diff = ab.length ^ bb.length;
  const n = Math.max(ab.length, bb.length);
  for (let i = 0; i < n; i++) diff |= (ab[i] ?? 0) ^ (bb[i] ?? 0);
  return diff === 0;
}

/// x-forwarded-for may be a chain; the first entry is the original client.
/// Returns null when unparseable — attribution must never fail the erasure.
function firstIp(raw: string | null): string | null {
  if (!raw) return null;
  const first = raw.split(',')[0]?.trim();
  return first && first.length > 0 ? first : null;
}
