import { verifyRegistrationResponse } from "@simplewebauthn/server";
import { cookies } from "next/headers";
import { z } from "zod";
import { establishSupabaseSession } from "@/lib/server/magic-session";
import { withAppRole } from "@/lib/server/database";
import { privateJson, sameOriginRequest, unavailable } from "@/lib/server/http";
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
const COOKIE = "ost_host_recovery";

export async function POST(request: Request) {
  if (!sameOriginRequest(request)) return unavailable();
  const input = schema.safeParse(await request.json().catch(() => null));
  if (!input.success) return unavailable();
  const store = await cookies();
  const ceremony = readCeremonyCookie(store.get(COOKIE)?.value);
  if (
    !ceremony ||
    ceremony.purpose !== "host-recovery" ||
    !ceremony.userId ||
    !ceremony.tokenDigest
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
    const hostId = await withAppRole((db) =>
      db
        .query<{ complete_host_recovery: string }>(
          "select private.complete_host_recovery($1,$2,$3,$4,$5,$6,$7,$8)",
          [
            Buffer.from(ceremony.tokenDigest!, "hex"),
            credential.id,
            Buffer.from(credential.publicKey),
            credential.counter,
            credential.transports ?? [],
            credentialDeviceType,
            credentialBackedUp,
            input.data.nickname,
          ],
        )
        .then((r) => r.rows[0]!.complete_host_recovery),
    );
    await establishSupabaseSession(hostId);
    store.set(COOKIE, "", {
      httpOnly: true,
      secure: process.env.NODE_ENV === "production",
      sameSite: "strict",
      path: "/api/host/recovery",
      maxAge: 0,
    });
    store.set("ost_host_recent", makeRecentVerification(hostId), {
      httpOnly: true,
      secure: process.env.NODE_ENV === "production",
      sameSite: "strict",
      path: "/",
      maxAge: 300,
    });
    return privateJson({ success: true, destination: "/host/security" });
  } catch {
    return unavailable();
  }
}
