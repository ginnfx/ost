import { withCurrentUser } from "@/lib/server/database";
import { privateJson, unavailable } from "@/lib/server/http";

export async function GET(
  _request: Request,
  context: { params: Promise<{ competitionId: string }> },
) {
  const { competitionId } = await context.params;
  if (!/^[0-9a-f-]{36}$/i.test(competitionId)) return unavailable();
  try {
    const submissions = await withCurrentUser(async (db) => {
      const { rows } = await db.query(
        "select * from private.list_my_submissions($1)",
        [competitionId],
      );
      return rows.map((row) => ({
        submissionId: row.submission_id,
        slot: row.slot,
        franchise: row.franchise,
        aniListId: row.anilist_id,
        ostTitle: row.ost_title,
        status: row.status,
        durationMismatch: row.duration_mismatch,
        version: Number(row.version),
      }));
    });
    return privateJson({ submissions });
  } catch {
    return unavailable();
  }
}
