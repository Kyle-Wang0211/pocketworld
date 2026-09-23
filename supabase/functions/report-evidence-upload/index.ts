// Authenticated, server-owned upload path for sanitized report evidence.
// The report row is created first by the client; a failed image upload never
// loses the durable report. Storage paths are random and the bucket is private.

import { createClient } from "jsr:@supabase/supabase-js@2.112.3";
import {
  consumeRateLimit,
  corsHeaders,
  jsonResponse,
} from "../_shared/cors.ts";
import { MAX_EVIDENCE_BYTES, validateEvidence } from "./validate.ts";

const MAX_BASE64_LENGTH = Math.ceil(MAX_EVIDENCE_BYTES / 3) * 4 + 4;

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
  const allowed = await consumeRateLimit(
    admin,
    `report-evidence:${user.id}`,
    30,
    3600,
  );
  if (!allowed) return jsonResponse({ error: "rate_limited" }, 429);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "invalid_json" }, 400);
  }

  const reportId = parseReportId(body.report_id);
  if (reportId === null) {
    return jsonResponse({ error: "invalid_report_id" }, 400);
  }

  // Check ownership and quota before decoding several megabytes of base64.
  // A caller cannot spend image-validation work against someone else's row.
  const { data: report, error: reportError } = await admin
    .from("reports")
    .select("id, reason, kind")
    .eq("id", reportId)
    .eq("reporter_id", user.id)
    .eq("target_type", "user")
    .eq("status", "pending")
    .maybeSingle();
  if (reportError) {
    return jsonResponse({ error: "report_lookup_failed" }, 500);
  }
  if (!report) return jsonResponse({ error: "report_not_found" }, 404);
  if (["minor_safety", "sexual_content"].includes(report.reason)) {
    return jsonResponse({ error: "evidence_not_allowed" }, 403);
  }
  const evidenceKind = typeof body.evidence_kind === "string"
    ? body.evidence_kind.trim()
    : "";
  const allowedKinds = report.kind === "rights"
    ? ["identity", "ownership", "authorization", "other"]
    : ["context"];
  if (!allowedKinds.includes(evidenceKind)) {
    return jsonResponse({ error: "invalid_evidence_kind" }, 400);
  }

  const { data: existing, error: evidenceError } = await admin
    .from("report_evidence")
    .select("ordinal")
    .eq("report_id", reportId)
    .order("ordinal");
  if (evidenceError) {
    return jsonResponse({ error: "evidence_lookup_failed" }, 500);
  }
  const used = new Set((existing ?? []).map((row) => Number(row.ordinal)));
  const ordinal = [0, 1, 2].find((candidate) => !used.has(candidate));
  if (ordinal === undefined) {
    return jsonResponse({ error: "evidence_limit_reached" }, 409);
  }

  const encoded = body.bytes;
  const contentType = body.content_type;
  const extension = body.extension;
  if (typeof encoded !== "string" || encoded.length === 0) {
    return jsonResponse({ error: "missing_bytes" }, 400);
  }
  if (encoded.length > MAX_BASE64_LENGTH) {
    return jsonResponse({ error: "evidence_too_large" }, 413);
  }

  let bytes: Uint8Array;
  try {
    bytes = Uint8Array.from(atob(encoded), (char) => char.charCodeAt(0));
  } catch {
    return jsonResponse({ error: "invalid_base64" }, 400);
  }
  const verdict = await validateEvidence(bytes, contentType, extension);
  if (!verdict.ok) {
    return jsonResponse(
      { error: "invalid_evidence", reason: verdict.reason },
      400,
    );
  }

  const ext = extension as "jpg" | "png";
  const path = `${user.id}/${reportId}/${crypto.randomUUID()}.${ext}`;
  const { error: uploadError } = await admin.storage
    .from("report-evidence")
    .upload(path, bytes, {
      contentType: contentType as string,
      cacheControl: "3600",
      upsert: false,
    });
  if (uploadError) {
    return jsonResponse({ error: "storage_upload_failed" }, 500);
  }

  const hashInput = new Uint8Array(bytes);
  const hash = await crypto.subtle.digest("SHA-256", hashInput.buffer);
  const sha256 = Array.from(new Uint8Array(hash))
    .map((value) => value.toString(16).padStart(2, "0"))
    .join("");
  const { data: inserted, error: insertError } = await admin
    .from("report_evidence")
    .insert({
      report_id: reportId,
      reporter_id: user.id,
      ordinal,
      evidence_kind: evidenceKind,
      storage_path: path,
      content_type: contentType,
      byte_size: bytes.length,
      width: verdict.width,
      height: verdict.height,
      sha256,
    })
    .select("id, ordinal")
    .single();
  if (insertError) {
    const { error: cleanupError } = await admin.storage
      .from("report-evidence")
      .remove([path]);
    if (cleanupError) {
      // The object has no metadata row, so preserve an internal sweep target.
      await admin.from("audit_logs").insert({
        actor_id: user.id,
        action: "report.evidence_cleanup_failed",
        target_type: "system",
        target_id: null,
        metadata: {
          report_id: reportId,
          storage_bucket: "report-evidence",
          storage_path: path,
          cleanup_error: cleanupError.message,
          metadata_error: insertError.message,
        },
      });
      return jsonResponse({ error: "evidence_cleanup_failed" }, 500);
    }
    if (insertError.code === "23505") {
      return jsonResponse({ error: "evidence_slot_conflict" }, 409);
    }
    return jsonResponse({ error: "evidence_metadata_failed" }, 500);
  }

  return jsonResponse({ ok: true, evidence_id: inserted.id, ordinal }, 201);
});

function parseReportId(value: unknown): string | null {
  const normalized = typeof value === "number"
    ? (Number.isSafeInteger(value) && value > 0 ? value.toString() : "")
    : typeof value === "string"
    ? value.trim()
    : "";
  return /^[1-9][0-9]*$/.test(normalized) ? normalized : null;
}
