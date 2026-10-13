import { generateRegistrationOptions } from "@simplewebauthn/server";
import { cookies } from "next/headers";
import {
  HostAccessDenied,
  SafeDatabaseError,
  withHost,
} from "@/lib/server/database";
import { privateJson, sameOriginRequest, unavailable } from "@/lib/server/http";
import {
  createChallenge,
  isRecentlyVerified,
  makeCeremonyCookie,
  webAuthnConfig,
} from "@/lib/server/webauthn";

const COOKIE = "ost_host_credential_ceremony";

export async function POST(request: Request) {
  if (!sameOriginRequest(request)) return unavailable();
  try {
    const registration = await withHost(async (db, userId) => {
      const raw = (await cookies()).get("ost_host_recent")?.value;
      if (!isRecentlyVerified(raw, userId))
        throw new SafeDatabaseError("RECENT_AUTH_REQUIRED");
      const { rows } = await db.query<{
        credential_id: string;
        transports: string[];
      }>(
        "select credential_id,transports from private.passkey_ids_for_user($1)",
        [userId],
      );
      const { rpID, rpName } = webAuthnConfig();
      const options = await generateRegistrationOptions({
        rpName,
        rpID,
        userID: Buffer.from(userId.replaceAll("-", ""), "hex"),
        userName: "host",
        userDisplayName: "Competition host",
        challenge: createChallenge(),
        excludeCredentials: rows.map((row) => ({
          id: row.credential_id,
          transports: row.transports as never,
        })),
        attestationType: "none",
        authenticatorSelection: {
          residentKey: "required",
          userVerification: "required",
        },
        supportedAlgorithmIDs: [-7, -257],
      });
      return { userId, options };
    });
    (await cookies()).set(
      COOKIE,
      makeCeremonyCookie({
        purpose: "host-register",
        challenge: registration.options.challenge,
        userId: registration.userId,
      }),
      {
        httpOnly: true,
        secure: process.env.NODE_ENV === "production",
        sameSite: "strict",
        path: "/api/host/security/credentials",
        maxAge: 300,
      },
    );
    return privateJson(registration.options);
  } catch (error) {
    if (
      error instanceof SafeDatabaseError &&
      error.message === "RECENT_AUTH_REQUIRED"
    )
      return privateJson(
        { error: "Sign in with a passkey again before adding a credential." },
        401,
      );
    return error instanceof HostAccessDenied ? unavailable() : unavailable();
  }
}
