import { isAdminRequest } from "./admin_auth.ts";

export type ModeratorRole = "reviewer" | "lead";
export type ModeratorIdentity = {
  userId: string | null;
  role: ModeratorRole;
  breakglass: boolean;
};

export type ModeratorAuthResult =
  | { ok: true; moderator: ModeratorIdentity }
  | { ok: false; status: 401 | 403; error: string };

export function canModerate(
  role: string,
  action: string,
  targetStatus?: string,
): boolean {
  if (role !== "reviewer" && role !== "lead") return false;
  if (action === "whoami" || action === "list" || action === "claim") {
    return true;
  }
  if (action !== "transition") return false;
  if (["in_review", "needs_info", "dismissed"].includes(targetStatus ?? "")) {
    return true;
  }
  return targetStatus === "actioned" && role === "lead";
}

export async function authenticateModerator(
  req: Request,
  // deno-lint-ignore no-explicit-any
  admin: any,
): Promise<ModeratorAuthResult> {
  // Retain a server/service-secret break-glass path for recovery and internal
  // function-to-function calls. The browser console never accepts this key.
  if (isAdminRequest(req)) {
    return {
      ok: true,
      moderator: { userId: null, role: "lead", breakglass: true },
    };
  }
  const bearer = (req.headers.get("Authorization") ?? "")
    .replace(/^Bearer\s+/i, "")
    .trim();
  if (!bearer) {
    return { ok: false, status: 401, error: "missing_authorization" };
  }
  const { data: userData, error: userError } = await admin.auth.getUser(bearer);
  const user = userData?.user;
  if (userError || !user) {
    return { ok: false, status: 401, error: "unauthorized" };
  }
  const { data: account, error } = await admin
    .from("moderator_accounts")
    .select("role, active")
    .eq("user_id", user.id)
    .maybeSingle();
  if (error || !account || account.active !== true) {
    return { ok: false, status: 403, error: "moderator_forbidden" };
  }
  if (account.role !== "reviewer" && account.role !== "lead") {
    return { ok: false, status: 403, error: "moderator_forbidden" };
  }
  return {
    ok: true,
    moderator: { userId: user.id, role: account.role, breakglass: false },
  };
}
