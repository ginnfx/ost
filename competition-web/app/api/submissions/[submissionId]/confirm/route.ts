import { withCurrentUser } from "@/lib/server/database";
import { privateJson, sameOriginRequest, unavailable } from "@/lib/server/http";

export async function POST(
  request: Request,
  context: { params: Promise<{ submissionId: string }> },
) {
  if (!sameOriginRequest(request)) return unavailable();
  const { submissionId } = await context.params;
  if (!/^[0-9a-f-]{36}$/i.test(submissionId)) return unavailable();
  try {
    await withCurrentUser((db) =>
      db.query("select private.confirm_submission($1)", [submissionId]),
    );
    return privateJson({ success: true, status: "confirmed" });
  } catch {
    return unavailable();
  }
}
