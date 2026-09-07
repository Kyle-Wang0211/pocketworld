export const STANDARD_REASONS = new Set([
  "harassment_threat",
  "spam_fraud",
  "minor_safety",
  "sexual_content",
  "violence_illegal",
  "misinformation",
  "other",
]);

export const RIGHTS_REASONS = new Set(["impersonation", "privacy_ip"]);

export type ReportKind = "standard" | "rights";

export type ValidatedReportInput = {
  kind: ReportKind;
  reason: string;
  targetUserId: string;
  sourceWorkId: string | null;
  detail: string | null;
};

export type ReportInputResult =
  | { ok: true; value: ValidatedReportInput }
  | { ok: false; error: string };

export function validateReportInput(
  body: Record<string, unknown>,
  reporterId: string,
): ReportInputResult {
  const kind = stringValue(body.kind);
  const reason = stringValue(body.reason);
  const targetUserId = stringValue(body.target_user_id);
  const sourceWorkId = stringValue(body.source_work_id) || null;
  const rawDetail = typeof body.detail === "string" ? body.detail.trim() : "";
  const detail = rawDetail || null;

  if (!isUuid(targetUserId) || targetUserId === reporterId) {
    return { ok: false, error: "invalid_target_user" };
  }
  if (kind !== "standard" && kind !== "rights") {
    return { ok: false, error: "invalid_kind" };
  }
  const allowed = kind === "rights" ? RIGHTS_REASONS : STANDARD_REASONS;
  if (!allowed.has(reason)) {
    const known = RIGHTS_REASONS.has(reason) || STANDARD_REASONS.has(reason);
    return {
      ok: false,
      error: known ? "kind_reason_mismatch" : "invalid_reason",
    };
  }
  const maxDetail = kind === "rights" ? 500 : 50;
  if (Array.from(rawDetail).length > maxDetail) {
    return { ok: false, error: "detail_too_long" };
  }
  if (sourceWorkId !== null && !isUuid(sourceWorkId)) {
    return { ok: false, error: "invalid_source_work" };
  }
  return {
    ok: true,
    value: { kind, reason, targetUserId, sourceWorkId, detail },
  };
}

function stringValue(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}
