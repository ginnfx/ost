import { z } from "zod";
import { createClient } from "@supabase/supabase-js";
import { clientAddress, sha256 } from "@/lib/server/webauthn";
import { withAppRole } from "@/lib/server/database";
import { privateJson, sameOriginRequest, unavailable } from "@/lib/server/http";

const schema = z.object({ refreshToken: z.string().min(8).max(4096) }).strict();

export async function POST(request: Request) {
  const origin = request.headers.get("origin");
  if (origin && !sameOriginRequest(request)) return unavailable();
  const body = schema.safeParse(await request.json().catch(() => null));
  if (!body.success) return unavailable();
  try {
    await withAppRole(async (db) => {
      const { rows } = await db.query<{ allowed: boolean }>(
        "select private.rate_limit_hit($1,$2,$3,$4) as allowed",
        ["login", sha256(clientAddress(request)), 30, 900],
      );
      if (!rows[0]?.allowed) throw new Error("RATE_LIMITED");
    });
    const client = createClient(
      process.env.NEXT_PUBLIC_SUPABASE_URL!,
      process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
      {
        auth: { persistSession: false, autoRefreshToken: false },
      },
    );
    const { data, error } = await client.auth.refreshSession({
      refresh_token: body.data.refreshToken,
    });
    if (error || !data.session) return unavailable();
    return privateJson({
      accessToken: data.session.access_token,
      refreshToken: data.session.refresh_token,
      expiresAt: data.session.expires_at,
      userId: data.session.user.id,
    });
  } catch {
    return unavailable();
  }
}
