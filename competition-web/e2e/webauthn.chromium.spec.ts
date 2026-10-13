import { createHash, randomBytes, randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import nextEnv from "@next/env";
import { createClient } from "@supabase/supabase-js";
import { expect, test, type Page } from "@playwright/test";
import { createRequire } from "node:module";

nextEnv.loadEnvConfig(process.cwd());
const require = createRequire(import.meta.url);
const axeSource = readFileSync(require.resolve("axe-core/axe.min.js"), "utf8");

const admin = createClient(
  process.env.SUPABASE_URL!,
  process.env.SUPABASE_SERVICE_ROLE_KEY!,
  { auth: { persistSession: false, autoRefreshToken: false } },
);
const dbContainer =
  process.env.LOCAL_SUPABASE_DB_CONTAINER ??
  "supabase_db_ost-competition-private";
const sql = (statement: string) =>
  execFileSync(
    "docker",
    [
      "exec",
      "-i",
      dbContainer,
      "psql",
      "-U",
      "supabase_admin",
      "-d",
      "postgres",
      "-v",
      "ON_ERROR_STOP=1",
      "-qAt",
      "-c",
      statement,
    ],
    { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
  ).trim();

async function addVirtualAuthenticator(page: Page) {
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("WebAuthn.enable");
  await cdp.send("WebAuthn.addVirtualAuthenticator", {
    options: {
      protocol: "ctap2",
      transport: "internal",
      hasResidentKey: true,
      hasUserVerification: true,
      isUserVerified: true,
      automaticPresenceSimulation: true,
    },
  });
  return cdp;
}

async function assertAxe(page: Page) {
  await page.evaluate((source) => eval(source), axeSource);
  const report = await page.evaluate(async () => {
    const axe = (
      window as unknown as Window & {
        axe: {
          run: (
            target: Document,
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
    report.violations.map(
      (violation) =>
        `${violation.id}: ${violation.help} (${violation.nodes.map((node) => node.target.join(",")).join("; ")})`,
    ),
  ).toEqual([]);
  process.stdout.write(`axe ${page.url()} ${Date.now()}\n`);
}

async function enableMobileVitals(page: Page) {
  await page.setViewportSize({ width: 375, height: 812 });
  const network = await page.context().newCDPSession(page);
  await network.send("Network.enable");
  await network.send("Network.emulateNetworkConditions", {
    offline: false,
    latency: 150,
    downloadThroughput: (1.6 * 1024 * 1024) / 8,
    uploadThroughput: (750 * 1024) / 8,
    connectionType: "cellular3g",
  });
  await network.send("Emulation.setCPUThrottlingRate", { rate: 4 });
  await page.addInitScript(() => {
    const metrics = { lcp: 0, cls: 0, inp: 0 };
    (window as unknown as { __ostVitals: typeof metrics }).__ostVitals =
      metrics;
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) metrics.lcp = entry.startTime;
    }).observe({ type: "largest-contentful-paint", buffered: true });
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries() as (PerformanceEntry & {
        hadRecentInput?: boolean;
      })[])
        if (!entry.hadRecentInput)
          metrics.cls += (entry as PerformanceEntry & { value: number }).value;
    }).observe({ type: "layout-shift", buffered: true });
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries() as (PerformanceEntry & {
        interactionId?: number;
      })[])
        if (entry.interactionId)
          metrics.inp = Math.max(metrics.inp, entry.duration);
    }).observe({
      type: "event",
      buffered: true,
      durationThreshold: 16,
    } as PerformanceObserverInit);
  });
}

async function recordMobileVitals(page: Page, origin: string, route: string) {
  await page.goto(`${origin}${route}`);
  if (route.endsWith("/submit"))
    await page.getByLabel("Anime or franchise").first().fill("Mobile measure");
  if (route.endsWith("/listen")) {
    await page.getByRole("button", { name: /Batch 1/ }).click();
    const rateEight = page
      .getByRole("radio", { name: /rating 8 of 10/ })
      .first();
    await expect(rateEight).toBeVisible();
    await rateEight.click();
    await expect(page.getByText("Saved on the server.")).toBeVisible();
  }
  await page.waitForTimeout(400);
  const values = await page.evaluate(
    () =>
      (
        window as unknown as {
          __ostVitals: { lcp: number; cls: number; inp: number };
        }
      ).__ostVitals,
  );
  process.stdout.write(
    `mobile-vitals ${route} ${JSON.stringify(values)} (375x812, 4x CPU, 150ms RTT, 1.6Mbps down / 750Kbps up)\n`,
  );
}

test("host bootstrap, invite passkey, recovery drill, and trial setup use virtual authenticators", async ({
  browser,
  baseURL,
}) => {
  const hostId = randomUUID();
  let participantId = "";
  const hostEmail = `host-${hostId}@host.invalid`;
  const token = randomBytes(32).toString("base64url");
  const trialId = { value: "" };
  const createdUsers: string[] = [];
  const uploadedMedia: string[] = [];
  let mediaFixtureDir = "";
  const hostContext = await browser.newContext();
  const hostPage = await hostContext.newPage();
  try {
    const origin = baseURL!;
    const { data, error } = await admin.auth.admin.createUser({
      id: hostId,
      email: hostEmail,
      email_confirm: true,
      app_metadata: {},
    });
    if (error || !data.user) throw error ?? new Error("Host fixture failed.");
    createdUsers.push(hostId);
    const tokenDigest = createHash("sha256").update(token).digest();
    sql(`
      delete from private.auth_rate_limits;
      insert into private.platform_config(singleton,host_user_id)
      values(true,'${hostId}');
      insert into private.host_bootstrap_tokens(token_digest,user_id,expires_at)
      values(decode('${tokenDigest.toString("hex")}','hex'),'${hostId}',now()+interval '10 minutes');
    `);

    await addVirtualAuthenticator(hostPage);
    await hostPage.goto(`${origin}/host/bootstrap#${token}`);
    await hostPage.getByRole("button", { name: "Create host passkey" }).click();
    await expect(hostPage).toHaveURL(/\/host\/security$/);
    await expect(hostPage.getByText("Host access is active.")).toBeVisible();

    const hostRoutes = [
      "/app",
      "/host/security",
      "/host/trials",
      "/host/submissions",
    ];
    for (const route of hostRoutes) {
      for (const colorScheme of ["light", "dark"] as const) {
        await hostPage.emulateMedia({ colorScheme });
        await hostPage.goto(`${origin}${route}`);
        await assertAxe(hostPage);
      }
    }
    await hostPage.goto(`${origin}/host/security`);

    await hostPage
      .getByRole("button", { name: "Generate new recovery codes" })
      .click();
    const firstCode = (
      await hostPage
        .locator(".recovery-code-list")
        .locator("li")
        .first()
        .innerText()
    ).trim();
    expect(firstCode).toMatch(/^[A-Za-z0-9_-]{22}$/);

    await hostPage.goto(`${baseURL}/host/trials`);
    await hostPage.getByRole("button", { name: "Create trial round" }).click();
    const controlsLink = hostPage.getByRole("link", { name: "Host controls" });
    await expect(controlsLink).toBeVisible();
    trialId.value = new URL(
      (await controlsLink.getAttribute("href"))!,
      origin,
    ).pathname
      .split("/")
      .at(-1)!;
    await controlsLink.click();
    await hostPage
      .getByRole("button", { name: "Open trial submissions" })
      .click();
    await expect(
      hostPage.getByRole("heading", { name: "submissions open" }),
    ).toBeVisible();
    for (const colorScheme of ["light", "dark"] as const) {
      await hostPage.emulateMedia({ colorScheme });
      await hostPage.goto(`${origin}/host/competitions/${trialId.value}`);
      await assertAxe(hostPage);
    }
    await hostPage.goto(`${baseURL}/host/trials`);
    await hostPage
      .getByRole("button", { name: "Create participant invite" })
      .click();
    const invite = await hostPage
      .locator(".invite-link-field input")
      .inputValue();
    expect(invite).toMatch(/\/invite#[A-Za-z0-9_-]{43}$/);
    const inviteToken = new URL(invite).hash.slice(1);

    const participantContext = await browser.newContext();
    const participantPage = await participantContext.newPage();
    try {
      await addVirtualAuthenticator(participantPage);
      await participantPage.goto(`${baseURL}/invite#${inviteToken}`);
      await participantPage.getByLabel("Nickname").fill("Browser Guest");
      await participantPage
        .getByRole("button", { name: "Create passkey and join" })
        .click();
      await expect(participantPage).toHaveURL(/\/app$/);
      await expect(
        participantPage.getByText("Trial round", { exact: false }),
      ).toBeVisible();
      participantId = sql(
        `select user_id from private.participants where competition_id='${trialId.value}' and nickname='Browser Guest'`,
      );
      if (!participantId)
        throw new Error(
          "Invite flow did not create the nickname-only participant account.",
        );
      createdUsers.push(participantId);
      for (const route of ["/app", `/competition/${trialId.value}/submit`]) {
        for (const colorScheme of ["light", "dark"] as const) {
          await participantPage.emulateMedia({ colorScheme });
          await participantPage.goto(`${origin}${route}`);
          await assertAxe(participantPage);
        }
      }
      await enableMobileVitals(participantPage);
      await recordMobileVitals(participantPage, origin, "/app");
      await recordMobileVitals(
        participantPage,
        origin,
        `/competition/${trialId.value}/submit`,
      );
      mediaFixtureDir = mkdtempSync(join(tmpdir(), "ost-chromium-media-"));
      const mediaPath = join(mediaFixtureDir, "fixture.m4a");
      execFileSync("ffmpeg", [
        "-hide_banner",
        "-loglevel",
        "error",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=880:duration=2",
        "-c:a",
        "aac",
        "-b:a",
        "256k",
        "-ar",
        "48000",
        "-ac",
        "2",
        mediaPath,
      ]);
      const audioBytes = readFileSync(mediaPath);
      const members = sql(
        `select id||':'||user_id from private.participants where competition_id='${trialId.value}' and user_id in ('${hostId}','${participantId}') order by user_id`,
      )
        .split("\n")
        .map((line) => line.split(":"));
      if (members.length !== 2)
        throw new Error("Expected host and invitee trial memberships.");
      const memberIds = new Map(members.map(([id, userId]) => [userId, id]));
      const submissionValues: string[] = [];
      for (const memberId of memberIds.values()) {
        for (const slot of [1, 2]) {
          const key = `${randomUUID().replaceAll("-", "")}/${randomUUID().replaceAll("-", "")}.m4a`;
          const stored = await admin.storage
            .from(process.env.SUPABASE_STORAGE_BUCKET!)
            .upload(key, audioBytes, {
              contentType: "audio/mp4",
              upsert: false,
            });
          if (stored.error) throw stored.error;
          uploadedMedia.push(key);
          submissionValues.push(
            `('${trialId.value}','${memberId}',${slot},'Browser fixture','Fixture track ${slot}','confirmed','${randomUUID().replaceAll("-", "")}/${randomUUID().replaceAll("-", "")}.mp4','${key}',${audioBytes.length},2,2,now())`,
          );
        }
      }
      sql(
        `insert into private.submissions(competition_id,participant_id,slot,franchise,ost_title,status,original_storage_key,audio_storage_key,original_bytes,original_seconds,audio_seconds,confirmed_at) values ${submissionValues.join(",")};`,
      );
      await hostPage.goto(`${origin}/host/competitions/${trialId.value}`);
      await hostPage
        .getByRole("button", { name: "Lock confirmed submissions" })
        .click();
      await hostPage
        .getByRole("button", { name: "Create batches and start listening" })
        .click();
      await hostPage.getByRole("button", { name: "Open batch 1" }).click();
      for (const colorScheme of ["light", "dark"] as const) {
        await participantPage.emulateMedia({ colorScheme });
        await participantPage.goto(
          `${origin}/competition/${trialId.value}/listen`,
        );
        await assertAxe(participantPage);
      }
      await recordMobileVitals(
        participantPage,
        origin,
        `/competition/${trialId.value}/listen`,
      );
    } finally {
      await participantContext.close();
    }

    await hostPage.goto(`${baseURL}/host/recover`);
    await hostPage.getByLabel("Recovery code").fill(firstCode);
    await hostPage.getByRole("button", { name: "Recover host access" }).click();
    await expect(hostPage).toHaveURL(/\/host\/security$/);
    await expect(hostPage.getByText("Host access is active.")).toBeVisible();
    expect(
      sql(
        `select count(*) from private.recovery_codes where user_id='${hostId}' and used_at is not null`,
      ),
    ).toBe("10");
    await hostPage.goto(`${baseURL}/host/competitions/${trialId.value}`);
    await expect(
      hostPage.getByRole("heading", { name: "Run this competition" }),
    ).toBeVisible();
    await admin.auth.admin.deleteUser(participantId).catch(() => undefined);
    createdUsers.splice(createdUsers.indexOf(participantId), 1);
  } finally {
    if (trialId.value) {
      sql(`
        alter table private.host_audit_log disable trigger host_audit_append_only;
        delete from private.host_audit_log where competition_id='${trialId.value}' or actor_user_id='${hostId}';
        delete from private.competitions where id='${trialId.value}';
        alter table private.host_audit_log enable trigger host_audit_append_only;
      `);
    }
    if (uploadedMedia.length)
      await admin.storage
        .from(process.env.SUPABASE_STORAGE_BUCKET!)
        .remove(uploadedMedia)
        .catch(() => undefined);
    if (mediaFixtureDir)
      rmSync(mediaFixtureDir, { recursive: true, force: true });
    sql(`delete from private.platform_config where host_user_id='${hostId}';`);
    for (const userId of createdUsers)
      await admin.auth.admin.deleteUser(userId).catch(() => undefined);
    await hostContext.close();
  }
});
