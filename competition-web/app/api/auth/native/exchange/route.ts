import { z } from "zod";
import { supabaseAdmin } from "@/lib/server/admin-auth";
import { withAppRole } from "@/lib/server/database";
import { privateJson, sameOriginRequest, unavailable } from "@/lib/server/http";
import { clientAddress, sha256 } from "@/lib/server/webauthn";
import { createClient } from "@supabase/supabase-js";

const schema = z.object({ code: z.string().min(40).max(64) }).strict();

export async function POST(request: Request) {
  const origin = request.headers.get("origin");
  if (origin && !sameOriginRequest(request)) return unavailable();
  const body = schema.safeParse(await request.json().catch(() => null));
  if (!body.success) return unavailable();
  try {
    const userId = await withAppRole(async (db) => {
      const limit = await db.query<{ allowed: boolean }>(
        "select private.rate_limit_hit($1,$2,$3,$4) as allowed",
        ["login", sha256(clientAddress(request)), 30, 900],
      );
      if (!limit.rows[0]?.allowed) throw new Error("RATE_LIMITED");
      const result = await db.query<{
        consume_native_authorization_code: string;
      }>("select private.consume_native_authorization_code($1)", [
        sha256(body.data.code),
      ]);
      return result.rows[0]?.consume_native_authorization_code;
    });
    const admin = supabaseAdmin();
    const { data: identity, error: identityError } =
      await admin.auth.admin.getUserById(userId);
    if (identityError || !identity.user?.email) return unavailable();
    const { data: link, error: linkError } =
      await admin.auth.admin.generateLink({
        type: "magiclink",
        email: identity.user.email,
      });
    const tokenHash = link.properties?.hashed_token;
    if (linkError || !tokenHash) return unavailable();
    const sessionClient = createClient(
      process.env.NEXT_PUBLIC_SUPABASE_URL!,
      process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
      { auth: { persistSession: false, autoRefreshToken: false } },
    );
    const { data: verified, error: verifyError } =
      await sessionClient.auth.verifyOtp({
        token_hash: tokenHash,
        type: "magiclink",
      });
    if (verifyError || !verified.session) return unavailable();
    return privateJson({
      accessToken: verified.session.access_token,
      refreshToken: verified.session.refresh_token,
      expiresAt: verified.session.expires_at,
      userId,
    });
  } catch {
    return unavailable();
  }
}
