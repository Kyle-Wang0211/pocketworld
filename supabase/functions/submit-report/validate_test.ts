import { assertEquals } from "jsr:@std/assert@1.0.19";
import { validateReportInput } from "./validate.ts";

const reporter = "11111111-1111-4111-8111-111111111111";
const target = "22222222-2222-4222-8222-222222222222";

Deno.test("accepts standard reports through 50 characters", () => {
  const result = validateReportInput({
    kind: "standard",
    reason: "spam_fraud",
    target_user_id: target,
    detail: "位".repeat(50),
  }, reporter);
  assertEquals(result.ok, true);
});

Deno.test("rejects standard reports over 50 characters", () => {
  assertEquals(
    validateReportInput({
      kind: "standard",
      reason: "other",
      target_user_id: target,
      detail: "x".repeat(51),
    }, reporter),
    { ok: false, error: "detail_too_long" },
  );
});

Deno.test("accepts rights complaints through 500 characters", () => {
  const result = validateReportInput({
    kind: "rights",
    reason: "privacy_ip",
    target_user_id: target,
    detail: "权".repeat(500),
  }, reporter);
  assertEquals(result.ok, true);
});

Deno.test("rejects mismatched reason and tier", () => {
  assertEquals(
    validateReportInput({
      kind: "standard",
      reason: "impersonation",
      target_user_id: target,
    }, reporter),
    { ok: false, error: "kind_reason_mismatch" },
  );
});

Deno.test("rejects self reports and malformed source ids", () => {
  assertEquals(
    validateReportInput({
      kind: "standard",
      reason: "spam_fraud",
      target_user_id: reporter,
    }, reporter),
    { ok: false, error: "invalid_target_user" },
  );
  assertEquals(
    validateReportInput({
      kind: "standard",
      reason: "spam_fraud",
      target_user_id: target,
      source_work_id: "not-a-uuid",
    }, reporter),
    { ok: false, error: "invalid_source_work" },
  );
});
