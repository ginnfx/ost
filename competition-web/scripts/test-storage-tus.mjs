import { createHmac, randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import nextEnv from "@next/env";
import { createClient } from "@supabase/supabase-js";
import { Upload } from "tus-js-client";

nextEnv.loadEnvConfig(process.cwd());

for (const name of [
  "SUPABASE_URL",
  "SUPABASE_SERVICE_ROLE_KEY",
  "SUPABASE_STORAGE_BUCKET",
]) {
  if (!process.env[name]) throw new Error(`${name} is required for this local test.`);
}

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY,
  { auth: { persistSession: false, autoRefreshToken: false } },
);
const bucket = process.env.SUPABASE_STORAGE_BUCKET;
const id = randomUUID();
const userId = randomUUID();
const email = `tus-${id}@example.invalid`;
const key = `${id.replaceAll("-", "")}/${randomUUID().replaceAll("-", "")}.mp4`;
const databaseContainer =
  process.env.LOCAL_SUPABASE_DB_CONTAINER ?? "supabase_db_ost-competition-private";
let createdUser = false;
let createdObject = false;

function sql(statement) {
  execFileSync(
    "docker",
    [
      "exec",
      "-i",
      databaseContainer,
      "psql",
      "-U",
      "supabase_admin",
      "-d",
      "postgres",
      "-v",
      "ON_ERROR_STOP=1",
      "-c",
      statement,
    ],
    { stdio: "ignore" },
  );
}

try {
  const created = await supabase.auth.admin.createUser({
    id: userId,
    email,
    email_confirm: true,
  });
  if (created.error) throw created.error;
  createdUser = true;

  sql(`
    insert into private.competitions(id,name,status,settings)
    values ('${id}','Local TUS probe','submissions_open',
      '{"entries_per_participant":5,"batch_count":1,"reveal_group_count":1,"min_clip_seconds":1,"max_clip_seconds":360,"max_upload_bytes":524288000,"loudness_normalization":false}');
    insert into private.participants(competition_id,user_id,nickname)
    values ('${id}','${userId}','TUS probe');
    insert into private.submission_uploads(
      competition_id,participant_id,slot,franchise,ost_title,original_storage_key,original_bytes,claimed_seconds
    ) values (
      '${id}',(select id from private.participants where competition_id='${id}'),1,
      'Probe','Storage check','${key}',41,2
    );
  `);

  const signed = await supabase.storage.from(bucket).createSignedUploadUrl(key, {
    upsert: false,
  });
  if (signed.error || !signed.data)
    throw signed.error ?? new Error("Could not issue the local upload token.");

  const containerEnv = execFileSync(
    "docker",
    [
      "inspect",
      "supabase_storage_ost-competition-private",
      "--format",
      "{{range .Config.Env}}{{println .}}{{end}}",
    ],
    { encoding: "utf8" },
  );
  // This test-only JWT is minted from the local Storage container's key so
  // the disposable participant can exercise the exact authenticated RLS rule.
  const jwtSecret = containerEnv
    .split("\n")
    .find((line) => line.startsWith("AUTH_JWT_SECRET="))
    ?.slice("AUTH_JWT_SECRET=".length);
  if (!jwtSecret) throw new Error("The local Supabase JWT secret is unavailable.");
  const issuedAt = Math.floor(Date.now() / 1000);
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
  const unsignedToken = `${encode({ alg: "HS256", typ: "JWT" })}.${encode({
    aud: "authenticated",
    role: "authenticated",
    sub: userId,
    email,
    app_metadata: { provider: "email", providers: ["email"] },
    user_metadata: {},
    is_anonymous: false,
    aal: "aal1",
    session_id: randomUUID(),
    amr: [{ method: "password", timestamp: issuedAt }],
    iat: issuedAt,
    exp: issuedAt + 600,
  })}`;
  const accessToken = `${unsignedToken}.${createHmac("sha256", jwtSecret)
    .update(unsignedToken)
    .digest("base64url")}`;

  const body = Buffer.from("local signed resumable upload integration probe");
  await new Promise((resolve, reject) => {
    new Upload(body, {
      endpoint: `${process.env.SUPABASE_URL}/storage/v1/upload/resumable`,
      headers: {
        authorization: `Bearer ${accessToken}`,
        "x-signature": signed.data.token,
        "x-upsert": "false",
      },
      metadata: {
        bucketName: bucket,
        objectName: key,
        contentType: "video/mp4",
        cacheControl: "0",
      },
      chunkSize: 6 * 1024 * 1024,
      onError: reject,
      onSuccess: resolve,
    }).start();
  });
  createdObject = true;

  const downloaded = await supabase.storage.from(bucket).download(key);
  if (
    downloaded.error ||
    !downloaded.data ||
    (await downloaded.data.text()) !== body.toString()
  )
    throw downloaded.error ?? new Error("Uploaded bytes did not match.");
  console.log("Local participant-scoped signed TUS upload and private read passed.");
} finally {
  if (createdObject) await supabase.storage.from(bucket).remove([key]);
  sql(`delete from private.competitions where id='${id}'`);
  if (createdUser) await supabase.auth.admin.deleteUser(userId);
}
