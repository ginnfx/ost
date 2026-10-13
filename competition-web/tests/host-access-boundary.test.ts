import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const source = (path: string) => readFileSync(resolve(root, path), "utf8");

describe("host access boundaries", () => {
  it("keeps host identity bootstrap in an operator script and one-use database token", () => {
    const bootstrap = source("scripts/bootstrap-host.mjs");
    const options = source("app/api/host/bootstrap/options/route.ts");
    const verify = source("app/api/host/bootstrap/verify/route.ts");
    expect(bootstrap).toContain("HOST_BOOTSTRAP_DB_URL");
    expect(bootstrap).toContain("private.platform_config");
    expect(options).toContain("sameOriginRequest(request)");
    expect(options).toContain("private.lookup_host_bootstrap");
    expect(verify).toContain("private.complete_host_bootstrap");
    expect(verify).not.toContain("SUPABASE_SERVICE_ROLE_KEY");
  });

  it("requires host authorization and a signed five-minute assertion for sensitive actions", () => {
    for (const path of [
      "app/api/host/security/route.ts",
      "app/api/host/security/recovery-codes/route.ts",
      "app/api/host/security/credentials/options/route.ts",
      "app/api/host/security/credentials/verify/route.ts",
      "app/api/host/security/sessions/route.ts",
    ]) {
      const route = source(path);
      expect(route, path).toContain("sameOriginRequest(request)");
      expect(route, path).toContain("withHost(");
    }
    expect(source("app/api/host/security/route.ts")).toContain(
      "isRecentlyVerified",
    );
    expect(source("app/api/host/security/recovery-codes/route.ts")).toContain(
      "isRecentlyVerified",
    );
    expect(source("app/api/host/recovery/verify/route.ts")).toContain(
      "private.complete_host_recovery",
    );
  });
});
