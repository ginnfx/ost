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
  .object({ code: z.string().regex(/^[A-Za-z0-9_-]{22}$/) })
  .strict();
const COOKIE = "ost_host_recovery";

export async function POST(request: Request) {
  if (!sameOriginRequest(request)) return unavailable();
  const parsed = schema.safeParse(await request.json().catch(() => null));
  if (!parsed.success) return unavailable();
  try {
    const digest = sha256(parsed.data.code);
    const userId = await withAppRole(async (db) => {
      const limit = await db.query<{ allowed: boolean }>(
        "select private.rate_limit_hit($1,$2,$3,$4) as allowed",
        ["recovery", sha256(clientAddress(request)), 6, 3600],
      );
      if (!limit.rows[0]?.allowed) throw new SafeDatabaseError("RATE_LIMITED");
      const result = await db.query<{ prepare_host_recovery: string }>(
        "select private.prepare_host_recovery($1)",
        [digest],
      );
      return result.rows[0]?.prepare_host_recovery;
    });
    if (!userId) return unavailable();
    const { rpID, rpName } = webAuthnConfig();
    const options = await generateRegistrationOptions({
      rpName,
      rpID,
      userID: Buffer.from(userId.replaceAll("-", ""), "hex"),
      userName: "host",
      userDisplayName: "Competition host",
      challenge: createChallenge(),
      attestationType: "none",
      authenticatorSelection: {
        residentKey: "required",
        userVerification: "required",
      },
      supportedAlgorithmIDs: [-7, -257],
    });
    (await cookies()).set(
      COOKIE,
      makeCeremonyCookie({
        purpose: "host-recovery",
        challenge: options.challenge,
        userId,
        tokenDigest: digest.toString("hex"),
      }),
      {
        httpOnly: true,
        secure: process.env.NODE_ENV === "production",
        sameSite: "strict",
        path: "/api/host/recovery",
        maxAge: 300,
      },
    );
    return privateJson(options);
  } catch (error) {
    if (error instanceof SafeDatabaseError && error.message === "RATE_LIMITED")
      return privateJson({ error: "Try again later." }, 429);
    if (error instanceof SafeDatabaseError) return unavailable();
    return failedRequest();
  }
}
