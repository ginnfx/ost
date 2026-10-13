import { cookies } from "next/headers";
import { z } from "zod";
import { HostAccessDenied, withHost } from "@/lib/server/database";
import { privateJson, sameOriginRequest, unavailable } from "@/lib/server/http";
import { isRecentlyVerified } from "@/lib/server/webauthn";
import { supabaseForRequest } from "@/lib/server/auth";

const removeSchema = z
  .object({ credentialId: z.string().min(1).max(1024) })
  .strict();

export async function GET() {
  try {
    const credentials = await withHost(async (db) => {
      const { rows } = await db.query(
        "select * from private.list_host_credentials()",
      );
      return rows;
    });
    return privateJson({ credentials });
  } catch (error) {
    return error instanceof HostAccessDenied ? unavailable() : unavailable();
  }
}

export async function DELETE(request: Request) {
  if (!sameOriginRequest(request)) return unavailable();
  const parsed = removeSchema.safeParse(await request.json().catch(() => null));
  if (!parsed.success) return unavailable();
  try {
    await withHost(async (db, hostId) => {
      const raw = (await cookies()).get("ost_host_recent")?.value;
      if (!isRecentlyVerified(raw, hostId))
        throw new Error("RECENT_AUTH_REQUIRED");
      await db.query("select private.remove_host_credential($1)", [
        parsed.data.credentialId,
      ]);
      await db.query("select private.revoke_host_sessions()");
    });
    await (await supabaseForRequest()).auth.signOut({ scope: "local" });
    return privateJson({ success: true, signedOut: true });
  } catch (error) {
    if (error instanceof Error && error.message === "RECENT_AUTH_REQUIRED")
      return privateJson(
        { error: "Sign in with a passkey again before changing credentials." },
        401,
      );
    return unavailable();
  }
}
