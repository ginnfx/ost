import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./e2e",
  testMatch: "webauthn.chromium.spec.ts",
  fullyParallel: false,
  reporter: "list",
  timeout: 240_000,
  use: {
    baseURL: "http://localhost:3212",
    browserName: "chromium",
    headless: true,
  },
  webServer: {
    command: "npm run dev -- --hostname 127.0.0.1 --port 3212",
    url: "http://localhost:3212/login",
    reuseExistingServer: false,
    timeout: 120_000,
    env: {
      NEXT_PUBLIC_SITE_URL: "http://localhost:3212",
      NEXT_PUBLIC_SITE_ORIGINS: "http://localhost:3212",
      WEBAUTHN_RP_ID: "localhost",
      WEBAUTHN_ALLOWED_ORIGINS: "http://localhost:3212",
    },
  },
});
