import { z } from "zod";
import { withCurrentUser } from "@/lib/server/database";
import { privateJson, unavailable } from "@/lib/server/http";

export async function GET(
  _request: Request,
  context: { params: Promise<{ uploadId: string }> },
) {
  const { uploadId } = await context.params;
  if (!z.string().uuid().safeParse(uploadId).success) return unavailable();
  try {
    const { rows } = await withCurrentUser((db) =>
      db.query<{
        status: string;
        error_code: string | null;
      }>("select * from private.my_submission_upload_status($1)", [uploadId]),
    );
    if (!rows[0]) return unavailable();
    return privateJson({
      status: rows[0].status,
      errorCode: rows[0].error_code,
    });
  } catch {
    return unavailable();
  }
}
