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
const COOKIE = "ost_host_bootstrap";

export async function POST(request: Request) {
  if (!sameOriginRequest(request)) return unavailable();
  const parsed = schema.safeParse(await request.json().catch(() => null));
  if (!parsed.success) return unavailable();
  try {
    const digest = sha256(parsed.data.token);
    const userId = await withAppRole(async (db) => {
      const rate = await db.query<{ allowed: boolean }>(
        "select private.rate_limit_hit($1,$2,$3,$4) as allowed",
        ["login", sha256(clientAddress(request)), 12, 900],
      );
      if (!rate.rows[0]?.allowed) throw new SafeDatabaseError("RATE_LIMITED");
      const { rows } = await db.query<{
        user_id: string;
        expires_at: string;
        redeemed_at: string | null;
      }>("select * from private.lookup_host_bootstrap($1)", [digest]);
      const row = rows[0];
      if (!row || row.redeemed_at || Date.parse(row.expires_at) <= Date.now())
        throw new SafeDatabaseError("RESOURCE_UNAVAILABLE");
      return row.user_id;
    });
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
        purpose: "host-register",
        challenge: options.challenge,
        userId,
        tokenDigest: digest.toString("hex"),
      }),
      {
        httpOnly: true,
        secure: process.env.NODE_ENV === "production",
        sameSite: "strict",
        path: "/api/host/bootstrap",
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
