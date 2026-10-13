import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const compact = (value: string) =>
  value.replace(/\s/g, "").replaceAll('"', "'");
const file = (path: string) =>
  compact(readFileSync(resolve(root, path), "utf8"));

describe("invite and WebAuthn boundaries", () => {
  it("uses server-side WebAuthn verification with required user verification and the configured RP ID", () => {
    const registration = file("app/api/auth/invite/verify/route.ts");
    const assertion = file("app/api/auth/passkey/verify/route.ts");
    expect(compact(registration)).toContain(
      compact("verifyRegistrationResponse"),
    );
    expect(compact(assertion)).toContain(
      compact("verifyAuthenticationResponse"),
    );
    for (const route of [registration, assertion]) {
      expect(route).toContain(compact("requireUserVerification:true"));
      expect(route).toContain(compact("expectedOrigin:origins"));
      expect(route).toContain(compact("expectedRPID:rpID"));
      expect(route).toContain(compact("sameOriginRequest(request)"));
    }
  });
  it("stores only an invite digest, uses a URL fragment, and consumes invites once", () => {
    const invite = file("app/api/host/invites/route.ts");
    const participant = file("app/api/auth/invite/verify/route.ts");
    const client = file("components/invite-enrollment.tsx");
    const migration = file(
      "supabase/migrations/20261013180000_auth_foundation.sql",
    );
    expect(compact(invite)).toContain(compact("sha256(token)"));
    expect(compact(invite)).toContain(compact("}#${token}"));
    expect(compact(client)).toContain(compact("window.history.replaceState"));
    expect(compact(migration)).toContain(compact("i.redeemed_at is null"));
    expect(compact(participant)).toContain(compact("register_invite_passkey"));
  });
  it("creates nickname-only invites with a non-routable Supabase identifier", () => {
    const invite = file("app/api/host/invites/route.ts");
    expect(compact(invite)).toContain(compact("@participants.invalid"));
    expect(compact(invite)).not.toContain(compact("email:z.string()"));
    expect(compact(invite)).toContain(compact("randomBytes(18)"));
  });
  it("does not authorize from editable metadata or expose auth admin operations to clients", () => {
    const invite = file("app/api/host/invites/route.ts");
    const server = file("lib/server/admin-auth.ts");
    expect(compact(invite)).toContain(compact("withHost"));
    expect(compact(invite)).toContain(compact("private.create_invite"));
    expect(compact(server)).toContain(compact("import 'server-only'"));
    expect(file("lib/server/database.ts")).toContain(
      "private.is_platform_host()",
    );
  });
});
