import { assertEquals } from "jsr:@std/assert@1.0.19";
import { canModerate } from "./moderator_auth.ts";

Deno.test("reviewers can triage but cannot confirm enforcement", () => {
  assertEquals(canModerate("reviewer", "list"), true);
  assertEquals(canModerate("reviewer", "claim"), true);
  assertEquals(canModerate("reviewer", "transition", "in_review"), true);
  assertEquals(canModerate("reviewer", "transition", "needs_info"), true);
  assertEquals(canModerate("reviewer", "transition", "dismissed"), true);
  assertEquals(canModerate("reviewer", "transition", "actioned"), false);
});

Deno.test("leads can confirm enforcement", () => {
  assertEquals(canModerate("lead", "transition", "actioned"), true);
});

Deno.test("unknown roles and actions fail closed", () => {
  assertEquals(canModerate("owner", "list"), false);
  assertEquals(canModerate("reviewer", "delete"), false);
});
