import { withCurrentUser } from "@/lib/server/database";
import { privateJson, unavailable } from "@/lib/server/http";

export async function GET(
  _request: Request,
  context: { params: Promise<{ competitionId: string }> },
) {
  const { competitionId } = await context.params;
  if (!/^[0-9a-f-]{36}$/i.test(competitionId)) return unavailable();
  try {
    const batches = await withCurrentUser(async (db) => {
      const { rows } = await db.query(
        "select * from private.my_listening_batches($1)",
        [competitionId],
      );
      return rows.map((row) => ({
        number: Number(row.batch_number),
        status: row.status,
        releasedAt: row.released_at,
        entryCount: Number(row.entry_count),
        ratedCount: Number(row.rated_count),
        finalized: row.finalized,
      }));
    });
    return privateJson({ batches });
  } catch {
    return unavailable();
  }
}
