// delete-work
// ----------------------------------------------------------------------
// Author-initiated removal of their own published work.
//
// Apple's UGC rejection letters ask for "a mechanism for users to
// immediately remove posts from the feed" on top of Guideline 1.2's four
// bullets. `works_delete_own` already lets an author delete the row from
// the client — but that alone is NOT a removal:
//
//   • the `works` bucket is public, and a public bucket bypasses RLS on
//     /object/public/ reads, so the .ply stays downloadable by anyone
//     holding (or guessing) the URL after the row is gone;
//   • deleting storage objects cannot be done from SQL at all — a SQL
//     delete only drops the metadata row and orphans the file.
//
// So a correct "delete my post" has to run server-side with the Storage
// API. That is this function.
//
// Auth: the author's own JWT. Ownership is re-checked server-side against
// the row (never trusted from the request body).
//
// FAIL POLICY: fail-open on storage, same as delete-account and opposite
// to admin-moderate-work. The author asked to remove their content;
// letting one stuck object block that forever is worse than a leftover
// file. Failures are recorded in audit_logs for manual sweeping.
//
// NOTE: the asset-enumeration logic is deliberately duplicated from
// delete-account rather than extracted into _shared/. Extracting it would
// mean redeploying delete-account, which is currently being end-to-end
// verified — moving a target under a test in progress. Fold them together
// once that verification lands.

import { createClient } from 'jsr:@supabase/supabase-js@2';
import { corsHeaders, jsonResponse } from '../_shared/cors.ts';

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
  if (!bearer) return jsonResponse({ error: 'missing_authorization' }, 401);

  const { data: userData, error: userErr } = await admin.auth.getUser(bearer);
  const user = userData?.user;
  if (userErr || !user) return jsonResponse({ error: 'unauthorized' }, 401);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: 'invalid_json' }, 400);
  }
  const workId = typeof body.work_id === 'string' ? body.work_id.trim() : '';
  if (!isUuid(workId)) return jsonResponse({ error: 'invalid_work_id' }, 400);

  // Ownership from the ROW, not the request. Also fetches the paths we
  // need before anything is deleted.
  const { data: work, error: workErr } = await admin
    .from('works')
    .select('id, user_id, model_storage_path, thumbnail_storage_path, preview_video_path')
    .eq('id', workId)
    .maybeSingle();
  if (workErr) {
    return jsonResponse({ error: 'work_lookup_failed', detail: workErr.message }, 500);
  }
  if (!work) return jsonResponse({ error: 'work_not_found' }, 404);
  if (work.user_id !== user.id) {
    // Deliberately 404, not 403: a 403 would confirm the work exists to
    // someone probing ids that aren't theirs.
    return jsonResponse({ error: 'work_not_found' }, 404);
  }

  // ── enumerate assets BEFORE deleting the row ────────────────────────
  // Deleting `works` cascades to work_versions, so their paths would be
  // unrecoverable afterwards.
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
  push('works', work.model_storage_path);
  push('thumbnails', work.thumbnail_storage_path);
  push('works', work.preview_video_path);

  const { data: versions } = await admin
    .from('work_versions')
    .select('model_storage_path, thumbnail_storage_path')
    .eq('work_id', workId);
  for (const v of versions ?? []) {
    push('works', v.model_storage_path);
    push('thumbnails', v.thumbnail_storage_path);
  }

  // If this work was previously taken down and later restored, or is
  // quarantined right now, its bytes may live under quarantine/{work_id}/.
  for (const p of await listAllUnder(admin, 'quarantine', workId)) {
    push('quarantine', p);
  }

  // ── delete files (batched per bucket) ───────────────────────────────
  const failures: Array<AssetRef & { detail: string }> = [];
  let deleted = 0;
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
        deleted += chunk.length;
      }
    }
  }

  // ── delete the row (cascades comments / likes / versions / tags) ────
  const { error: delErr } = await admin.from('works').delete().eq('id', workId);
  if (delErr) {
    return jsonResponse({
      error: 'work_delete_failed',
      detail: delErr.message,
      storage_objects_deleted: deleted,
    }, 500);
  }

  await admin.from('audit_logs').insert({
    actor_id: user.id,
    action: 'work.deleted_by_author',
    target_type: 'work',
    target_id: workId,
    ip_address: firstIp(req.headers.get('x-forwarded-for')),
    user_agent: (req.headers.get('user-agent') ?? '').slice(0, 500) || null,
    metadata: {
      storage_objects_found: assets.length,
      storage_objects_deleted: deleted,
      storage_failures: failures,
      note: failures.length > 0
        ? 'Work row deleted despite storage failures — sweep these manually.'
        : null,
    },
  });

  return jsonResponse({
    ok: true,
    work_id: workId,
    storage_objects_found: assets.length,
    storage_objects_deleted: deleted,
    storage_failures: failures.length,
    failures,
  });
});

async function listAllUnder(
  admin: ReturnType<typeof createClient>,
  bucket: string,
  prefix: string,
): Promise<string[]> {
  const out: string[] = [];
  const queue: string[] = [prefix];
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
        if (entry.id === null || entry.id === undefined) queue.push(full);
        else out.push(full);
      }
      if (data.length < 100) break;
      offset += data.length;
    }
  }
  return out;
}

function normalizeStoragePath(raw: unknown, bucket: string): string | null {
  if (typeof raw !== 'string') return null;
  const s = raw.trim();
  if (s.length === 0) return null;
  if (!s.startsWith('http')) return s.replace(/^\/+/, '');
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

/// x-forwarded-for may be a chain; the first entry is the original client.
/// Returns null when unparseable — attribution must never fail the delete.
function firstIp(raw: string | null): string | null {
  if (!raw) return null;
  const first = raw.split(',')[0]?.trim();
  return first && first.length > 0 ? first : null;
}
