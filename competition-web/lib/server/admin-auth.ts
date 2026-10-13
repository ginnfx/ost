import "server-only";
import { createClient } from "@supabase/supabase-js";

let admin: ReturnType<typeof createClient> | undefined;
export function supabaseAdmin() {
  if (!admin) {
    const url = process.env.SUPABASE_URL;
    const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
    if (!url || !key) throw new Error("Server auth configuration is missing.");
    admin = createClient(url, key, {
      auth: {
        autoRefreshToken: false,
        persistSession: false,
        detectSessionInUrl: false,
      },
    });
  }
  return admin;
}
