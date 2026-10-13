import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { chromium } from "@playwright/test";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const axeSource = await import("node:fs").then(({ readFileSync }) =>
  readFileSync(require.resolve("axe-core/axe.min.js"), "utf8"),
);
const origin = process.env.DEMO_REVIEW_URL ?? "http://127.0.0.1:3222";
const outDir = resolve("screenshots/demo-after");
const browser = await chromium.launch({ headless: true });

function installMetricsScript() {
  return `(() => {
    window.__demoPerf = { lcp: 0, cls: 0, events: [] };
    try {
      new PerformanceObserver(list => { for (const entry of list.getEntries()) window.__demoPerf.lcp = entry.startTime; }).observe({type:'largest-contentful-paint', buffered:true});
      new PerformanceObserver(list => { for (const entry of list.getEntries()) if (!entry.hadRecentInput) window.__demoPerf.cls += entry.value; }).observe({type:'layout-shift', buffered:true});
      new PerformanceObserver(list => { for (const entry of list.getEntries()) if (entry.interactionId) window.__demoPerf.events.push({id:entry.interactionId, duration:entry.duration}); }).observe({type:'event', buffered:true, durationThreshold:16});
    } catch {}
  })()`;
}

async function scanAxe(page, screen) {
  await page.evaluate((source) => eval(source), axeSource);
  const report = await page.evaluate(async () => {
    const axe = window.axe;
    return axe.run(document, {
      runOnly: {
        type: "tag",
        values: ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"],
      },
    });
  });
  if (report.violations.length) {
    throw new Error(
      `${screen} axe: ${report.violations.map((item) => `${item.id}: ${item.help} ${JSON.stringify(item.nodes.map((node) => node.target))}`).join("; ")}`,
    );
  }
}

async function bundleStats(page) {
  return page.evaluate(() => {
    const scripts = performance
      .getEntriesByType("resource")
      .filter(
        (entry) =>
          entry.name.includes("/_next/static/") && entry.name.endsWith(".js"),
      );
    const unique = new Map(
      scripts.map((entry) => [entry.name, entry.encodedBodySize]),
    );
    return {
      chunks: [...unique].map(([url, bytes]) => ({
        file: url.split("/").at(-1),
        bytes,
      })),
      totalEncodedBytes: [...unique.values()].reduce(
        (sum, bytes) => sum + bytes,
        0,
      ),
    };
  });
}

async function snap(page, iteration, name, fullPage = false) {
  const file = resolve(outDir, `iteration-${iteration}`, `${name}.png`);
  mkdirSync(dirname(file), { recursive: true });
  await page.screenshot({ path: file, fullPage, animations: "disabled" });
  return file;
}

async function iteration({
  name,
  width,
  height,
  colorScheme,
  reducedMotion,
  threeD,
}) {
  const context = await browser.newContext({
    viewport: { width, height },
    deviceScaleFactor: width < 600 ? 2 : 1,
    colorScheme,
    reducedMotion: reducedMotion ? "reduce" : "no-preference",
    isMobile: width < 600,
    hasTouch: width < 600,
  });
  const page = await context.newPage();
  const consoleErrors = [];
  const pageErrors = [];
  page.on("console", (message) => {
    if (message.type() === "error") consoleErrors.push(message.text());
  });
  page.on("pageerror", (error) => pageErrors.push(error.message));
  await page.addInitScript(installMetricsScript());
  await page.goto(`${origin}/demo`);
  await page
    .getByRole("heading", { name: "Hear the track. Guess the story." })
    .waitFor();
  if (threeD) {
    await page.getByRole("button", { name: "Next mystery record" }).click();
    await page.waitForSelector(".intro-scene canvas");
    await page.evaluate(() => window.scrollTo(0, 0));
  } else {
    await page.waitForSelector(".intro-fallback");
  }
  await scanAxe(page, `${name} intro`);
  const intro = await snap(page, name, "intro");
  const introBundles = await bundleStats(page);

  await page.getByRole("button", { name: "Enter the listening room" }).click();
  await page.getByRole("button", { name: "Skip to listening" }).last().click();
  await page.getByRole("heading", { name: "Batch 1 of 5" }).waitFor();
  await scanAxe(page, `${name} listening grid`);
  const grid = await snap(page, name, "listening-grid", true);
  const gridBundles = await bundleStats(page);

  await page
    .getByRole("button", { name: /^Open fullscreen player for Mystery OST/ })
    .first()
    .click();
  await page.getByRole("dialog", { name: "Mystery listening" }).waitFor();
  if (threeD) await page.waitForSelector(".player-scene canvas");
  else await page.waitForSelector(".vinyl-fallback");
  await scanAxe(page, `${name} fullscreen player`);
  const player = await snap(page, name, "fullscreen-player");
  const playerBundles = await bundleStats(page);
  await page.getByRole("button", { name: "Close fullscreen player" }).click();

  await page.getByRole("button", { name: "Skip to reveals" }).click();
  await page.getByRole("button", { name: "Host" }).click();
  await page.getByRole("tab", { name: "Publish results" }).click();
  const hold = page.getByRole("button", {
    name: "Hold to confirm next reveal group",
  });
  await hold.scrollIntoViewIfNeeded();
  const box = await hold.boundingBox();
  if (!box)
    throw new Error("Host reveal confirmation control was not visible.");
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
  if (threeD) await page.waitForSelector(".reveal-scene canvas");
  else await page.waitForSelector(".reveal-fallback");
  await page.waitForTimeout(2900);
  await page.evaluate(() => window.scrollTo(0, 0));
  await scanAxe(page, `${name} reveal`);
  const reveal = await snap(page, name, "reveal");
  const revealBundles = await bundleStats(page);
  const metrics = await page.evaluate(() => {
    const interactions = new Map();
    for (const event of window.__demoPerf.events) {
      interactions.set(
        event.id,
        Math.max(interactions.get(event.id) ?? 0, event.duration),
      );
    }
    const values = [...interactions.values()].sort((a, b) => b - a);
    return {
      inpEstimateMs: values.length
        ? Math.round(values[Math.floor((values.length - 1) * 0.02)])
        : null,
      eventDurationsMs: values.map(Math.round),
      cls: Number(window.__demoPerf.cls.toFixed(4)),
    };
  });
  await context.close();
  return {
    name,
    screenshots: { intro, grid, player, reveal },
    bundles: {
      intro: introBundles,
      listening: gridBundles,
      player: playerBundles,
      reveal: revealBundles,
    },
    metrics,
    consoleErrors,
    pageErrors,
  };
}

async function mobilePerfProfile() {
  const seedContext = await browser.newContext();
  const seedPage = await seedContext.newPage();
  await seedPage.goto(`${origin}/demo`);
  await seedPage
    .getByRole("button", { name: "Enter the listening room" })
    .click();
  await seedPage
    .getByRole("button", { name: "Skip to listening" })
    .last()
    .click();
  await seedPage.getByRole("heading", { name: "Batch 1 of 5" }).waitFor();
  const listeningState = await seedPage.evaluate(() =>
    sessionStorage.getItem("ost-competition-demo-v2"),
  );
  await seedContext.close();
  if (!listeningState) throw new Error("Could not seed listening demo state.");

  const context = await browser.newContext({
    viewport: { width: 375, height: 812 },
    deviceScaleFactor: 2,
    isMobile: true,
    hasTouch: true,
    colorScheme: "dark",
  });
  const page = await context.newPage();
  await page.addInitScript((savedState) => {
    sessionStorage.setItem("ost-demo-entered", "yes");
    sessionStorage.setItem("ost-competition-demo-v2", savedState);
  }, listeningState);
  const cdp = await context.newCDPSession(page);
  await cdp.send("Emulation.setCPUThrottlingRate", { rate: 4 });
  await cdp.send("Network.enable");
  await cdp.send("Network.emulateNetworkConditions", {
    offline: false,
    latency: 150,
    downloadThroughput: (1.6 * 1024 * 1024) / 8,
    uploadThroughput: (750 * 1024) / 8,
    connectionType: "cellular3g",
  });
  await page.addInitScript(installMetricsScript());
  const start = Date.now();
  await page.goto(`${origin}/demo`, { waitUntil: "domcontentloaded" });
  await page.getByRole("heading", { name: "Batch 1 of 5" }).waitFor();
  const gridReadyMs = Date.now() - start;
  const gridMetrics = await page.evaluate(() => ({
    lcpMs: Math.round(window.__demoPerf.lcp),
    cls: Number(window.__demoPerf.cls.toFixed(4)),
  }));
  const grid = await bundleStats(page);
  await page
    .getByRole("button", { name: /^Open fullscreen player for Mystery OST/ })
    .first()
    .click();
  await page.waitForSelector(".player-scene canvas");
  const playing = await page
    .getByRole("button", { name: "Pause melody" })
    .isVisible();
  const player = await bundleStats(page);
  const fps = await page.evaluate(async () => {
    const frames = [];
    return await new Promise((resolve) => {
      let previous = performance.now();
      const started = previous;
      const tick = (now) => {
        frames.push(now - previous);
        previous = now;
        if (now - started >= 1800) {
          const span = frames.reduce((sum, value) => sum + value, 0);
          resolve(Math.round((frames.length * 1000) / span));
        } else requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    });
  });
  const metrics = await page.evaluate(() => {
    const interactions = new Map();
    for (const event of window.__demoPerf.events) {
      interactions.set(
        event.id,
        Math.max(interactions.get(event.id) ?? 0, event.duration),
      );
    }
    const values = [...interactions.values()].sort((a, b) => b - a);
    return {
      inpEstimateMs: values.length
        ? Math.round(values[Math.floor((values.length - 1) * 0.02)])
        : null,
      cls: Number(window.__demoPerf.cls.toFixed(4)),
    };
  });
  await context.close();
  return {
    profile: "Chromium iPhone 375x812, 2x DPR, 4x CPU, 150ms RTT, 1.6Mbps down",
    gridReadyMs,
    listeningGridLcpAndCls: gridMetrics,
    playerWasPlaying: playing,
    fpsDuringPlayer: fps,
    metrics,
    bundles: {
      listeningGrid: grid.totalEncodedBytes,
      playerAfter3DScene: player.totalEncodedBytes,
      threePayloadAddedAtPlayer: Math.max(
        0,
        player.totalEncodedBytes - grid.totalEncodedBytes,
      ),
    },
  };
}

try {
  const results = [];
  results.push(
    await iteration({
      name: "iphone-dark-3d",
      width: 375,
      height: 812,
      colorScheme: "dark",
      reducedMotion: false,
      threeD: true,
    }),
  );
  results.push(
    await iteration({
      name: "desktop-light-3d",
      width: 1280,
      height: 900,
      colorScheme: "light",
      reducedMotion: false,
      threeD: true,
    }),
  );
  results.push(
    await iteration({
      name: "iphone-reduced-motion-2d",
      width: 375,
      height: 812,
      colorScheme: "dark",
      reducedMotion: true,
      threeD: false,
    }),
  );
  const mobilePerf = await mobilePerfProfile();
  const result = {
    origin,
    screenshotReviewPasses: 3,
    iterations: results,
    mobilePerf,
  };
  const path = resolve(outDir, "review-results.json");
  writeFileSync(path, JSON.stringify(result, null, 2));
  process.stdout.write(
    `${JSON.stringify({ resultsPath: path, iterations: results }, null, 2)}\n`,
  );
} finally {
  await browser.close();
}
