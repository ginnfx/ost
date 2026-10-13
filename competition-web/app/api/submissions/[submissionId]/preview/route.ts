import { withCurrentUser } from "@/lib/server/database";
import { privateJson, unavailable } from "@/lib/server/http";
import { SupabasePrivateObjectStore } from "@/lib/server/storage";

export async function GET(
  _request: Request,
  context: { params: Promise<{ submissionId: string }> },
) {
  const { submissionId } = await context.params;
  if (!/^[0-9a-f-]{36}$/i.test(submissionId)) return unavailable();
  try {
    const key = await withCurrentUser(async (db) => {
      const result = await db.query<{
        my_submission_preview_key: string | null;
      }>("select private.my_submission_preview_key($1)", [submissionId]);
      return result.rows[0]?.my_submission_preview_key;
    });
    if (!key) return unavailable();
    const url = await new SupabasePrivateObjectStore().signedReadUrl(key, 120);
    return privateJson({ url, expiresIn: 120 });
  } catch {
    return unavailable();
  }
}
