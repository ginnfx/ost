import { generateAuthenticationOptions } from "@simplewebauthn/server";
import { cookies } from "next/headers";
import { SafeDatabaseError, withAppRole } from "@/lib/server/database";
import {
  failedRequest,
  privateJson,
  sameOriginRequest,
  unavailable,
} from "@/lib/server/http";
import {
  clientAddress,
  makeCeremonyCookie,
  sha256,
  webAuthnConfig,
} from "@/lib/server/webauthn";

const COOKIE = "ost_webauthn_ceremony";
export async function POST(request: Request) {
  if (!sameOriginRequest(request)) return unavailable();
  try {
    const { rpID } = webAuthnConfig();
    const options = await withAppRole(async (db) => {
      const limit = await db.query<{ allowed: boolean }>(
        "select private.rate_limit_hit($1,$2,$3,$4) as allowed",
        ["login", sha256(clientAddress(request)), 12, 900],
      );
      if (!limit.rows[0]?.allowed) throw new SafeDatabaseError("RATE_LIMITED");
      return generateAuthenticationOptions({
        rpID,
        userVerification: "required",
      });
    });
    const store = await cookies();
    store.set(
      COOKIE,
      makeCeremonyCookie({
        purpose: "passkey-login",
        challenge: options.challenge,
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
    return failedRequest();
  }
}
