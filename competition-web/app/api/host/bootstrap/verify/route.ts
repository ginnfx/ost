import { verifyRegistrationResponse } from "@simplewebauthn/server";
import { cookies } from "next/headers";
import { z } from "zod";
import { establishSupabaseSession } from "@/lib/server/magic-session";
import { withAppRole } from "@/lib/server/database";
import {
  failedRequest,
  privateJson,
  sameOriginRequest,
  unavailable,
} from "@/lib/server/http";
import {
  makeRecentVerification,
  readCeremonyCookie,
  webAuthnConfig,
} from "@/lib/server/webauthn";

const schema = z
  .object({
    nickname: z.string().trim().min(1).max(60),
    response: z.record(z.string(), z.unknown()),
  })
  .strict();
const COOKIE = "ost_host_bootstrap";
const RECENT = "ost_host_recent";

export async function POST(request: Request) {
  if (!sameOriginRequest(request)) return unavailable();
  const input = schema.safeParse(await request.json().catch(() => null));
  if (!input.success)
    return privateJson(
      { error: "Enter a passkey name between 1 and 60 characters." },
      400,
    );
  const store = await cookies();
  const ceremony = readCeremonyCookie(store.get(COOKIE)?.value);
  if (
    !ceremony ||
    ceremony.purpose !== "host-register" ||
    !ceremony.userId ||
    !ceremony.tokenDigest
  )
    return unavailable();
  const tokenDigest = ceremony.tokenDigest;
  try {
    const { rpID, origins } = webAuthnConfig();
    const result = await verifyRegistrationResponse({
      response: input.data.response as never,
      expectedChallenge: ceremony.challenge,
      expectedOrigin: origins,
      expectedRPID: rpID,
      requireUserVerification: true,
    });
    if (!result.verified || !result.registrationInfo) return unavailable();
    const info = result.registrationInfo;
    const { credential, credentialDeviceType, credentialBackedUp } = info;
    const hostId = await withAppRole((db) =>
      db
        .query<{ complete_host_bootstrap: string }>(
          "select private.complete_host_bootstrap($1,$2,$3,$4,$5,$6,$7,$8)",
          [
            Buffer.from(tokenDigest, "hex"),
            credential.id,
            Buffer.from(credential.publicKey),
            credential.counter,
            credential.transports ?? [],
            credentialDeviceType,
            credentialBackedUp,
            input.data.nickname,
          ],
        )
        .then((r) => r.rows[0]!.complete_host_bootstrap),
    );
    await establishSupabaseSession(hostId);
    store.set(COOKIE, "", {
      httpOnly: true,
      secure: process.env.NODE_ENV === "production",
      sameSite: "strict",
      path: "/api/host/bootstrap",
      maxAge: 0,
    });
    store.set(RECENT, makeRecentVerification(hostId), {
      httpOnly: true,
      secure: process.env.NODE_ENV === "production",
      sameSite: "strict",
      path: "/",
      maxAge: 300,
    });
    return privateJson({ success: true, destination: "/host/security" });
  } catch {
    return failedRequest();
  }
}
