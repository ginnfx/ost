import { randomBytes } from "node:crypto";
import { withCurrentUser } from "@/lib/server/database";
import { privateJson, sameOriginRequest, unavailable } from "@/lib/server/http";
import { clientAddress, sha256 } from "@/lib/server/webauthn";

export async function POST(request: Request) {
  if (!sameOriginRequest(request)) return unavailable();
  try {
    const code = randomBytes(32).toString("base64url");
    await withCurrentUser(async (db, userId) => {
      const { rows } = await db.query<{ allowed: boolean }>(
        "select private.rate_limit_hit($1,$2,$3,$4) as allowed",
        ["login", sha256(`${userId}:${clientAddress(request)}`), 30, 900],
      );
      if (!rows[0]?.allowed) throw new Error("RATE_LIMITED");
      await db.query("select private.create_native_authorization_code($1,$2)", [
        sha256(code),
        new Date(Date.now() + 60_000).toISOString(),
      ]);
    });
    return privateJson({
      callbackUrl: `osttracker://competition?code=${code}`,
    });
  } catch {
    return unavailable();
  }
}
