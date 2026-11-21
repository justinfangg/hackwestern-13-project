// Authentication: the user id comes ONLY from the verified JWT (docs/api.md §1).
import { createClient } from "npm:@supabase/supabase-js@2";
import { ApiError } from "./http.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const authClient = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });

/** Service-role client for Storage uploads (server-only). */
export const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

export async function requireUser(req: Request): Promise<string> {
  const token = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "");
  if (!token) throw new ApiError(401, "unauthorized", "Missing access token.");
  const { data, error } = await authClient.auth.getUser(token);
  if (error || !data.user) throw new ApiError(401, "unauthorized", "Missing or expired access token.");
  return data.user.id;
}
