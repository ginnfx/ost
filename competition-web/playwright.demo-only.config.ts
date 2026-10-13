import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./e2e",
  testMatch: "demo-only.spec.ts",
  fullyParallel: true,
  reporter: "list",
  use: {
    baseURL: process.env.DEMO_BASE_URL ?? "http://127.0.0.1:3217",
    ...devices["iPhone 13"],
    browserName: "webkit",
  },
  webServer: process.env.DEMO_BASE_URL
    ? undefined
    : {
        command: "npm run dev -- --hostname 127.0.0.1 --port 3217",
        url: "http://127.0.0.1:3217/demo",
        reuseExistingServer: false,
        timeout: 120_000,
        env: { DEMO_ONLY: "true" },
      },
});
