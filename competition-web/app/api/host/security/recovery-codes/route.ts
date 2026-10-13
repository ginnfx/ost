import { randomBytes } from "node:crypto";
import { cookies } from "next/headers";
import {
  HostAccessDenied,
  SafeDatabaseError,
  withHost,
} from "@/lib/server/database";
import { privateJson, sameOriginRequest, unavailable } from "@/lib/server/http";
import { isRecentlyVerified, sha256 } from "@/lib/server/webauthn";

export async function POST(request: Request) {
  if (!sameOriginRequest(request)) return unavailable();
  try {
    const codes = Array.from({ length: 10 }, () =>
      randomBytes(16).toString("base64url"),
    );
    await withHost(async (db, userId) => {
      const raw = (await cookies()).get("ost_host_recent")?.value;
      if (!isRecentlyVerified(raw, userId))
        throw new SafeDatabaseError("RECENT_AUTH_REQUIRED");
      const hashes = codes.map((code) => sha256(code));
      await db.query(
        "select private.replace_host_recovery_codes($1::bytea[])",
        [hashes],
      );
    });
    return privateJson({ codes });
  } catch (error) {
    if (
      error instanceof SafeDatabaseError &&
      error.message === "RECENT_AUTH_REQUIRED"
    )
      return privateJson(
        {
          error: "Sign in with a passkey again before rotating recovery codes.",
        },
        401,
      );
    return error instanceof HostAccessDenied ? unavailable() : unavailable();
  }
}
