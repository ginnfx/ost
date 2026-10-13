import { withCurrentUser, withHost } from "@/lib/server/database";
import { privateJson, unavailable } from "@/lib/server/http";
import { SupabasePrivateObjectStore } from "@/lib/server/storage";

export async function GET(
  _request: Request,
  context: { params: Promise<{ competitionId: string }> },
) {
  const { competitionId } = await context.params;
  if (!/^[0-9a-f-]{36}$/i.test(competitionId)) return unavailable();
  try {
    const rows = await withCurrentUser(async (db) => {
      const result = await db.query(
        "select * from private.my_completed_competition_archive($1)",
        [competitionId],
      );
      return result.rows;
    });
    const storage = new SupabasePrivateObjectStore();
    const entries = await Promise.all(
      rows.map(async (row) => ({
        listeningId: row.listening_id,
        label: row.label,
        franchise: row.franchise,
        title: row.ost_title,
        rank: Number(row.rank),
        meanScore: row.mean_score,
        ratingCount: Number(row.rating_count),
        group: Number(row.group_number),
        audioUrl: await storage.signedReadUrl(row.audio_storage_key, 300),
      })),
    );
    let originals: string[] = [];
    try {
      const keys = await withHost(async (db) => {
        const { rows: originals } = await db.query<{ storage_key: string }>(
          "select * from private.host_archived_original_keys($1)",
          [competitionId],
        );
        return originals.map((row) => row.storage_key);
      });
      originals = await Promise.all(
        keys.map((key) => storage.signedReadUrl(key, 300)),
      );
    } catch {
      // Participants receive audio only. The original videos are host-only.
    }
    return privateJson({ competitionId, entries, originals });
  } catch {
    return unavailable();
  }
}
