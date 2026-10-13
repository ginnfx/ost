import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
} from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";

const root = resolve(import.meta.dirname, "..");
const temporaryEnv = mkdtempSync(join(tmpdir(), "ost-demo-env-"));
const hiddenEnvFiles = [];
const cleanEnv = {
  PATH: process.env.PATH ?? "/usr/bin:/bin",
  HOME: process.env.HOME ?? "/tmp",
  DEMO_ONLY: "true",
  CI: "1",
};

function run(command, args, options = {}) {
  execFileSync(command, args, {
    cwd: root,
    env: cleanEnv,
    stdio: "inherit",
    ...options,
  });
}

async function capture(command, args, options = {}) {
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      const output = execFileSync(command, args, {
        cwd: root,
        env: cleanEnv,
        encoding: "utf8",
        ...options,
      });
      process.stdout.write(output);
      return output;
    } catch (error) {
      if (attempt === 3) throw error;
      process.stderr.write(
        `Vercel deploy attempt ${attempt} failed; retrying shortly.\n`,
      );
      await new Promise((resolve) => setTimeout(resolve, attempt * 4000));
    }
  }
  throw new Error("Vercel deploy did not complete.");
}

async function captureAsVercelCliUser(command, args) {
  let repositoryRoot;
  try {
    repositoryRoot = execFileSync("git", ["rev-parse", "--show-toplevel"], {
      cwd: root,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return capture(command, args);
  }
  const gitDirectory = join(repositoryRoot, ".git");
  const hiddenGitDirectory = join(root, ".vercel", "git-metadata-disabled");
  if (!existsSync(gitDirectory)) return capture(command, args);
  if (existsSync(hiddenGitDirectory))
    throw new Error("A prior temporary Git metadata move was not restored.");
  renameSync(gitDirectory, hiddenGitDirectory);
  try {
    return await capture(command, args);
  } finally {
    if (existsSync(hiddenGitDirectory))
      renameSync(hiddenGitDirectory, gitDirectory);
  }
}

function hideLocalEnvFiles() {
  for (const name of readdirSync(root)) {
    if (!/^\.env(?:\..+)?$/.test(name) || name.startsWith(".env.example"))
      continue;
    const source = join(root, name);
    if (!statSync(source).isFile()) continue;
    const hidden = join(temporaryEnv, name);
    renameSync(source, hidden);
    hiddenEnvFiles.push([hidden, source]);
  }
}

function restoreLocalEnvFiles() {
  for (const [hidden, source] of hiddenEnvFiles.reverse())
    if (existsSync(hidden)) renameSync(hidden, source);
  rmSync(temporaryEnv, { recursive: true, force: true });
}

function scanBuildOutput() {
  const roots = [join(root, ".next", "server"), join(root, ".next", "static")];
  const findings = [];
  const patterns = [
    ["Supabase project URL", /https?:\/\/[a-z0-9-]+\.supabase\.co\b/i],
    [
      "Supabase secret/publishable key",
      /\bsb_(?:secret|publishable)_[A-Za-z0-9_-]{12,}/,
    ],
    [
      "JWT-like credential",
      /\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/,
    ],
  ];
  const visit = (directory) => {
    for (const name of readdirSync(directory, { withFileTypes: true })) {
      const path = join(directory, name.name);
      if (name.isDirectory()) visit(path);
      else if (name.isFile() && !name.name.endsWith(".map")) {
        const content = readFileSync(path);
        for (const [label, pattern] of patterns)
          if (pattern.test(content.toString("utf8")))
            findings.push(`${label}: ${path.slice(root.length + 1)}`);
      }
    }
  };
  if (roots.some((directory) => !existsSync(directory)))
    throw new Error("Production build output is missing.");
  for (const directory of roots) visit(directory);
  if (findings.length) {
    process.stderr.write(`Build secret scan failed:\n${findings.join("\n")}\n`);
    process.exitCode = 1;
    throw new Error("Remove deployment secrets from the production bundle.");
  }
  process.stdout.write(
    "Production bundle scan passed: no Supabase URL or credential patterns found.\n",
  );
}

async function verifyLiveDemo(origin) {
  const rootResponse = await fetch(origin, { redirect: "follow" });
  if (rootResponse.status !== 200)
    throw new Error(`Public root returned HTTP ${rootResponse.status}.`);
  const html = await rootResponse.text();
  if (!html.includes("OST Competition demo"))
    throw new Error("The public demo title was not found.");
  if (!(rootResponse.headers.get("x-robots-tag") ?? "").includes("noindex"))
    throw new Error("The public response is missing its noindex directive.");
  if (
    /supabase\.co/i.test(
      rootResponse.headers.get("content-security-policy") ?? "",
    )
  )
    throw new Error("The demo CSP unexpectedly includes a Supabase origin.");
  for (const header of [
    "x-robots-tag",
    "content-security-policy",
    "x-content-type-options",
    "referrer-policy",
    "permissions-policy",
    "strict-transport-security",
  ])
    if (!rootResponse.headers.get(header))
      throw new Error(`Public demo is missing ${header}.`);

  const robots = await fetch(new URL("/robots.txt", origin));
  if (robots.status !== 200 || !(await robots.text()).includes("Disallow: /"))
    throw new Error("The public robots.txt does not disallow crawling.");

  for (const path of ["/login", "/app", "/host"]) {
    const response = await fetch(new URL(path, origin));
    if (
      response.status !== 404 ||
      !(await response.text()).includes("Not set up yet")
    )
      throw new Error(`${path} was not blocked by the demo-only guard.`);
  }
  process.stdout.write(
    `Live public checks passed: ${origin} (HTTP 200, privacy headers, robots, blocked routes).\n`,
  );
}

try {
  hideLocalEnvFiles();
  run("npm", ["run", "format"]);
  run("npm", ["run", "format:check"]);
  run("npm", ["run", "typecheck"]);
  run("npm", ["run", "lint"]);
  run("npm", ["test"]);
  run("npm", ["run", "test:e2e:demo-only"]);
  rmSync(join(root, ".next"), { recursive: true, force: true });
  run("npm", ["run", "build"]);
  scanBuildOutput();

  if (process.argv.includes("--check-only")) {
    process.stdout.write("Demo-only checks completed; deployment skipped.\n");
  } else {
    run("npx", [
      "vercel",
      "project",
      "update",
      "ost-comp-demo",
      "--framework",
      "nextjs",
      "--yes",
    ]);
    run("npx", [
      "vercel",
      "project",
      "protection",
      "disable",
      "ost-comp-demo",
      "--sso",
    ]);
    process.stdout.write("Setting DEMO_ONLY=true for Vercel production.\n");
    run("npx", [
      "vercel",
      "env",
      "add",
      "DEMO_ONLY",
      "production",
      "--value",
      "true",
      "--force",
      "--yes",
    ]);
    process.stdout.write("Deploying the public demo to Vercel production.\n");
    await captureAsVercelCliUser("npx", [
      "vercel",
      "deploy",
      "--prod",
      "--yes",
    ]);
    const productionUrl = "https://ost-comp-demo.vercel.app";
    await verifyLiveDemo(productionUrl);
    run("npm", ["run", "test:e2e:demo-only"], {
      env: { ...cleanEnv, DEMO_BASE_URL: productionUrl },
    });
  }
} finally {
  restoreLocalEnvFiles();
}
