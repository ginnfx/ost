import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { execFileSync, spawn } from "node:child_process";
import { readFile, rm } from "node:fs/promises";
import { setTimeout as delay } from "node:timers/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import nextEnv from "@next/env";
import { createClient } from "@supabase/supabase-js";
import { Upload } from "tus-js-client";

nextEnv.loadEnvConfig(process.cwd());
for (const name of ["SUPABASE_URL", "SUPABASE_ANON_KEY", "SUPABASE_SERVICE_ROLE_KEY", "SUPABASE_STORAGE_BUCKET", "SUPABASE_DB_URL"]) {
  if (!process.env[name]) throw new Error(`${name} is required for media orchestration integration.`);
}

const id = randomUUID();
const userId = randomUUID();
const competitionId = randomUUID();
const password = `Local-media-${randomUUID()}-!`;
const email = `media-${id}@example.invalid`;
const origin = "http://127.0.0.1:3210";
const bucket = process.env.SUPABASE_STORAGE_BUCKET;
const dbContainer = process.env.LOCAL_SUPABASE_DB_CONTAINER ?? "supabase_db_ost-competition-private";
const secret = randomUUID() + randomUUID();
const localToken = randomUUID() + randomUUID();
const root = join(tmpdir(), `ost-media-orchestration-${id}`);
const sourceKey = () => `${randomUUID().replaceAll("-", "")}/${randomUUID().replaceAll("-", "")}.mp4`;
const objects = [];
const servers = [];
const admin = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});
let userCreated = false;

function sql(statement) {
  return execFileSync("docker", ["exec", "-i", dbContainer, "psql", "-U", "supabase_admin", "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-qAt", "-c", statement], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
}
function start(command, args, env) {
  const child = spawn(command, args, { cwd: process.cwd(), env: { ...process.env, ...env }, stdio: "inherit" });
  servers.push(child);
  return child;
}
async function waitHttp(url, timeout = 90_000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    try {
      const response = await fetch(url, { cache: "no-store" });
      if (response.ok) return;
    } catch {}
    await delay(400);
  }
  throw new Error(`Timed out waiting for ${new URL(url).hostname}:${new URL(url).port}.`);
}
async function signedInSession() {
  const created = await admin.auth.admin.createUser({ id: userId, email, password, email_confirm: true });
  if (created.error) throw created.error;
  userCreated = true;
  const anon = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  let result = await anon.auth.signInWithPassword({ email, password });
  if (result.error) {
    const link = await admin.auth.admin.generateLink({ type: "magiclink", email });
    const tokenHash = link.data.properties?.hashed_token;
    if (link.error || !tokenHash) throw link.error ?? result.error;
    result = await anon.auth.verifyOtp({ token_hash: tokenHash, type: "magiclink" });
  }
  if (result.error || !result.data.session) throw result.error ?? new Error("No local test session.");
  return result.data.session.access_token;
}
async function uploadTus(key, accessToken, signature, bytes) {
  return new Promise((resolve, reject) => {
    new Upload(bytes, {
      endpoint: `${process.env.SUPABASE_URL}/storage/v1/upload/resumable`,
      headers: { authorization: `Bearer ${accessToken}`, "x-signature": signature, "x-upsert": "false" },
      metadata: { bucketName: bucket, objectName: key, contentType: "video/mp4", cacheControl: "0" },
      chunkSize: 6 * 1024 * 1024,
      retryDelays: [0, 1000],
      onError: reject,
      onSuccess: resolve,
    }).start();
  });
}
async function makeClip(file, silent) {
  const args = silent
    ? ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=black:s=64x64:d=21", "-an", "-c:v", "mpeg4", "-y", file]
    : ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=21", "-c:a", "aac", "-b:a", "128k", "-y", file];
  execFileSync("ffmpeg", args, { stdio: "ignore" });
  return readFile(file);
}
async function startUpload(slot, bytes, accessToken) {
  const key = sourceKey(slot);
  objects.push(key);
  sql(`insert into private.submission_uploads(competition_id,participant_id,slot,franchise,ost_title,original_storage_key,original_bytes,claimed_seconds)
       values('${competitionId}',(select id from private.participants where competition_id='${competitionId}' and user_id='${userId}'),${slot},'Orchestration Test','Clip ${slot}','${key}',${bytes.length},21);`);
  const signed = await admin.storage.from(bucket).createSignedUploadUrl(key, { upsert: false });
  if (signed.error || !signed.data) throw signed.error ?? new Error("Could not sign upload.");
  await uploadTus(key, accessToken, signed.data.token, bytes);
  return { key };
}

try {
  await (await import("node:fs/promises")).mkdir(root, { recursive: true });
  const accessToken = await signedInSession();
  sql(`insert into private.platform_config(singleton,host_user_id) values(true,'${userId}');
       insert into private.competitions(id,name,status,settings) values('${competitionId}','Local worker orchestration','submissions_open',
       '{"entries_per_participant":5,"batch_count":1,"reveal_group_count":1,"min_clip_seconds":20,"max_clip_seconds":360,"max_upload_bytes":524288000,"loudness_normalization":false}');
       insert into private.participants(competition_id,user_id,nickname) values('${competitionId}','${userId}','Worker Test Host');`);

  start("python3", ["worker/server.py"], {
    PORT: "3220", NODE_ENV: "development", MEDIA_WORKER_LOCAL_TOKEN: localToken,
    MEDIA_WORKER_CALLBACK_SECRET: secret, MEDIA_WORKER_TIMEOUT_SECONDS: "180",
    MEDIA_ALLOWED_STORAGE_ORIGIN: new URL(process.env.SUPABASE_URL).origin,
    MEDIA_CALLBACK_ORIGIN: origin,
  });
  await waitHttp("http://127.0.0.1:3220/healthz");
  start(process.execPath, ["node_modules/next/dist/bin/next", "start", "--hostname", "127.0.0.1", "--port", "3210"], {
    NEXT_PUBLIC_SITE_URL: origin, NEXT_PUBLIC_SITE_ORIGINS: origin,
    MEDIA_TASK_MODE: "local", MEDIA_WORKER_URL: "http://127.0.0.1:3220",
    MEDIA_WORKER_LOCAL_TOKEN: localToken, MEDIA_WORKER_CALLBACK_SECRET: secret,
    MEDIA_TASK_MAX_ATTEMPTS: "5",
    NODE_ENV: "production",
  });
  await waitHttp(`${origin}/login`);

  const normalFile = join(root, "normal.mp4");
  const normalBytes = await makeClip(normalFile, false);
  const normal = await startUpload(1, normalBytes, accessToken);
  const uploadId = sql(`select id from private.submission_uploads where competition_id='${competitionId}' and slot=1`);
  const membership = await fetch(`${origin}/api/competitions`, { headers: { authorization: `Bearer ${accessToken}` }, cache: "no-store" });
  assert.equal(membership.status, 200, "Authenticated participant membership API failed.");
  const begin = await fetch(`${origin}/api/submission-uploads/${uploadId}/process`, {
    method: "POST", headers: { authorization: `Bearer ${accessToken}`, origin, "content-type": "application/json" }, body: "{}", cache: "no-store",
  });
  assert.equal(begin.status, 202, `Upload completion was not dispatched: ${begin.status} ${await begin.text()}`);
  let status = "processing";
  for (let i = 0; i < 90 && status === "processing"; i += 1) {
    await delay(500);
    const response = await fetch(`${origin}/api/submission-uploads/${uploadId}`, { headers: { authorization: `Bearer ${accessToken}` }, cache: "no-store" });
    assert.equal(response.status, 200, "Participant could not poll processing status.");
    status = (await response.json()).status;
  }
  assert.equal(status, "awaiting_confirmation", `Completed TUS upload did not become playable (${status}).`);
  const media = sql(`select original_storage_key || '|' || audio_storage_key || '|' || status from private.submissions where competition_id='${competitionId}' and slot=1`);
  const [originalKey, audioKey, submissionStatus] = media.split("|");
  assert.equal(submissionStatus, "awaiting_confirmation");
  assert.equal(originalKey, normal.key);
  objects.push(audioKey);
  const audio = await admin.storage.from(bucket).download(audioKey);
  if (audio.error || !audio.data) throw audio.error ?? new Error("Transcoded audio is unavailable in private Storage.");
  const audioPath = join(root, "playable.m4a");
  await (await import("node:fs/promises")).writeFile(audioPath, Buffer.from(await audio.data.arrayBuffer()));
  const probe = JSON.parse(execFileSync("ffprobe", ["-v", "error", "-show_entries", "stream=codec_name,sample_rate,channels", "-of", "json", audioPath], { encoding: "utf8" }));
  assert.equal(probe.streams[0].codec_name, "aac");
  assert.equal(probe.streams[0].sample_rate, "48000");
  assert.equal(probe.streams[0].channels, 2);
  execFileSync("ffmpeg", ["-hide_banner", "-v", "error", "-i", audioPath, "-f", "null", "-"], { stdio: "ignore" });

  const silentBytes = await makeClip(join(root, "silent.mp4"), true);
  await startUpload(2, silentBytes, accessToken);
  const silentUploadId = sql(`select id from private.submission_uploads where competition_id='${competitionId}' and slot=2`);
  const failedDispatch = await fetch(`${origin}/api/submission-uploads/${silentUploadId}/process`, {
    method: "POST", headers: { authorization: `Bearer ${accessToken}`, origin, "content-type": "application/json" }, body: "{}", cache: "no-store",
  });
  assert.equal(failedDispatch.status, 202);
  let failedStatus = "processing";
  for (let i = 0; i < 60 && failedStatus === "processing"; i += 1) {
    await delay(500);
    const response = await fetch(`${origin}/api/submission-uploads/${silentUploadId}`, { headers: { authorization: `Bearer ${accessToken}` }, cache: "no-store" });
    failedStatus = (await response.json()).status;
  }
  assert.equal(failedStatus, "failed", `Silent upload should fail processing, got ${failedStatus}.`);
  const hostReviews = await fetch(`${origin}/api/host/submission-reviews`, { headers: { authorization: `Bearer ${accessToken}` }, cache: "no-store" });
  assert.equal(hostReviews.status, 200);
  const reviewData = await hostReviews.json();
  assert(reviewData.failures.some((failure) => failure.uploadId === silentUploadId && failure.errorCode === "audio_stream_missing"), "Host console did not receive permanent processing failure.");
  console.log("Media orchestration integration: completed TUS upload → local task endpoint → signed Storage transcode → playable AAC, plus host-visible validation failure, passed.");
} finally {
  for (const child of servers) child.kill("SIGTERM");
  if (objects.length) await admin.storage.from(bucket).remove(objects).catch(() => undefined);
  try {
    sql(`delete from private.competitions where id='${competitionId}'; delete from private.platform_config where host_user_id='${userId}';`);
  } catch {}
  if (userCreated) await admin.auth.admin.deleteUser(userId).catch(() => undefined);
  await rm(root, { recursive: true, force: true });
}
