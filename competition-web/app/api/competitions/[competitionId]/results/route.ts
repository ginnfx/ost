import { withCurrentUser } from "@/lib/server/database";
import { privateJson, unavailable } from "@/lib/server/http";

export async function GET(
  _request: Request,
  context: { params: Promise<{ competitionId: string }> },
) {
  const { competitionId } = await context.params;
  if (!/^[0-9a-f-]{36}$/i.test(competitionId)) return unavailable();
  try {
    const results = await withCurrentUser(async (db) => {
      const { rows } = await db.query(
        "select * from private.list_published_results($1)",
        [competitionId],
      );
      return rows.map((row) => ({
        listeningId: row.listening_id,
        label: row.label,
        franchise: row.franchise,
        ostTitle: row.ost_title,
        rank: Number(row.rank),
        meanScore: row.mean_score,
        ratingCount: Number(row.rating_count),
        group: Number(row.group_number),
        publishedAt: row.published_at,
      }));
    });
    return privateJson({ results });
  } catch {
    return unavailable();
  }
}
