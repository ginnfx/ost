import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import nextEnv from "@next/env";
import { createClient } from "@supabase/supabase-js";
import { scoreCompetition } from "../lib/scoring.ts";

nextEnv.loadEnvConfig(process.cwd());

for (const name of ["SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY"])
  if (!process.env[name]) throw new Error(`${name} is required for this local test.`);

const admin = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY,
  { auth: { persistSession: false, autoRefreshToken: false } },
);
const competitionId = randomUUID();
const hostId = randomUUID();
const participantId = randomUUID();
const hostEmail = `host-${competitionId}@example.invalid`;
const participantEmail = `player-${competitionId}@example.invalid`;
const dbContainer =
  process.env.LOCAL_SUPABASE_DB_CONTAINER ?? "supabase_db_ost-competition-private";
const userIds = [hostId, participantId];

function psql(query) {
  try {
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
      query,
    ],
    { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
    ).trim();
  } catch (error) {
    if (error instanceof Error && "stderr" in error && error.stderr)
      throw new Error(String(error.stderr).trim());
    throw error;
  }
}

function asUser(userId, query, json = false) {
  const claims = JSON.stringify({ sub: userId, role: "authenticated" });
  return psql(
    `begin; set local role ost_web_app; select set_config('request.jwt.claim.sub','${userId}',true); select set_config('request.jwt.claims','${claims}',true); ${query}; commit;`,
    json,
  );
}
function asUserJSON(userId, query) {
  const result = asUser(userId, query);
  return JSON.parse(result.split("\n").at(-1));
}
function expectSqlFailure(run, fragment) {
  try {
    run();
  } catch (error) {
    if (error instanceof Error && error.message.includes(fragment)) return;
    throw error;
  }
  throw new Error(`Expected database rejection containing: ${fragment}`);
}

async function createUser(id, email) {
  const result = await admin.auth.admin.createUser({
    id,
    email,
    email_confirm: true,
  });
  if (result.error) throw result.error;
}

function cleanFixture() {
  psql(`
    alter table private.host_audit_log disable trigger host_audit_append_only;
    delete from private.host_audit_log where competition_id='${competitionId}' or actor_user_id in ('${hostId}','${participantId}');
    delete from private.platform_config where host_user_id='${hostId}';
    delete from private.competitions where id='${competitionId}';
    alter table private.host_audit_log enable trigger host_audit_append_only;
  `);
}

try {
  await createUser(hostId, hostEmail);
  await createUser(participantId, participantEmail);
  psql(`
    insert into private.platform_config(singleton,host_user_id) values(true,'${hostId}');
    insert into private.competitions(id,name,status,settings)
    values ('${competitionId}','Local listening test','submissions_open',
      '{"entries_per_participant":2,"batch_count":2,"reveal_group_count":2,"min_clip_seconds":20,"max_clip_seconds":360,"max_upload_bytes":524288000,"loudness_normalization":false}');
    insert into private.participants(competition_id,user_id,nickname) values
      ('${competitionId}','${hostId}','Host'),('${competitionId}','${participantId}','Player');
    insert into private.submissions(competition_id,participant_id,slot,franchise,ost_title,status,
      original_storage_key,audio_storage_key,original_bytes,original_seconds,audio_seconds,confirmed_at)
    select '${competitionId}',p.id,n,'Series '||n,'Track '||p.nickname||n,'confirmed',
      repeat(md5(p.id::text||n),1)||'/'||md5(p.id::text||n||'original')||'.mp4',
      repeat(md5(p.id::text||n),1)||'/'||md5(p.id::text||n||'audio')||'.m4a',1024,60,60,now()
    from private.participants p cross join generate_series(1,2) n where p.competition_id='${competitionId}';
  `);

  asUser(hostId, `select private.host_lock_submissions('${competitionId}')`);
  const startResult = asUser(
    hostId,
    `select private.host_start_listening('${competitionId}')`,
  );
  if (!startResult.endsWith("2")) throw new Error("Expected two listening batches.");
  for (const batch of [1, 2])
    asUser(hostId, `select private.host_release_batch('${competitionId}',${batch}::smallint)`);

  for (const userId of userIds) {
    const batchRows = asUserJSON(
      userId,
      `select coalesce(json_agg(to_jsonb(x) order by x.batch_number),'[]'::json) from private.my_listening_batches('${competitionId}') x`,
    );
    if (batchRows.length !== 2 || batchRows.some((batch) => batch.entry_count === 0))
      throw new Error("Expected each participant to have nonempty batches.");
    for (const batch of batchRows) {
      const entries = asUserJSON(
        userId,
        `select coalesce(json_agg(to_jsonb(x) order by x.label),'[]'::json) from private.my_listening_batch_entries('${competitionId}',${batch.batch_number}::smallint) x`,
      );
      for (const entry of entries) {
        if (entry.is_own) {
          if (entry.own_rating !== 10)
            throw new Error("Own entry did not receive its automatic ten.");
          continue;
        }
        asUser(
          userId,
          `select private.save_listening_rating('${competitionId}',${batch.batch_number}::smallint,'${entry.listening_id}',8::smallint,0::bigint)`,
        );
      }
      asUser(
        userId,
        `select private.finalize_listening_batch('${competitionId}',${batch.batch_number}::smallint)`,
      );
      const editable = entries.find((entry) => !entry.is_own);
      if (editable)
        expectSqlFailure(
          () =>
            asUser(
              userId,
              `select private.save_listening_rating('${competitionId}',${batch.batch_number}::smallint,'${editable.listening_id}',9::smallint,${editable.rating_version}::bigint)`,
            ),
          "Batch is finalized",
        );
    }
  }

  const reopenedEntry = asUserJSON(
    participantId,
    `select coalesce(json_agg(to_jsonb(x)),'[]'::json) from private.my_listening_batch_entries('${competitionId}',1::smallint) x where not x.is_own`,
  )[0];
  const participantRecordId = psql(
    `select id from private.participants where competition_id='${competitionId}' and user_id='${participantId}'`,
  );
  asUser(
    hostId,
    `select private.host_reopen_listening_batch('${competitionId}','${participantRecordId}',1::smallint)`,
  );
  asUser(
    participantId,
    `select private.save_listening_rating('${competitionId}',1::smallint,'${reopenedEntry.listening_id}',9::smallint,${reopenedEntry.rating_version}::bigint)`,
  );
  asUser(
    participantId,
    `select private.finalize_listening_batch('${competitionId}',1::smallint)`,
  );

  asUser(
    hostId,
    `select private.host_close_ratings('${competitionId}')`,
  );
  const scoringInput = asUserJSON(
    hostId,
    `select private.host_scoring_input('${competitionId}')`,
  );
  const snapshot = scoreCompetition(scoringInput);
  asUser(
    hostId,
    `select private.host_record_score_snapshot('${competitionId}','${scoringInput.seed}',$payload$${JSON.stringify(snapshot)}$payload$::jsonb)`,
  );
  if (snapshot.ranked.length !== 4 || snapshot.revealGroups.length !== 2)
    throw new Error("Scoring snapshot has an unexpected shape.");

  for (const group of snapshot.revealGroups) {
    asUser(
      hostId,
      `select private.host_publish_reveal_group('${competitionId}',${group.number}::smallint)`,
    );
    const before = asUserJSON(
      participantId,
      `select coalesce(json_agg(to_jsonb(x)),'[]'::json) from private.list_published_results('${competitionId}') x`,
    );
    const startCount = before.length;
    for (let index = 0; index < group.entryIds.length; index += 1)
      asUser(
        hostId,
        `select private.host_reveal_next_entry('${competitionId}',${group.number}::smallint)`,
      );
    const after = asUserJSON(
      participantId,
      `select coalesce(json_agg(to_jsonb(x)),'[]'::json) from private.list_published_results('${competitionId}') x`,
    );
    if (after.length - startCount !== group.entryIds.length)
      throw new Error("Participants did not receive exactly the entries revealed.");
  }
  const finalStatus = psql(
    `select status from private.competitions where id='${competitionId}'`,
  );
  if (finalStatus !== "complete") throw new Error("Reveal did not complete the round.");
  console.log("Local listening, rating, frozen scoring, and reveal workflow passed.");
} finally {
  cleanFixture();
  for (const id of userIds)
    await admin.auth.admin.deleteUser(id).catch(() => undefined);
}
