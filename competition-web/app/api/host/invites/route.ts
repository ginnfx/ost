import { randomBytes } from "node:crypto";
import { z } from "zod";
import {
  HostAccessDenied,
  SafeDatabaseError,
  withHost,
} from "@/lib/server/database";
import { supabaseAdmin } from "@/lib/server/admin-auth";
import { opaqueToken, sha256 } from "@/lib/server/webauthn";
import {
  failedRequest,
  privateJson,
  sameOriginRequest,
  unavailable,
} from "@/lib/server/http";

const bodySchema = z.object({ competitionId: z.string().uuid() }).strict();

export async function POST(request: Request) {
  if (!sameOriginRequest(request))
    return privateJson({ error: "This item is not available." }, 404);
  const parsed = bodySchema.safeParse(await request.json().catch(() => null));
  if (!parsed.success)
    return privateJson({ error: "A valid competition is required." }, 400);
  const configuredSite = process.env.NEXT_PUBLIC_SITE_URL;
  if (!configuredSite) return failedRequest();
  let inviteBase: string;
  try {
    inviteBase = new URL("/invite", configuredSite).toString();
  } catch {
    return failedRequest();
  }
  try {
    const inviteUrl = await withHost(async (db, userId) => {
      const limited = await db.query<{ allowed: boolean }>(
        "select private.rate_limit_hit($1,$2,$3,$4) as allowed",
        ["invite", sha256(userId), 20, 3600],
      );
      if (!limited.rows[0]?.allowed)
        throw new SafeDatabaseError("RATE_LIMITED");
      const admin = supabaseAdmin();
      // Supabase Auth requires an email-shaped identity. This reserved .invalid address is opaque,
      // cannot receive mail, and is never shown to participants or used for delivery.
      const email = `participant-${randomBytes(18).toString("hex")}@participants.invalid`;
      const { data, error } = await admin.auth.admin.createUser({
        email,
        email_confirm: true,
        app_metadata: {},
      });
      if (error || !data.user) throw new Error("INVITE_CREATE_FAILED");
      const token = opaqueToken();
      try {
        await db.query("select private.create_invite($1,$2,$3,$4,$5,$6)", [
          parsed.data.competitionId,
          email,
          sha256(token),
          new Date(Date.now() + 7 * 86400_000).toISOString(),
          userId,
          data.user.id,
        ]);
      } catch (error) {
        await admin.auth.admin.deleteUser(data.user.id).catch(() => undefined);
        throw error;
      }
      return `${inviteBase}#${token}`;
    });
    return privateJson({ inviteUrl }, 201);
  } catch (error) {
    if (error instanceof Error && error.message === "RATE_LIMITED")
      return privateJson({ error: "Try again later." }, 429);
    if (error instanceof HostAccessDenied) return unavailable();
    return failedRequest();
  }
}
