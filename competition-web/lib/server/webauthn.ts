import "server-only";
import {
  createHash,
  createHmac,
  randomBytes,
  timingSafeEqual,
} from "node:crypto";

export type Ceremony = {
  purpose:
    "invite-register" | "passkey-login" | "host-register" | "host-recovery";
  challenge: string;
  userId?: string;
  inviteId?: string;
  email?: string;
  tokenDigest?: string;
  expiresAt: number;
};

export function webAuthnConfig() {
  const rpID = required("WEBAUTHN_RP_ID");
  const origins = required("WEBAUTHN_ALLOWED_ORIGINS")
    .split(",")
    .map((value) => new URL(value.trim()).origin);
  for (const origin of origins) {
    const host = new URL(origin).hostname;
    if (
      process.env.NODE_ENV === "production" &&
      host !== rpID &&
      !host.endsWith(`.${rpID}`)
    ) {
      throw new Error(
        "WebAuthn origin does not match the permanent relying party ID.",
      );
    }
  }
  return {
    rpID,
    origins,
    rpName: process.env.WEBAUTHN_RP_NAME || "OST Competition",
  };
}

export function makeCeremonyCookie(
  ceremony: Omit<Ceremony, "expiresAt">,
): string {
  const value = Buffer.from(
    JSON.stringify({ ...ceremony, expiresAt: Date.now() + 5 * 60_000 }),
  ).toString("base64url");
  const signature = createHmac("sha256", challengeSecret())
    .update(value)
    .digest("base64url");
  return `${value}.${signature}`;
}

export function readCeremonyCookie(raw: string | undefined): Ceremony | null {
  if (!raw) return null;
  const [value, signature, extra] = raw.split(".");
  if (!value || !signature || extra) return null;
  const expected = createHmac("sha256", challengeSecret())
    .update(value)
    .digest();
  let actual: Buffer;
  try {
    actual = Buffer.from(signature, "base64url");
  } catch {
    return null;
  }
  if (actual.length !== expected.length || !timingSafeEqual(actual, expected))
    return null;
  try {
    const data = JSON.parse(
      Buffer.from(value, "base64url").toString("utf8"),
    ) as Ceremony;
    if (
      data.expiresAt < Date.now() ||
      data.expiresAt > Date.now() + 5 * 60_000 + 1000
    )
      return null;
    return data;
  } catch {
    return null;
  }
}

export function createChallenge(): string {
  return randomBytes(32).toString("base64url");
}
export function makeRecentVerification(userId: string): string {
  const issuedAt = Date.now().toString();
  const value = `${userId}.${issuedAt}`;
  const signature = createHmac("sha256", challengeSecret())
    .update(`recent:${value}`)
    .digest("base64url");
  return `${value}.${signature}`;
}
export function isRecentlyVerified(
  raw: string | undefined,
  userId: string,
): boolean {
  if (!raw) return false;
  const [savedUser, timestamp, signature, extra] = raw.split(".");
  if (!savedUser || !timestamp || !signature || extra || savedUser !== userId)
    return false;
  const time = Number(timestamp);
  if (
    !Number.isSafeInteger(time) ||
    time > Date.now() ||
    Date.now() - time > 300_000
  )
    return false;
  const expected = createHmac("sha256", challengeSecret())
    .update(`recent:${savedUser}.${timestamp}`)
    .digest();
  const actual = Buffer.from(signature, "base64url");
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}
export function opaqueToken(): string {
  return randomBytes(32).toString("base64url");
}
export function sha256(value: string): Buffer {
  return createHash("sha256").update(value).digest();
}
export function clientAddress(request: Request): string {
  const forwarded = request.headers
    .get("x-forwarded-for")
    ?.split(",")[0]
    ?.trim();
  return forwarded || "unknown";
}
function challengeSecret(): string {
  const value = required("WEBAUTHN_CHALLENGE_SECRET");
  if (Buffer.byteLength(value) < 32)
    throw new Error("WebAuthn challenge secret must be at least 32 bytes.");
  return value;
}
function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Server configuration is missing: ${name}`);
  return value;
}
