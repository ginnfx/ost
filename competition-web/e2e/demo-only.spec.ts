import { expect, test } from "@playwright/test";
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";

const require = createRequire(import.meta.url);
const axeSource = readFileSync(require.resolve("axe-core/axe.min.js"), "utf8");

test("demo-only root redirects and all other app/API paths stop before handlers", async ({
  page,
  request,
}) => {
  await page.goto("/");
  await expect(page).toHaveURL(/\/demo$/);
  await expect(page).toHaveTitle("OST Competition demo");
  await expect(page.locator('meta[name="robots"]')).toHaveAttribute(
    "content",
    /noindex/,
  );
  await expect(page.locator('meta[property="og:title"]')).toHaveAttribute(
    "content",
    "OST Competition demo",
  );
  for (const path of [
    "/login",
    "/invite",
    "/app",
    "/host",
    "/api/competitions",
  ]) {
    const response = await request.get(path);
    expect(response.status()).toBe(404);
    expect(await response.text()).toContain("Not set up yet");
  }
  const how = await request.get("/how-it-works");
  expect(how.status()).toBe(200);
  expect(await how.text()).toContain("How it works");
  const robots = await request.get("/robots.txt");
  expect(robots.status()).toBe(200);
  expect(await robots.text()).toContain("Disallow: /");
});

test("demo-only pages have no axe WCAG A/AA violations on iPhone", async ({
  page,
}) => {
  for (const width of [320, 375]) {
    await page.setViewportSize({ width, height: 812 });
    for (const route of ["/demo", "/how-it-works"])
      for (const colorScheme of ["dark", "light"] as const) {
        await page.emulateMedia({ colorScheme });
        await page.goto(route);
        await page.evaluate((source) => eval(source), axeSource);
        const violations = await page.evaluate(async () => {
          const axe = (
            window as unknown as Window & {
              axe: {
                run: (
                  document: Document,
                  options: unknown,
                ) => Promise<{ violations: { id: string; help: string }[] }>;
              };
            }
          ).axe;
          return axe.run(document, {
            runOnly: {
              type: "tag",
              values: ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"],
            },
          });
        });
        expect(violations.violations.map((v) => `${v.id}: ${v.help}`)).toEqual(
          [],
        );
      }
  }
});
