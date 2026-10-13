import { verifyRegistrationResponse } from "@simplewebauthn/server";
import { cookies } from "next/headers";
import { z } from "zod";
import {
  HostAccessDenied,
  SafeDatabaseError,
  withHost,
} from "@/lib/server/database";
import {
  failedRequest,
  privateJson,
  sameOriginRequest,
  unavailable,
} from "@/lib/server/http";
import {
  isRecentlyVerified,
  readCeremonyCookie,
  webAuthnConfig,
} from "@/lib/server/webauthn";

const schema = z
  .object({
    nickname: z.string().trim().min(1).max(60),
    response: z.record(z.string(), z.unknown()),
  })
  .strict();
const COOKIE = "ost_host_credential_ceremony";

export async function POST(request: Request) {
  if (!sameOriginRequest(request)) return unavailable();
  const input = schema.safeParse(await request.json().catch(() => null));
  if (!input.success) return unavailable();
  const store = await cookies();
  const ceremony = readCeremonyCookie(store.get(COOKIE)?.value);
  if (
    !ceremony ||
    ceremony.purpose !== "host-register" ||
    !ceremony.userId ||
    ceremony.tokenDigest
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
    await withHost(async (db, userId) => {
      if (
        userId !== ceremony.userId ||
        !isRecentlyVerified(store.get("ost_host_recent")?.value, userId)
      )
        throw new SafeDatabaseError("RECENT_AUTH_REQUIRED");
      await db.query(
        "select private.register_host_credential($1,$2,$3,$4,$5,$6,$7)",
        [
          credential.id,
          Buffer.from(credential.publicKey),
          credential.counter,
          credential.transports ?? [],
          credentialDeviceType,
          credentialBackedUp,
          input.data.nickname,
        ],
      );
    });
    store.set(COOKIE, "", {
      httpOnly: true,
      secure: process.env.NODE_ENV === "production",
      sameSite: "strict",
      path: "/api/host/security/credentials",
      maxAge: 0,
    });
    return privateJson({ success: true });
  } catch (error) {
    if (
      error instanceof SafeDatabaseError &&
      error.message === "RECENT_AUTH_REQUIRED"
    )
      return privateJson(
        { error: "Sign in with a passkey again before adding a credential." },
        401,
      );
    if (error instanceof HostAccessDenied) return unavailable();
    return failedRequest();
  }
}
