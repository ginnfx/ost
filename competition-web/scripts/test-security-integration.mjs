import { randomUUID } from "node:crypto";
import { execFileSync, spawn } from "node:child_process";
import { setTimeout as delay } from "node:timers/promises";
import nextEnv from "@next/env";
import { createServerClient } from "@supabase/ssr";
import { createClient } from "@supabase/supabase-js";

nextEnv.loadEnvConfig(process.cwd());
const required = [
  "SUPABASE_URL",
  "SUPABASE_ANON_KEY",
  "SUPABASE_SERVICE_ROLE_KEY",
  "SUPABASE_STORAGE_BUCKET",
];
for (const name of required)
  if (!process.env[name])
    throw new Error(`${name} is required for local security integration.`);

const id = randomUUID();
const hostId = randomUUID();
const participantA = randomUUID();
const participantB = randomUUID();
const competitionId = randomUUID();
const legacySourceId = randomUUID();
const participantARecord = randomUUID();
const participantBRecord = randomUUID();
const hostParticipantRecord = randomUUID();
const submissionA = randomUUID();
const submissionB = randomUUID();
const labelA = randomUUID();
const labelB = randomUUID();
const listeningA = randomUUID();
const listeningB = randomUUID();
const batch1 = randomUUID();
const batch2 = randomUUID();
const keyA = `${randomUUID().replaceAll("-", "")}/${randomUUID().replaceAll("-", "")}.m4a`;
const keyB = `${randomUUID().replaceAll("-", "")}/${randomUUID().replaceAll("-", "")}.m4a`;
const originalKeyA = `${randomUUID().replaceAll("-", "")}/${randomUUID().replaceAll("-", "")}.mp4`;
const originalKeyB = `${randomUUID().replaceAll("-", "")}/${randomUUID().replaceAll("-", "")}.mp4`;
const email = (name) => `${name}-${id}@example.invalid`;
const password = `Local-test-${randomUUID()}-!`;
const siteOrigin = "http://127.0.0.1:3210";
const bucket = process.env.SUPABASE_STORAGE_BUCKET;
const admin = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY,
  {
    auth: { persistSession: false, autoRefreshToken: false },
  },
);
const dbContainer =
  process.env.LOCAL_SUPABASE_DB_CONTAINER ??
  "supabase_db_ost-competition-private";
const server = spawn(
  process.execPath,
  [
    "node_modules/next/dist/bin/next",
    "start",
    "--hostname",
    "127.0.0.1",
    "--port",
    "3210",
  ],
  {
    cwd: process.cwd(),
    env: {
      ...process.env,
      NEXT_PUBLIC_SITE_URL: siteOrigin,
      NEXT_PUBLIC_SITE_ORIGINS: siteOrigin,
      NODE_ENV: "production",
    },
    stdio: "inherit",
  },
);
let seeded = false;
const uploaded = [];
const users = [];

function sql(statement) {
  return execFileSync(
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
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

async function createSignedInUser(userId, userEmail, nickname) {
  const created = await admin.auth.admin.createUser({
    id: userId,
    email: userEmail,
    password,
    email_confirm: true,
    user_metadata: { nickname, host: true },
  });
  if (created.error) throw created.error;
  users.push(userId);
  const anonymous = createClient(
    process.env.SUPABASE_URL,
    process.env.SUPABASE_ANON_KEY,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
  let sessionResult = await anonymous.auth.signInWithPassword({
    email: userEmail,
    password,
  });
  if (sessionResult.error) {
    // The private app disables password/email login. Use an admin-issued, local-only
    // one-use magic link to create a legitimate Auth session for the HTTP probes.
    const link = await admin.auth.admin.generateLink({
      type: "magiclink",
      email: userEmail,
    });
    const tokenHash = link.data.properties?.hashed_token;
    if (link.error || !tokenHash) throw link.error ?? sessionResult.error;
    sessionResult = await anonymous.auth.verifyOtp({
      token_hash: tokenHash,
      type: "magiclink",
    });
  }
  if (sessionResult.error || !sessionResult.data.session)
    throw (
      sessionResult.error ??
      new Error("Local test sign-in returned no session.")
    );
  const jar = new Map();
  const cookieClient = createServerClient(
    process.env.SUPABASE_URL,
    process.env.SUPABASE_ANON_KEY,
    {
      cookies: {
        getAll: () => [...jar].map(([name, value]) => ({ name, value })),
        setAll: (items) => {
          for (const item of items) jar.set(item.name, item.value);
        },
      },
    },
  );
  const result = await cookieClient.auth.setSession(sessionResult.data.session);
  if (result.error) throw result.error;
  const cookie = [...jar].map(([name, value]) => `${name}=${value}`).join("; ");
  assert(cookie.length > 20, "Could not create a local SSR auth cookie.");
  return {
    cookie,
    storage: anonymous,
    accessToken: sessionResult.data.session.access_token,
    cookieNames: [...jar.keys()],
  };
}

async function waitForServer() {
  for (let attempt = 0; attempt < 90; attempt += 1) {
    if (server.exitCode !== null)
      throw new Error(
        "Next production server exited before the security probes ran.",
      );
    try {
      const response = await fetch(`${siteOrigin}/login`);
      if (response.ok) return;
    } catch {}
    await delay(500);
  }
  throw new Error("Next production server did not become ready.");
}

async function request(path, { cookie, bearer, method = "GET", body, includeOrigin = true } = {}) {
  return fetch(`${siteOrigin}${path}`, {
    method,
    headers: {
      ...(cookie ? { cookie } : {}),
      ...(bearer ? { authorization: `Bearer ${bearer}` } : {}),
      ...(body === undefined
        ? {}
        : { "content-type": "application/json", ...(includeOrigin ? { origin: siteOrigin } : {}) }),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    redirect: "manual",
  });
}

try {
  const identities = await Promise.all([
    createSignedInUser(hostId, email("host"), "Local Host"),
    createSignedInUser(participantA, email("a"), "Participant A Secret"),
    createSignedInUser(participantB, email("b"), "Participant B Only"),
  ]);
  const b = identities[2];

  seeded = true;
  sql(`
    begin;
    insert into private.platform_config(singleton,host_user_id) values(true,'${hostId}');
    insert into private.competitions(id,name,status,settings)
      values ('${competitionId}','Local security probe','listening',
      '{"entries_per_participant":2,"batch_count":2,"reveal_group_count":1,"min_clip_seconds":20,"max_clip_seconds":360,"max_upload_bytes":524288000,"loudness_normalization":false}');
    insert into private.participants(id,competition_id,user_id,nickname) values
      ('${participantARecord}','${competitionId}','${participantA}','Participant A Secret'),
      ('${participantBRecord}','${competitionId}','${participantB}','Participant B Only'),
      ('${hostParticipantRecord}','${competitionId}','${hostId}','Local Host');
    insert into private.submissions(id,competition_id,participant_id,slot,franchise,ost_title,status,original_storage_key,audio_storage_key,original_bytes,original_seconds,audio_seconds,confirmed_at) values
      ('${submissionA}','${competitionId}','${participantARecord}',1,'Secret Franchise A','Secret OST Title A','confirmed','${originalKeyA}','${keyA}',100,30,30,now()),
      ('${submissionB}','${competitionId}','${participantBRecord}',1,'Secret Franchise B','Secret OST Title B','confirmed','${originalKeyB}','${keyB}',100,30,30,now());
    insert into private.listening_labels(id,competition_id,submission_id,listening_id,label_number,label) values
      ('${labelA}','${competitionId}','${submissionA}','${listeningA}',1,'Mystery OST #1'),
      ('${labelB}','${competitionId}','${submissionB}','${listeningB}',2,'Mystery OST #2');
    insert into private.batches(id,competition_id,batch_number,status,released_at) values
      ('${batch1}','${competitionId}',1,'released',now()),('${batch2}','${competitionId}',2,'scheduled',null);
    insert into private.batch_entries(batch_id,listening_id,display_order_seed) values
      ('${batch1}','${listeningA}',1),('${batch1}','${listeningB}',2),('${batch2}','${listeningA}',1);
    insert into private.participant_batch_entries(participant_id,batch_id,listening_id,display_order) values
      ('${participantARecord}','${batch1}','${listeningA}',1),('${participantARecord}','${batch1}','${listeningB}',2),
      ('${participantBRecord}','${batch1}','${listeningA}',1),('${participantBRecord}','${batch1}','${listeningB}',2),
      ('${participantARecord}','${batch2}','${listeningA}',1),('${participantBRecord}','${batch2}','${listeningA}',1);
    insert into private.ratings(participant_id,submission_id,batch_id,score) values
      ('${participantARecord}','${submissionA}','${batch1}',10),('${participantARecord}','${submissionB}','${batch1}',3),
      ('${participantBRecord}','${submissionB}','${batch1}',10);
    insert into private.reveal_groups(competition_id,group_number) values('${competitionId}',1);
    insert into private.score_snapshots(competition_id,algorithm_version,seed,payload) values
      ('${competitionId}',1,decode(repeat('ab',32),'hex'),
       '{"ranked":[{"id":"${submissionA}","rank":1,"mean":"5","count":2},{"id":"${submissionB}","rank":2,"mean":"6.5","count":2}],"revealGroups":[{"number":1,"entryIds":["${submissionA}","${submissionB}"]}]}');
    commit;
  `);

  for (const [key, contentType] of [
    [keyA, "audio/mp4"],
    [keyB, "audio/mp4"],
    [originalKeyA, "video/mp4"],
    [originalKeyB, "video/mp4"],
  ]) {
    const result = await admin.storage
      .from(bucket)
      .upload(
        key,
        new Blob([`local security fixture ${key}`], { type: contentType }),
        { contentType, upsert: false },
      );
    if (result.error) throw result.error;
    uploaded.push(key);
  }

  sql(`begin; set local role ost_web_app;
    select set_config('request.jwt.claim.sub','${participantB}',true);
    select set_config('request.jwt.claims','{"sub":"${participantB}","role":"authenticated"}',true);
    select private.create_native_authorization_code(decode(repeat('cd',32),'hex'),now()+interval '1 minute');
    select * from private.my_competition_memberships();
    rollback;`);

  await waitForServer();
  const authCheck = await fetch(`${process.env.SUPABASE_URL}/auth/v1/user`, {
    headers: {
      apikey: process.env.SUPABASE_ANON_KEY,
      authorization: `Bearer ${b.accessToken}`,
    },
  });
  assert(
    authCheck.ok,
    `Auth test session is invalid (HTTP ${authCheck.status}).`,
  );
  const nativeApiMemberships = await request("/api/competitions", { bearer: b.accessToken });
  const nativeApiMembershipsBody = await nativeApiMemberships.text();
  assert(nativeApiMemberships.ok, `Bearer session could not reach the authenticated competition API (HTTP ${nativeApiMemberships.status}: ${nativeApiMembershipsBody}).`);
  const authorization = await request("/api/auth/native/authorize", {
    bearer: b.accessToken,
    method: "POST",
    body: {},
  });
  const authorizationBody = await authorization.text();
  assert(
    authorization.ok,
    `Signed-in participant could not authorize the Mac client (HTTP ${authorization.status}: ${authorizationBody}).`,
  );
  const callbackUrl = new URL(JSON.parse(authorizationBody).callbackUrl);
  assert(callbackUrl.protocol === "osttracker:" && callbackUrl.hostname === "competition", "Native authorization callback is not the fixed app URL.");
  const code = callbackUrl.searchParams.get("code");
  assert(code?.length === 43, "Native authorization code is not high entropy.");
  const exchange = await request("/api/auth/native/exchange", {
    method: "POST",
    body: { code },
    includeOrigin: false,
  });
  assert(exchange.ok, "Native one-time authorization code could not be exchanged.");
  const nativeSession = await exchange.json();
  assert(typeof nativeSession.refreshToken === "string" && nativeSession.refreshToken.length >= 8, "Native exchange omitted a valid refresh token.");
  const refresh = await request("/api/auth/native/refresh", {
    method: "POST",
    body: { refreshToken: nativeSession.refreshToken },
    includeOrigin: false,
  });
  const refreshBody = await refresh.text();
  assert(refresh.ok, `Native refresh-token renewal failed (HTTP ${refresh.status}: ${refreshBody}).`);
  const refreshedSession = JSON.parse(refreshBody);
  const bearerMemberships = await request("/api/competitions", { bearer: refreshedSession.accessToken });
  const bearerMembershipsBody = await bearerMemberships.text();
  assert(bearerMemberships.ok && bearerMembershipsBody.includes(competitionId), "Bearer-authenticated Mac session could not use the competition API.");
  const nativeRating = {
    competitionId,
    batch: 1,
    listeningId: listeningA,
    score: 7,
    expectedVersion: 0,
  };
  const nativeWrite = await request("/api/ratings", {
    bearer: refreshedSession.accessToken,
    method: "PUT",
    body: nativeRating,
  });
  assert(nativeWrite.ok && (await nativeWrite.json()).version === 1, "Mac bearer session could not save an assigned rating.");
  const staleNativeWrite = await request("/api/ratings", {
    bearer: refreshedSession.accessToken,
    method: "PUT",
    body: nativeRating,
  });
  assert(staleNativeWrite.status === 409, "Mac stale rating version was silently overwritten.");
  const replay = await request("/api/auth/native/exchange", {
    method: "POST",
    body: { code },
    includeOrigin: false,
  });
  assert(replay.status === 404, "Native authorization code was reusable.");
  const legacyArchive = {
    sourceId: legacySourceId,
    name: "Legacy import probe",
    payload: { osts: [{ title: "Old OST" }], ratings: [], settings: [] },
  };
  const legacyImport = await request("/api/host/legacy-import", {
    bearer: identities[0].accessToken,
    method: "POST",
    body: legacyArchive,
  });
  assert(legacyImport.ok && (await legacyImport.json()).imported, "Authenticated Mac host could not import a legacy ranking.");
  const legacyReplay = await request("/api/host/legacy-import", {
    bearer: identities[0].accessToken,
    method: "POST",
    body: legacyArchive,
  });
  assert(legacyReplay.ok && !(await legacyReplay.json()).imported, "Legacy archive import was not idempotent.");

  const appCheck = await request("/app", { cookie: b.cookie });
  if (appCheck.status !== 200)
    console.log(
      `Local session diagnostics: cookie names ${b.cookieNames.join(",")}; /app HTTP ${appCheck.status}; location ${appCheck.headers.get("location") ?? "none"}.`,
    );
  const query = `?fixture=${id}`;
  const ownSubmissions = await request(
    `/api/competitions/${competitionId}/submissions${query}`,
    { cookie: b.cookie },
  );
  const ownSubmissionBody = await ownSubmissions.text();
  assert(
    ownSubmissions.status === 200,
    `Participant could not read their own submissions (HTTP ${ownSubmissions.status}: ${ownSubmissionBody}).`,
  );
  assert(
    ownSubmissions.headers.get("cache-control")?.includes("no-store"),
    "Participant API response is cacheable.",
  );
  assert(
    ownSubmissionBody.includes("Secret OST Title B") &&
      !ownSubmissionBody.includes("Secret OST Title A"),
    "Submission API exposed another participant's submission.",
  );

  const forbiddenPreview = await request(
    `/api/submissions/${submissionA}/preview`,
    { cookie: b.cookie },
  );
  assert(
    forbiddenPreview.status === 404 &&
      !(await forbiddenPreview.text()).includes(keyA),
    "Participant could read another participant's submission preview.",
  );

  const unreleased = await request(
    `/api/competitions/${competitionId}/batches/2`,
    { cookie: b.cookie },
  );
  assert(
    unreleased.status === 404,
    "Unreleased batch entries were available to a participant.",
  );

  const released = await request(
    `/api/competitions/${competitionId}/batches/1`,
    { cookie: b.cookie },
  );
  assert(released.status === 200, "Released anonymous batch was unavailable.");
  const releasedBody = await released.json();
  assert(
    releasedBody.entries.length === 2 &&
      !JSON.stringify(releasedBody).includes("Secret Franchise") &&
      !JSON.stringify(releasedBody).includes("Secret OST Title"),
    "Listening response exposed entry mappings or titles.",
  );
  const otherRatingView = releasedBody.entries.find(
    (entry) => entry.listeningId === listeningA,
  );
  assert(
    otherRatingView?.rating === 7 &&
      otherRatingView?.automaticScore === null,
    "Listening response did not return only the participant's own Mac-saved rating.",
  );
  const playable = await fetch(releasedBody.entries[0].audioUrl);
  assert(
    playable.ok,
    "An authorized short-lived audio URL did not serve the released clip.",
  );

  const csrfWrite = await request("/api/ratings", {
    cookie: b.cookie,
    method: "PUT",
    body: {
      competitionId,
      batch: 1,
      listeningId: listeningB,
      score: 8,
      expectedVersion: 1,
    },
  });
  assert(
    csrfWrite.status === 404,
    "A cookie-authenticated write without an Origin header passed CSRF validation.",
  );

  const notPublished = await request(
    `/api/competitions/${competitionId}/results${query}`,
    { cookie: b.cookie },
  );
  assert(
    notPublished.status === 200 &&
      JSON.stringify(await notPublished.json()) ===
        JSON.stringify({ results: [] }),
    "Unpublished ranking data reached a participant response.",
  );

  const otherRatingWrite = await request("/api/ratings", {
    cookie: b.cookie,
    method: "PUT",
    body: {
      competitionId,
      batch: 1,
      listeningId: randomUUID(),
      score: 1,
      expectedVersion: 0,
    },
  });
  assert(
    otherRatingWrite.status === 404,
    "Participant could rate an entry outside their own assigned batch.",
  );

  const hostConsole = await request(`/api/host/competitions/${competitionId}`, {
    cookie: b.cookie,
  });
  assert(
    hostConsole.status === 404,
    "Participant opened host-only competition data.",
  );
  const hostAction = await request(
    `/api/host/competitions/${competitionId}/actions`,
    { cookie: b.cookie, method: "POST", body: { action: "close_ratings" } },
  );
  assert(hostAction.status === 404, "Participant performed a host action.");
  const hostTrials = await request("/api/host/trials", { cookie: b.cookie });
  assert(
    hostTrials.status === 404,
    "Participant read host trial management data.",
  );
  const hostSecurity = await request("/api/host/security", {
    cookie: b.cookie,
  });
  assert(
    hostSecurity.status === 404,
    "Participant read host credential or audit data.",
  );
  const hostReviews = await request("/api/host/submission-reviews", {
    cookie: b.cookie,
  });
  assert(
    hostReviews.status === 404,
    "Participant read submitter mappings through host review data.",
  );
  const hostScore = await request(
    `/api/host/competitions/${competitionId}/actions`,
    { cookie: b.cookie, method: "POST", body: { action: "score" } },
  );
  assert(hostScore.status === 404, "Participant triggered privileged scoring.");

  const appPage = await request("/app", { cookie: b.cookie });
  const appHtml = await appPage.text();
  assert(
    appPage.status === 200 &&
      appPage.headers.get("cache-control")?.includes("no-store") &&
      appHtml.includes("Participant B Only") &&
      !appHtml.includes("Participant A Secret") &&
      !appHtml.includes("Submission checks") &&
      !appHtml.includes("Host security"),
    "Participant app page payload exposed another participant or host-only information, or is cacheable.",
  );
  const listenPage = await request(`/competition/${competitionId}/listen`, {
    cookie: b.cookie,
  });
  const listenHtml = await listenPage.text();
  assert(
    listenPage.status === 200 &&
      !listenHtml.includes("Secret OST Title A") &&
      !listenHtml.includes("Secret OST Title B"),
    "Listening page payload included unrevealed soundtrack mappings.",
  );

  const anonymousHost = await request(
    `/api/host/competitions/${competitionId}`,
  );
  assert(
    anonymousHost.status === 404,
    "Unauthenticated request received host-only data.",
  );
  const directPrivateSchema = await fetch(
    `${process.env.SUPABASE_URL}/rest/v1/submissions?select=*`,
    {
      headers: {
        apikey: process.env.SUPABASE_ANON_KEY,
        authorization: `Bearer ${b.accessToken}`,
        "accept-profile": "private",
      },
    },
  );
  assert(
    !directPrivateSchema.ok,
    "Participant queried competition tables through PostgREST.",
  );

  const foreignObject = await b.storage.storage.from(bucket).download(keyA);
  assert(
    foreignObject.error,
    "Direct participant Storage read bypassed signed playback URLs.",
  );
  const foreignOriginal = await b.storage.storage
    .from(bucket)
    .download(originalKeyA);
  assert(
    foreignOriginal.error,
    "Participant read another person's private original video.",
  );
  const anonStorage = createClient(
    process.env.SUPABASE_URL,
    process.env.SUPABASE_ANON_KEY,
    { auth: { persistSession: false } },
  );
  const publicObject = await anonStorage.storage.from(bucket).download(keyA);
  assert(
    publicObject.error,
    "Anonymous Storage read succeeded for private media.",
  );

  sql(`update private.competitions set status='complete' where id='${competitionId}';
    update private.reveal_groups set published_at=now() where competition_id='${competitionId}';
    insert into private.reveal_events(competition_id,listening_id,group_number)
      values('${competitionId}','${listeningA}',1),('${competitionId}','${listeningB}',1);`);
  const participantArchive = await request(
    `/api/competitions/${competitionId}/archive`,
    { bearer: b.accessToken },
  );
  const participantArchiveBody = await participantArchive.json();
  assert(
    participantArchive.ok && participantArchiveBody.entries.length === 2 && participantArchiveBody.originals.length === 0,
    "Participant archive did not contain only published audio and metadata.",
  );
  const hostArchive = await request(
    `/api/competitions/${competitionId}/archive`,
    { bearer: identities[0].accessToken },
  );
  const hostArchiveBody = await hostArchive.json();
  assert(
    hostArchive.ok && hostArchiveBody.entries.length === 2 && hostArchiveBody.originals.length === 2,
    `Host archive did not include private originals (HTTP ${hostArchive.status}, entries ${hostArchiveBody.entries?.length ?? 0}, originals ${hostArchiveBody.originals?.length ?? 0}).`,
  );
  const archiveRemoval = await request(
    `/api/host/competitions/${competitionId}/archive-originals`,
    {
      bearer: identities[0].accessToken,
      method: "POST",
      body: {
        confirmation: "ARCHIVE VERIFIED",
        digest: "ab".repeat(32),
      },
    },
  );
  assert(
    archiveRemoval.ok && (await archiveRemoval.json()).archivedOriginals === 2,
    "Host could not remove originals after local archive confirmation.",
  );
  const removedOriginal = await admin.storage.from(bucket).download(originalKeyA);
  assert(removedOriginal.error, "Archived original remained downloadable from Storage.");

  console.log(
    "Local API, Storage, rendered-payload, native-session, legacy-import, stale-write, and archive authorization probes passed.",
  );
} finally {
  server.kill("SIGTERM");
  if (server.exitCode === null)
    await Promise.race([
      new Promise((resolve) => server.once("exit", resolve)),
      delay(2_000),
    ]);
  if (uploaded.length)
    await admin.storage
      .from(bucket)
      .remove(uploaded)
      .catch(() => undefined);
  if (seeded) {
    sql(
      `delete from private.legacy_competition_imports where source_id='${legacySourceId}'; delete from private.platform_config where host_user_id='${hostId}'; delete from private.competitions where id='${competitionId}';`,
    );
  }
  for (const userId of users)
    await admin.auth.admin.deleteUser(userId).catch(() => undefined);
}
