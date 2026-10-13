import { expect, test } from "@playwright/test";
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";

const require = createRequire(import.meta.url);
const axeSource = readFileSync(require.resolve("axe-core/axe.min.js"), "utf8");

async function checkAxe(page: import("@playwright/test").Page) {
  await page.evaluate((source) => eval(source), axeSource);
  const violations = await page.evaluate(async () => {
    const axe = (
      window as unknown as Window & {
        axe: {
          run: (
            doc: Document,
            options: unknown,
          ) => Promise<{
            violations: {
              id: string;
              help: string;
              nodes: { target: string[] }[];
            }[];
          }>;
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
  expect(
    violations.violations.map(
      (item) => `${item.id}: ${item.help}: ${JSON.stringify(item.nodes)}`,
    ),
  ).toEqual([]);
}

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
                ) => Promise<{
                  violations: {
                    id: string;
                    help: string;
                    nodes: { target: string[] }[];
                  }[];
                }>;
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
        expect(
          violations.violations.map(
            (v) => `${v.id}: ${v.help}: ${JSON.stringify(v.nodes)}`,
          ),
        ).toEqual([]);
      }
  }
});

test("participant grid and full player stay accessible on a phone", async ({
  page,
}) => {
  await page.setViewportSize({ width: 375, height: 812 });
  await page.emulateMedia({ colorScheme: "dark", reducedMotion: "reduce" });
  await page.goto("/demo");
  await expect(page.locator(".intro-fallback")).toBeVisible();
  await checkAxe(page);
  await page.getByRole("button", { name: "Enter the listening room" }).click();
  await page.getByRole("button", { name: "Skip to listening" }).last().click();
  await expect(
    page.getByRole("heading", { name: "Batch 1 of 5" }),
  ).toBeVisible();
  await page.waitForFunction(() => window.scrollY === 0);
  await checkAxe(page);
  await page
    .getByRole("button", { name: /^Open fullscreen player for Mystery OST/ })
    .first()
    .click();
  await expect(page.locator(".vinyl-fallback")).toBeVisible();
  await checkAxe(page);
  await page.getByRole("button", { name: "Close fullscreen player" }).click();
  await page.getByRole("button", { name: "Skip to reveals" }).click();
  await page.getByRole("button", { name: "Host" }).click();
  await page.getByRole("tab", { name: "Publish results" }).click();
  const confirm = page.getByRole("button", {
    name: "Hold to confirm next reveal group",
  });
  const box = await confirm.boundingBox();
  if (!box) throw new Error("Reveal confirmation button was not visible.");
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  await page.waitForTimeout(1700);
  await page.mouse.up();
  await page
    .getByRole("button", { name: "Simulate passkey verification" })
    .click();
  await page.getByRole("button", { name: "Reveal next soundtrack" }).click();
  await page.getByRole("button", { name: "Participant" }).click();
  await page.getByRole("button", { name: "Watch reveal" }).click();
  await expect(page.locator(".reveal-fallback")).toBeVisible();
  await checkAxe(page);
});
