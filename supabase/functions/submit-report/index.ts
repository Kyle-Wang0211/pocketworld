// Unified authenticated report submission for both the 50-character standard
// path and the 500-character rights/privacy complaint path.

import { createClient } from "jsr:@supabase/supabase-js@2.112.3";
import {
  consumeRateLimit,
  corsHeaders,
  jsonResponse,
} from "../_shared/cors.ts";
import { moderationProviderFromName } from "../_shared/moderation_provider.ts";
import { validateReportInput } from "./validate.ts";

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

  const bearer = (req.headers.get("Authorization") ?? "").replace(
    /^Bearer\s+/i,
    "",
  ).trim();
  if (!bearer) return jsonResponse({ error: "missing_authorization" }, 401);
  const { data: userData, error: userError } = await admin.auth.getUser(bearer);
  const user = userData?.user;
  if (userError || !user) return jsonResponse({ error: "unauthorized" }, 401);
  if (!await consumeRateLimit(admin, `submit-report:${user.id}`, 20, 3600)) {
    return jsonResponse({ error: "rate_limited" }, 429);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "invalid_json" }, 400);
  }
  const verdict = validateReportInput(body, user.id);
  if (!verdict.ok) return jsonResponse({ error: verdict.error }, 400);
  const { kind, reason, targetUserId, sourceWorkId, detail } = verdict.value;
  let moderationProvider;
  try {
    moderationProvider = moderationProviderFromName(
      Deno.env.get("MODERATION_PROVIDER"),
    );
  } catch {
    return jsonResponse({ error: "moderation_provider_misconfigured" }, 500);
  }

  const { data: target, error: targetError } = await admin
    .from("profiles").select("id").eq("id", targetUserId).maybeSingle();
  if (targetError) {
    return jsonResponse({ error: "target_user_lookup_failed" }, 500);
  }
  if (!target) return jsonResponse({ error: "target_user_not_found" }, 404);

  let sourceWork: Record<string, unknown> | null = null;
  if (sourceWorkId !== null) {
    const { data, error } = await admin
      .from("works")
      .select(
        "id, user_id, model_storage_path, thumbnail_storage_path, preview_video_path",
      )
      .eq("id", sourceWorkId)
      .eq("user_id", targetUserId)
      .is("deleted_at", null)
      .maybeSingle();
    if (error) return jsonResponse({ error: "source_work_lookup_failed" }, 500);
    if (!data) return jsonResponse({ error: "source_work_mismatch" }, 400);
    sourceWork = data;
  }

  // Suppress exact duplicates for 24 hours without losing the id the client
  // needs for its report history. Sensitive source preservation is not repeated.
  let duplicateQuery = admin.from("reports")
    .select("id, preservation_state")
    .eq("reporter_id", user.id)
    .eq("target_type", "user")
    .eq("target_id", targetUserId)
    .eq("reason", reason)
    .gte("created_at", new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString())
    .order("created_at", { ascending: false })
    .limit(1);
  duplicateQuery = sourceWorkId === null
    ? duplicateQuery.is("source_work_id", null)
    : duplicateQuery.eq("source_work_id", sourceWorkId);
  const { data: duplicates, error: duplicateError } = await duplicateQuery;
  if (duplicateError) {
    return jsonResponse({ error: "duplicate_lookup_failed" }, 500);
  }
  if ((duplicates ?? []).length > 0) {
    return jsonResponse({
      ok: true,
      duplicate: true,
      report_id: duplicates![0].id,
      preservation_state: duplicates![0].preservation_state,
    }, 200);
  }

  const { data: report, error: reportError } = await admin.from("reports")
    .insert({
      reporter_id: user.id,
      target_type: "user",
      target_id: targetUserId,
      kind,
      reason,
      detail,
      source_work_id: sourceWorkId,
    }).select("id, preservation_state").single();
  if (reportError || !report) {
    return jsonResponse({ error: "report_create_failed" }, 500);
  }

  let preserved = 0;
  let failed = 0;
  if (SENSITIVE_REASONS.has(reason) && sourceWork !== null) {
    const assets = sourceAssets(sourceWork);
    for (let ordinal = 0; ordinal < assets.length; ordinal++) {
      const asset = assets[ordinal];
      const { data: info, error: infoError } = await admin.storage.from(
        asset.bucket,
      ).info(asset.path);
      if (infoError || !info) {
        failed++;
        continue;
      }
      const storagePath = `${user.id}/${report.id}/${crypto.randomUUID()}${
        extensionOf(asset.path)
      }`;
      const { error: copyError } = await admin.storage.from(asset.bucket).copy(
        asset.path,
        storagePath,
        {
          destinationBucket: SOURCE_BUCKET,
        },
      );
      if (copyError) {
        failed++;
        continue;
      }
      const { error: metadataError } = await admin.from("report_source_assets")
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
        await admin.storage.from(SOURCE_BUCKET).remove([storagePath]);
      } else {
        preserved++;
      }
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
    }).eq("id", report.id);
  }

  const moderationReceipt = await moderationProvider.enqueue({
    reportId: report.id,
    reason,
  });

  return jsonResponse({
    ok: true,
    report_id: report.id,
    moderation_route: moderationReceipt.route,
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
  return path.match(/(\.[a-z0-9]{1,10})$/i)?.[1]?.toLowerCase() ?? ".bin";
}
