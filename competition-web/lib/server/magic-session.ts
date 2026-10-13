import "server-only";
import { supabaseAdmin } from "./admin-auth";
import { supabaseForRequest } from "./auth";

export async function establishSupabaseSession(userId: string): Promise<void> {
  const admin = supabaseAdmin();
  const { data: user, error: userError } =
    await admin.auth.admin.getUserById(userId);
  if (userError || !user.user?.email) throw new Error("AUTH_SESSION_FAILED");
  const { data: link, error: linkError } = await admin.auth.admin.generateLink({
    type: "magiclink",
    email: user.user.email,
  });
  const tokenHash = link?.properties?.hashed_token;
  if (linkError || !tokenHash) throw new Error("AUTH_SESSION_FAILED");
  const supabase = await supabaseForRequest();
  const { error } = await supabase.auth.verifyOtp({
    token_hash: tokenHash,
    type: "magiclink",
  });
  if (error) throw new Error("AUTH_SESSION_FAILED");
}
