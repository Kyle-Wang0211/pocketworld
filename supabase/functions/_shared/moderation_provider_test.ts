import { assertEquals, assertRejects } from "jsr:@std/assert@1.0.19";
import { moderationProviderFromName } from "./moderation_provider.ts";

Deno.test("manual provider is the safe default and performs no external call", async () => {
  const provider = moderationProviderFromName(undefined);
  assertEquals(provider.name, "manual");
  assertEquals(await provider.enqueue({ reportId: 7, reason: "spam_fraud" }), {
    route: "manual",
    externalReference: null,
  });
});

Deno.test("unimplemented vendors fail closed instead of pretending success", async () => {
  await assertRejects(
    async () => moderationProviderFromName("tencent"),
    Error,
    "unsupported moderation provider",
  );
});
