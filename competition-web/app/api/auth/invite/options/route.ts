import { generateRegistrationOptions } from "@simplewebauthn/server";
import { cookies } from "next/headers";
import { z } from "zod";
import { SafeDatabaseError, withAppRole } from "@/lib/server/database";
import {
  failedRequest,
  privateJson,
  sameOriginRequest,
  unavailable,
} from "@/lib/server/http";
import {
  clientAddress,
  createChallenge,
  makeCeremonyCookie,
  sha256,
  webAuthnConfig,
} from "@/lib/server/webauthn";

const schema = z
  .object({ token: z.string().regex(/^[A-Za-z0-9_-]{43}$/) })
  .strict();
const COOKIE = "ost_webauthn_ceremony";

export async function POST(request: Request) {
  if (!sameOriginRequest(request)) return unavailable();
  const input = schema.safeParse(await request.json().catch(() => null));
  if (!input.success) return unavailable();
  try {
    const digest = sha256(input.data.token);
    const invite = await withAppRole(async (db) => {
      const limit = await db.query<{ allowed: boolean }>(
        "select private.rate_limit_hit($1,$2,$3,$4) as allowed",
        ["invite", sha256(clientAddress(request)), 15, 3600],
      );
      if (!limit.rows[0]?.allowed) throw new SafeDatabaseError("RATE_LIMITED");
      const { rows } = await db.query<{
        invite_id: string;
        email: string;
        auth_user_id: string | null;
        expires_at: string;
        redeemed_at: string | null;
        revoked_at: string | null;
      }>("select * from private.lookup_invite($1)", [digest]);
      const found = rows[0];
      const userId = found?.auth_user_id;
      if (
        !found ||
        typeof userId !== "string" ||
        found.redeemed_at ||
        found.revoked_at ||
        Date.parse(found.expires_at) <= Date.now()
      )
        throw new SafeDatabaseError("RESOURCE_UNAVAILABLE");
      return { ...found, auth_user_id: userId };
    });
    const { rpID, rpName } = webAuthnConfig();
    const options = await generateRegistrationOptions({
      rpName,
      rpID,
      userID: Buffer.from(invite.auth_user_id.replaceAll("-", ""), "hex"),
      challenge: createChallenge(),
      userName: "participant",
      userDisplayName: "Participant",
      attestationType: "none",
      authenticatorSelection: {
        residentKey: "required",
        userVerification: "required",
      },
      supportedAlgorithmIDs: [-7, -257],
    });
    const cookieStore = await cookies();
    cookieStore.set(
      COOKIE,
      makeCeremonyCookie({
        purpose: "invite-register",
        challenge: options.challenge,
        userId: invite.auth_user_id,
        inviteId: invite.invite_id,
      }),
      {
        httpOnly: true,
        secure: process.env.NODE_ENV === "production",
        sameSite: "strict",
        path: "/api/auth",
        maxAge: 300,
      },
    );
    return privateJson(options);
  } catch (error) {
    if (error instanceof Error && error.message === "RATE_LIMITED")
      return privateJson({ error: "Try again later." }, 429);
    if (error instanceof Error && error.message === "RESOURCE_UNAVAILABLE")
      return unavailable();
    return failedRequest();
  }
}
