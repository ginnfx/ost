import { withCurrentUser } from "@/lib/server/database";
import { privateJson, unavailable } from "@/lib/server/http";
import { SupabasePrivateObjectStore } from "@/lib/server/storage";

export async function GET(
  _request: Request,
  context: { params: Promise<{ competitionId: string; batchNumber: string }> },
) {
  const { competitionId, batchNumber: batchText } = await context.params;
  const batchNumber = Number(batchText);
  if (
    !/^[0-9a-f-]{36}$/i.test(competitionId) ||
    !Number.isInteger(batchNumber) ||
    batchNumber < 1 ||
    batchNumber > 20
  )
    return unavailable();
  try {
    const rows = await withCurrentUser(async (db) => {
      const result = await db.query<{
        listening_id: string;
        label: string;
        audio_storage_key: string;
        duration_seconds: number;
        is_own: boolean;
        own_rating: number | null;
        current_rating: number | null;
        rating_version: string | null;
      }>("select * from private.my_listening_batch_entries($1,$2::smallint)", [
        competitionId,
        batchNumber,
      ]);
      return result.rows;
    });
    const storage = new SupabasePrivateObjectStore();
    const entries = await Promise.all(
      rows.map(async (row) => ({
        listeningId: row.listening_id,
        label: row.label,
        audioUrl: await storage.signedReadUrl(row.audio_storage_key, 120),
        durationSeconds: Number(row.duration_seconds),
        own: row.is_own,
        automaticScore: row.own_rating,
        rating: row.current_rating,
        version: row.rating_version === null ? 0 : Number(row.rating_version),
      })),
    );
    return privateJson({ entries });
  } catch {
    return unavailable();
  }
}
