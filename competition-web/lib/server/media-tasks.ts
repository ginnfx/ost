import "server-only";
import { createSign } from "node:crypto";

type MediaTask = {
  uploadId: string;
  dispatchAttempt: number;
  sourceUrl: string;
  destinationUrl: string;
  audioKey: string;
  normalize: boolean;
  minClipSeconds: number;
  maxClipSeconds: number;
  maxUploadBytes: number;
  callbackUrl: string;
};

export async function dispatchMediaTask(task: MediaTask): Promise<void> {
  const mode = process.env.MEDIA_TASK_MODE ?? "cloud-tasks";
  if (mode === "local") {
    const endpoint = `${required("MEDIA_WORKER_URL").replace(/\/$/, "")}/process`;
    void (async () => {
      for (
        let attempt = 0;
        attempt < Number(process.env.MEDIA_TASK_MAX_ATTEMPTS ?? 5);
        attempt += 1
      ) {
        try {
          const response = await fetch(endpoint, {
            method: "POST",
            headers: {
              "content-type": "application/json",
              authorization: `Bearer ${required("MEDIA_WORKER_LOCAL_TOKEN")}`,
              "x-cloudtasks-taskretrycount": String(attempt),
            },
            body: JSON.stringify(task),
            cache: "no-store",
          });
          if (response.ok || response.status < 500) return;
        } catch {
          if (attempt + 1 === Number(process.env.MEDIA_TASK_MAX_ATTEMPTS ?? 5))
            return;
        }
        await new Promise((resolve) =>
          setTimeout(resolve, Math.min(100 * 2 ** attempt, 2_000)),
        );
      }
    })();
    return;
  }

  const project = required("GCP_PROJECT_ID");
  const region = required("GCP_REGION");
  const queue = required("GCP_TASKS_QUEUE");
  const serviceAccount = required("GCP_TASKS_INVOKER_SERVICE_ACCOUNT");
  const workerUrl = required("MEDIA_WORKER_URL").replace(/\/$/, "");
  const accessToken = await googleAccessToken();
  const parent = `projects/${project}/locations/${region}/queues/${queue}`;
  const response = await fetch(
    `https://cloudtasks.googleapis.com/v2/${parent}/tasks`,
    {
      method: "POST",
      headers: {
        authorization: `Bearer ${accessToken}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        task: {
          name: `${parent}/tasks/${task.uploadId.replaceAll("-", "")}-${task.dispatchAttempt}`,
          dispatchDeadline: "1800s",
          httpRequest: {
            httpMethod: "POST",
            url: `${workerUrl}/process`,
            headers: { "content-type": "application/json" },
            body: Buffer.from(JSON.stringify(task)).toString("base64"),
            oidcToken: {
              serviceAccountEmail: serviceAccount,
              audience: workerUrl,
            },
          },
        },
      }),
      cache: "no-store",
      signal: AbortSignal.timeout(10_000),
    },
  );
  if (!response.ok && response.status !== 409)
    throw new Error("Media task could not be queued.");
}

async function googleAccessToken(): Promise<string> {
  const email = required("GCP_TASKS_CLIENT_EMAIL");
  const privateKey = required("GCP_TASKS_CLIENT_PRIVATE_KEY").replace(
    /\\n/g,
    "\n",
  );
  const now = Math.floor(Date.now() / 1000);
  const encode = (value: unknown) =>
    Buffer.from(JSON.stringify(value)).toString("base64url");
  const unsigned = `${encode({ alg: "RS256", typ: "JWT" })}.${encode({
    iss: email,
    scope: "https://www.googleapis.com/auth/cloud-platform",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 300,
  })}`;
  const signer = createSign("RSA-SHA256");
  signer.update(unsigned);
  const assertion = `${unsigned}.${signer.sign(privateKey, "base64url")}`;
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
    cache: "no-store",
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) throw new Error("Media task could not be queued.");
  const token = (await response.json()) as { access_token?: string };
  if (!token.access_token) throw new Error("Media task could not be queued.");
  return token.access_token;
}

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error("Media task configuration is missing.");
  return value;
}
