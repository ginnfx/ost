import { verifyAuthenticationResponse } from "@simplewebauthn/server";
import { cookies } from "next/headers";
import { z } from "zod";
import { SafeDatabaseError, withAppRole } from "@/lib/server/database";
import { establishSupabaseSession } from "@/lib/server/magic-session";
import { privateJson, sameOriginRequest, unavailable } from "@/lib/server/http";
import {
  clientAddress,
  makeRecentVerification,
  readCeremonyCookie,
  sha256,
  webAuthnConfig,
} from "@/lib/server/webauthn";

const schema = z
  .object({ response: z.record(z.string(), z.unknown()) })
  .strict();
const COOKIE = "ost_webauthn_ceremony";

export async function POST(request: Request) {
  if (!sameOriginRequest(request)) return unavailable();
  const input = schema.safeParse(await request.json().catch(() => null));
  if (!input.success) return unavailable();
  const store = await cookies();
  const ceremony = readCeremonyCookie(store.get(COOKIE)?.value);
  if (!ceremony || ceremony.purpose !== "passkey-login") return unavailable();
  try {
    const result = await withAppRole(async (db) => {
      const limit = await db.query<{ allowed: boolean }>(
        "select private.rate_limit_hit($1,$2,$3,$4) as allowed",
        ["login", sha256(clientAddress(request)), 12, 900],
      );
      if (!limit.rows[0]?.allowed) throw new SafeDatabaseError("RATE_LIMITED");
      const id = input.data.response.id;
      if (typeof id !== "string" || id.length > 1024)
        throw new Error("RESOURCE_UNAVAILABLE");
      const { rows } = await db.query<{
        user_id: string;
        public_key: Buffer;
        sign_count: string;
        transports: string[];
        device_type: string;
        backed_up: boolean;
      }>("select * from private.passkey_lookup($1)", [id]);
      const credential = rows[0];
      if (!credential) throw new Error("RESOURCE_UNAVAILABLE");
      const { rpID, origins } = webAuthnConfig();
      const verification = await verifyAuthenticationResponse({
        response: input.data.response as never,
        expectedChallenge: ceremony.challenge,
        expectedOrigin: origins,
        expectedRPID: rpID,
        requireUserVerification: true,
        credential: {
          id,
          publicKey: new Uint8Array(credential.public_key),
          counter: Number(credential.sign_count),
          transports: credential.transports as never,
        },
      });
      if (!verification.verified) throw new Error("RESOURCE_UNAVAILABLE");
      await db.query("select private.update_passkey_counter($1,$2)", [
        id,
        verification.authenticationInfo.newCounter,
      ]);
      return credential.user_id;
    });
    await establishSupabaseSession(result);
    store.set(COOKIE, "", {
      httpOnly: true,
      secure: process.env.NODE_ENV === "production",
      sameSite: "strict",
      path: "/api/auth",
      maxAge: 0,
    });
    store.set("ost_host_recent", makeRecentVerification(result), {
      httpOnly: true,
      secure: process.env.NODE_ENV === "production",
      sameSite: "strict",
      path: "/",
      maxAge: 300,
    });
    return privateJson({ success: true, destination: "/app" });
  } catch (error) {
    if (error instanceof Error && error.message === "RATE_LIMITED")
      return privateJson({ error: "Try again later." }, 429);
    return unavailable();
  }
}
