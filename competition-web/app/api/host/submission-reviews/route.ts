import { HostAccessDenied, withHost } from "@/lib/server/database";
import { privateJson, unavailable } from "@/lib/server/http";
import { SupabasePrivateObjectStore } from "@/lib/server/storage";

export async function GET() {
  try {
    const reviews = await withHost(async (db) => {
      const [reviewResult, failureResult] = await Promise.all([
        db.query<{
          submission_id: string;
          competition_id: string;
          round_name: string;
          nickname: string;
          slot: number;
          franchise: string;
          anilist_id: number | null;
          ost_title: string;
          original_seconds: number;
          audio_seconds: number;
          original_key: string;
          audio_key: string;
          status: string;
          duplicate_count: number;
          history_reuse_count: number;
        }>("select * from private.list_host_submission_reviews()"),
        db.query<{
          upload_id: string;
          competition_id: string;
          round_name: string;
          nickname: string;
          slot: number;
          ost_title: string;
          error_code: string;
          attempt_count: number;
          updated_at: string;
        }>("select * from private.host_list_media_failures()"),
      ]);
      return { reviews: reviewResult.rows, failures: failureResult.rows };
    });
    const storage = new SupabasePrivateObjectStore();
    const dto = await Promise.all(
      reviews.reviews.map(async (item) => ({
        submissionId: item.submission_id,
        competitionId: item.competition_id,
        roundName: item.round_name,
        nickname: item.nickname,
        slot: item.slot,
        franchise: item.franchise,
        anilistId: item.anilist_id,
        ostTitle: item.ost_title,
        originalSeconds: Number(item.original_seconds),
        audioSeconds: Number(item.audio_seconds),
        status: item.status,
        duplicateCount: Number(item.duplicate_count),
        historyReuseCount: Number(item.history_reuse_count),
        originalUrl: await storage.signedReadUrl(item.original_key, 120),
        audioUrl: await storage.signedReadUrl(item.audio_key, 120),
      })),
    );
    return privateJson({
      reviews: dto,
      failures: reviews.failures.map((item) => ({
        uploadId: item.upload_id,
        roundName: item.round_name,
        nickname: item.nickname,
        slot: item.slot,
        ostTitle: item.ost_title,
        errorCode: item.error_code,
        attemptCount: item.attempt_count,
        updatedAt: item.updated_at,
      })),
    });
  } catch (error) {
    return error instanceof HostAccessDenied ? unavailable() : unavailable();
  }
}
