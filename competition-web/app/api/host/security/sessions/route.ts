import { cookies } from "next/headers";
import {
  HostAccessDenied,
  SafeDatabaseError,
  withHost,
} from "@/lib/server/database";
import { supabaseForRequest } from "@/lib/server/auth";
import { privateJson, sameOriginRequest, unavailable } from "@/lib/server/http";
import { isRecentlyVerified } from "@/lib/server/webauthn";

export async function POST(request: Request) {
  if (!sameOriginRequest(request)) return unavailable();
  try {
    await withHost(async (db, hostId) => {
      if (
        !isRecentlyVerified(
          (await cookies()).get("ost_host_recent")?.value,
          hostId,
        )
      )
        throw new SafeDatabaseError("RECENT_AUTH_REQUIRED");
      await db.query("select private.revoke_host_sessions()");
    });
    await (await supabaseForRequest()).auth.signOut({ scope: "local" });
    return privateJson({ success: true });
  } catch (error) {
    if (error instanceof SafeDatabaseError)
      return privateJson(
        { error: "Sign in with a passkey again before ending all sessions." },
        401,
      );
    return error instanceof HostAccessDenied ? unavailable() : unavailable();
  }
}
