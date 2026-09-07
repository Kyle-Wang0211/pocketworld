export type ModerationQueueInput = {
  reportId: number | string;
  reason: string;
};

export type ModerationQueueReceipt = {
  route: "manual" | "external";
  externalReference: string | null;
};

export interface ModerationProvider {
  readonly name: string;
  enqueue(input: ModerationQueueInput): Promise<ModerationQueueReceipt>;
}

class ManualModerationProvider implements ModerationProvider {
  readonly name = "manual";

  enqueue(_input: ModerationQueueInput): Promise<ModerationQueueReceipt> {
    return Promise.resolve({ route: "manual", externalReference: null });
  }
}

/// Deliberately fail closed for vendor names until their credentials, payload
/// minimisation, retention terms, callback authentication, and error handling
/// have a reviewed adapter. Supabase and Alibaba/Tencent/NetEase are not API
/// compatible services merely because they can all store PostgreSQL-like data.
export function moderationProviderFromName(
  rawName: string | undefined,
): ModerationProvider {
  const name = rawName?.trim().toLowerCase() || "manual";
  if (name === "manual") return new ManualModerationProvider();
  throw new Error(`unsupported moderation provider: ${name}`);
}
