import { verifyRegistrationResponse } from "@simplewebauthn/server";
import { cookies } from "next/headers";
import { z } from "zod";
import { withAppRole } from "@/lib/server/database";
import { establishSupabaseSession } from "@/lib/server/magic-session";
import {
  failedRequest,
  privateJson,
  sameOriginRequest,
  unavailable,
} from "@/lib/server/http";
import { readCeremonyCookie, webAuthnConfig } from "@/lib/server/webauthn";

const schema = z
  .object({
    nickname: z.string().trim().min(1).max(40),
    response: z.record(z.string(), z.unknown()),
  })
  .strict();
const COOKIE = "ost_webauthn_ceremony";

export async function POST(request: Request) {
  if (!sameOriginRequest(request)) return unavailable();
  const input = schema.safeParse(await request.json().catch(() => null));
  if (!input.success)
    return privateJson(
      { error: "Enter a nickname of 1 to 40 characters." },
      400,
    );
  const cookieStore = await cookies();
  const ceremony = readCeremonyCookie(cookieStore.get(COOKIE)?.value);
  if (
    !ceremony ||
    ceremony.purpose !== "invite-register" ||
    !ceremony.inviteId ||
    !ceremony.userId
  )
    return unavailable();
  try {
    const { rpID, origins } = webAuthnConfig();
    const verification = await verifyRegistrationResponse({
      response: input.data.response as never,
      expectedChallenge: ceremony.challenge,
      expectedOrigin: origins,
      expectedRPID: rpID,
      requireUserVerification: true,
    });
    if (!verification.verified || !verification.registrationInfo)
      return unavailable();
    const info = verification.registrationInfo;
    const { credential, credentialDeviceType, credentialBackedUp } = info;
    await withAppRole(async (db) => {
      await db.query(
        "select private.register_invite_passkey($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)",
        [
          ceremony.inviteId,
          ceremony.userId,
          input.data.nickname,
          credential.id,
          Buffer.from(credential.publicKey),
          credential.counter,
          credential.transports ?? [],
          credentialDeviceType,
          credentialBackedUp,
          "Primary passkey",
        ],
      );
    });
    await establishSupabaseSession(ceremony.userId);
    cookieStore.set(COOKIE, "", {
      httpOnly: true,
      secure: process.env.NODE_ENV === "production",
      sameSite: "strict",
      path: "/api/auth",
      maxAge: 0,
    });
    return privateJson({ success: true, destination: "/app" });
  } catch (error) {
    if (error instanceof Error && error.message === "AUTH_SESSION_FAILED")
      return failedRequest();
    return unavailable();
  }
}
