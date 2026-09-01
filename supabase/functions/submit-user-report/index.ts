// Authenticated server-owned account-report submission. User reports cannot be
// inserted directly through PostgREST: this endpoint validates the linked work
// and, for minor/sexual-safety reports, preserves its current assets in a
// private moderation-only bucket before the author can remove the source work.

import { createClient } from "jsr:@supabase/supabase-js@2.112.3";
import {
  consumeRateLimit,
  corsHeaders,
  jsonResponse,
} from "../_shared/cors.ts";

const REASONS = new Set([
  "impersonation",
  "harassment_threat",
  "spam_fraud",
  "minor_safety",
  "sexual_content",
  "violence_illegal",
  "misinformation",
  "privacy_ip",
  "other",
]);
const SENSITIVE_REASONS = new Set(["minor_safety", "sexual_content"]);
const SOURCE_BUCKET = "report-source-evidence";

type SourceAsset = { bucket: string; path: string };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return jsonResponse({ error: "method_not_allowed" }, 405);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) {
    return jsonResponse({ error: "server_misconfigured" }, 500);
  }
  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false },
  });

  const bearer = (req.headers.get("Authorization") ?? "")
    .replace(/^Bearer\s+/i, "")
    .trim();
  if (!bearer) return jsonResponse({ error: "missing_authorization" }, 401);
  const { data: userData, error: userError } = await admin.auth.getUser(bearer);
  const user = userData?.user;
  if (userError || !user) return jsonResponse({ error: "unauthorized" }, 401);
  if (
    !await consumeRateLimit(admin, `submit-user-report:${user.id}`, 20, 3600)
  ) {
    return jsonResponse({ error: "rate_limited" }, 429);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "invalid_json" }, 400);
  }
  const targetUserId = stringValue(body.target_user_id);
  const reason = stringValue(body.reason);
  const sourceWorkId = stringValue(body.source_work_id) || null;
  const rawDetail = typeof body.detail === "string" ? body.detail.trim() : "";
  const detail = rawDetail || null;
  if (!isUuid(targetUserId) || targetUserId === user.id) {
    return jsonResponse({ error: "invalid_target_user" }, 400);
  }
  if (!REASONS.has(reason)) {
    return jsonResponse({ error: "invalid_reason" }, 400);
  }
  if (Array.from(rawDetail).length > 500) {
    return jsonResponse({ error: "detail_too_long" }, 400);
  }
  if (sourceWorkId !== null && !isUuid(sourceWorkId)) {
    return jsonResponse({ error: "invalid_source_work" }, 400);
  }

  let sourceWork: Record<string, unknown> | null = null;
  if (sourceWorkId !== null) {
    const { data, error } = await admin
      .from("works")
      .select(
        "id, user_id, model_storage_path, thumbnail_storage_path, preview_video_path",
      )
      .eq("id", sourceWorkId)
      .eq("user_id", targetUserId)
      .maybeSingle();
    if (error) return jsonResponse({ error: "source_work_lookup_failed" }, 500);
    if (!data) return jsonResponse({ error: "source_work_mismatch" }, 400);
    sourceWork = data;
  }

  const { data: report, error: reportError } = await admin
    .from("reports")
    .insert({
      reporter_id: user.id,
      target_type: "user",
      target_id: targetUserId,
      reason,
      detail,
      source_work_id: sourceWorkId,
    })
    .select("id, preservation_state")
    .single();
  if (reportError || !report) {
    return jsonResponse({ error: "report_create_failed" }, 500);
  }

  let preserved = 0;
  let failed = 0;
  if (SENSITIVE_REASONS.has(reason) && sourceWork !== null) {
    const assets = sourceAssets(sourceWork);
    for (let ordinal = 0; ordinal < assets.length; ordinal++) {
      const asset = assets[ordinal];
      const { data: info, error: infoError } = await admin.storage
        .from(asset.bucket)
        .info(asset.path);
      if (infoError || !info) {
        failed++;
        continue;
      }
      const storagePath = `${user.id}/${report.id}/${crypto.randomUUID()}${
        extensionOf(asset.path)
      }`;
      // Storage performs the cross-bucket copy server-side. Large 3D models
      // never enter Edge Function memory or consume its request time budget.
      const { error: copyError } = await admin.storage
        .from(asset.bucket)
        .copy(asset.path, storagePath, {
          destinationBucket: SOURCE_BUCKET,
        });
      if (copyError) {
        failed++;
        continue;
      }
      const { error: metadataError } = await admin
        .from("report_source_assets")
        .insert({
          report_id: report.id,
          reporter_id: user.id,
          ordinal,
          source_bucket: asset.bucket,
          source_path: asset.path,
          storage_path: storagePath,
          byte_size: info.size ?? 1,
          content_type: info.contentType || null,
        });
      if (metadataError) {
        failed++;
        const { error: cleanupError } = await admin.storage
          .from(SOURCE_BUCKET)
          .remove([storagePath]);
        if (cleanupError) {
          await admin.from("audit_logs").insert({
            actor_id: user.id,
            action: "report.source_cleanup_failed",
            target_type: "system",
            target_id: null,
            metadata: {
              report_id: report.id,
              storage_bucket: SOURCE_BUCKET,
              storage_path: storagePath,
            },
          });
        }
        continue;
      }
      preserved++;
    }

    const preservationState = failed === 0
      ? "complete"
      : preserved > 0
      ? "partial"
      : "failed";
    await admin.from("reports").update({
      preservation_state: preservationState,
      preservation_attempts: 1,
      preservation_lease_until: null,
    })
      .eq("id", report.id);
  }

  return jsonResponse({
    ok: true,
    report_id: report.id,
    source_assets_preserved: preserved,
    source_assets_failed: failed,
  }, 201);
});

function sourceAssets(work: Record<string, unknown>): SourceAsset[] {
  const candidates: Array<[string, unknown]> = [
    ["works", work.model_storage_path],
    ["thumbnails", work.thumbnail_storage_path],
    ["works", work.preview_video_path],
  ];
  const out: SourceAsset[] = [];
  const seen = new Set<string>();
  for (const [bucket, raw] of candidates) {
    const path = normalizeStoragePath(raw, bucket);
    if (!path || seen.has(`${bucket}:${path}`)) continue;
    seen.add(`${bucket}:${path}`);
    out.push({ bucket, path });
  }
  return out.slice(0, 3);
}

function normalizeStoragePath(raw: unknown, bucket: string): string | null {
  if (typeof raw !== "string") return null;
  const value = raw.trim();
  if (!value) return null;
  if (!value.startsWith("http")) return value.replace(/^\/+/, "");
  const match = value.match(
    new RegExp(
      `/storage/v1/object/(?:public|sign|authenticated)/${bucket}/(.+?)(?:\\?|$)`,
    ),
  );
  if (!match) return null;
  try {
    return decodeURIComponent(match[1]);
  } catch {
    return match[1];
  }
}

function extensionOf(path: string): string {
  const match = path.match(/(\.[a-z0-9]{1,10})$/i);
  return match?.[1]?.toLowerCase() ?? ".bin";
}

function stringValue(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}
