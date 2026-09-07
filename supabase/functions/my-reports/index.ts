// Authenticated safe projection of the current user's own report history.
// The RPC deliberately excludes moderator notes and reporter identifiers.

import { createClient } from "jsr:@supabase/supabase-js@2.112.3";
import {
  consumeRateLimit,
  corsHeaders,
  jsonResponse,
} from "../_shared/cors.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return jsonResponse({ error: "method_not_allowed" }, 405);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceKey) {
    return jsonResponse({ error: "server_misconfigured" }, 500);
  }
  const bearer = (req.headers.get("Authorization") ?? "").replace(
    /^Bearer\s+/i,
    "",
  ).trim();
  if (!bearer) return jsonResponse({ error: "missing_authorization" }, 401);
  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false },
  });
  const { data: userData, error: userError } = await admin.auth.getUser(bearer);
  const user = userData?.user;
  if (userError || !user) return jsonResponse({ error: "unauthorized" }, 401);
  if (!await consumeRateLimit(admin, `my-reports:${user.id}`, 60, 3600)) {
    return jsonResponse({ error: "rate_limited" }, 429);
  }

  const userClient = createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false },
    global: { headers: { Authorization: `Bearer ${bearer}` } },
  });
  const { data, error } = await userClient.rpc("get_my_reports", {
    p_limit: 100,
  });
  if (error) return jsonResponse({ error: "report_history_failed" }, 500);
  return jsonResponse({ ok: true, reports: data ?? [] }, 200);
});
