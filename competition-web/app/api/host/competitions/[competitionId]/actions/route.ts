import { cookies } from "next/headers";
import { z } from "zod";
import { scoreCompetition } from "@/lib/scoring";
import { HostAccessDenied, withHost } from "@/lib/server/database";
import { isRecentlyVerified } from "@/lib/server/webauthn";
import { privateJson, sameOriginRequest, unavailable } from "@/lib/server/http";

const schema = z
  .object({
    action: z.enum([
      "lock_submissions",
      "start_listening",
      "release_batch",
      "reopen_batch",
      "close_ratings",
      "score",
      "publish_group",
      "reveal_next",
    ]),
    batch: z.number().int().positive().max(20).optional(),
    group: z.number().int().positive().max(20).optional(),
    participantId: z.string().uuid().optional(),
  })
  .strict();

export async function POST(
  request: Request,
  context: { params: Promise<{ competitionId: string }> },
) {
  if (!sameOriginRequest(request)) return unavailable();
  const { competitionId } = await context.params;
  const input = schema.safeParse(await request.json().catch(() => null));
  if (!/^[0-9a-f-]{36}$/i.test(competitionId) || !input.success)
    return unavailable();
  try {
    if (input.data.action === "publish_group") {
      const store = await cookies();
      const authorized = await withHost(async (_db, userId) =>
        isRecentlyVerified(store.get("ost_host_recent")?.value, userId),
      );
      if (!authorized)
        return privateJson(
          {
            error:
              "Confirm with your passkey again before publishing this group.",
          },
          401,
        );
    }
    let result: unknown = null;
    await withHost(async (db) => {
      switch (input.data.action) {
        case "lock_submissions":
          await db.query("select private.host_lock_submissions($1)", [
            competitionId,
          ]);
          break;
        case "start_listening": {
          const query = await db.query(
            "select private.host_start_listening($1)",
            [competitionId],
          );
          result = { batches: Number(query.rows[0]?.host_start_listening) };
          break;
        }
        case "release_batch":
          if (!input.data.batch) throw new Error("RESOURCE_UNAVAILABLE");
          await db.query("select private.host_release_batch($1,$2::smallint)", [
            competitionId,
            input.data.batch,
          ]);
          break;
        case "reopen_batch":
          if (!input.data.batch || !input.data.participantId)
            throw new Error("RESOURCE_UNAVAILABLE");
          await db.query(
            "select private.host_reopen_listening_batch($1,$2,$3::smallint)",
            [competitionId, input.data.participantId, input.data.batch],
          );
          break;
        case "close_ratings":
          await db.query("select private.host_close_ratings($1)", [
            competitionId,
          ]);
          break;
        case "score": {
          const inputResult = await db.query<{
            host_scoring_input: Parameters<typeof scoreCompetition>[0];
          }>("select private.host_scoring_input($1)", [competitionId]);
          const scoringInput = inputResult.rows[0]?.host_scoring_input;
          if (!scoringInput) throw new Error("RESOURCE_UNAVAILABLE");
          const snapshot = scoreCompetition(scoringInput);
          await db.query(
            "select private.host_record_score_snapshot($1,$2,$3::jsonb)",
            [competitionId, scoringInput.seed, JSON.stringify(snapshot)],
          );
          result = {
            rankedEntries: snapshot.ranked.length,
            revealGroups: snapshot.revealGroups.length,
          };
          break;
        }
        case "publish_group":
          if (!input.data.group) throw new Error("RESOURCE_UNAVAILABLE");
          await db.query(
            "select private.host_publish_reveal_group($1,$2::smallint)",
            [competitionId, input.data.group],
          );
          break;
        case "reveal_next": {
          if (!input.data.group) throw new Error("RESOURCE_UNAVAILABLE");
          const query = await db.query(
            "select private.host_reveal_next_entry($1,$2::smallint)",
            [competitionId, input.data.group],
          );
          result = { revealed: query.rows[0]?.host_reveal_next_entry === true };
          break;
        }
      }
    });
    return privateJson({ success: true, ...(result as object | null) });
  } catch (error) {
    if (error instanceof HostAccessDenied) return unavailable();
    return unavailable();
  }
}
