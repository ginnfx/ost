import { withCurrentUser } from "@/lib/server/database";
import { privateJson, unavailable } from "@/lib/server/http";

export async function GET(
  _request: Request,
  context: { params: Promise<{ competitionId: string }> },
) {
  const { competitionId } = await context.params;
  if (!/^[0-9a-f-]{36}$/i.test(competitionId)) return unavailable();
  try {
    const policy = await withCurrentUser(async (db) => {
      const result = await db.query(
        "select * from private.my_submission_upload_policy($1)",
        [competitionId],
      );
      return result.rows[0] ?? null;
    });
    if (!policy) return unavailable();
    return privateJson({
      maxUploadBytes: Number(policy.max_upload_bytes),
      minClipSeconds: Number(policy.min_clip_seconds),
      maxClipSeconds: Number(policy.max_clip_seconds),
      entriesPerParticipant: Number(policy.entries_per_participant),
    });
  } catch {
    return unavailable();
  }
}
