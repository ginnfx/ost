import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const compact = (value: string) =>
  value.replace(/\s/g, "").replaceAll('"', "'");
const auth = compact(readFileSync(resolve(root, "lib/server/auth.ts"), "utf8"));
const database = compact(
  readFileSync(resolve(root, "lib/server/database.ts"), "utf8"),
);
const storage = compact(
  readFileSync(resolve(root, "lib/server/storage.ts"), "utf8"),
);
const http = compact(readFileSync(resolve(root, "lib/server/http.ts"), "utf8"));

describe("server-only access boundary", () => {
  it("verifies sessions through Supabase Auth and sets secure, HTTP-only cookies", () => {
    expect(compact(auth)).toContain(compact("supabase.auth.getUser()"));
    expect(compact(auth)).toContain(compact("httpOnly:true"));
    expect(compact(auth)).toContain(compact("sameSite:'lax'"));
    expect(compact(auth)).toContain(
      compact("secure:process.env.NODE_ENV==='production'"),
    );
  });
  it("executes database work under a non-owner role and verified identity", () => {
    expect(compact(database)).toContain(compact("verifiedCurrentUser()"));
    expect(compact(database)).toContain(compact("set local role ost_web_app"));
    expect(compact(database)).toContain(
      compact("set_config('request.jwt.claim.sub'"),
    );
    expect(compact(database)).toContain(compact("private.is_platform_host()"));
    expect(compact(database)).not.toContain(
      compact("SUPABASE_SERVICE_ROLE_KEY"),
    );
  });
  it("routes all private media through a server-only storage abstraction", () => {
    expect(compact(storage)).toContain(compact("interface PrivateObjectStore"));
    expect(compact(storage)).toContain(compact("SUPABASE_SERVICE_ROLE_KEY"));
    expect(compact(storage)).toContain(compact("createSignedUrl"));
    expect(compact(storage)).toContain(compact("assertOpaqueStorageKey"));
  });
  it("requires same-origin mutations and gives no-store generic private responses", () => {
    expect(compact(http)).toContain(compact("request.headers.get('origin')"));
    expect(compact(http)).toContain(
      compact("'Cache-Control':'private, no-store, max-age=0'"),
    );
    expect(compact(http)).toContain(
      compact("{error:'This item is not available.'}"),
    );
    expect(compact(http)).not.toMatch(/stack|sqlstate|postgres/i);
  });
});
