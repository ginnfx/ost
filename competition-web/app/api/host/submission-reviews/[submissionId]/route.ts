import { z } from "zod";
import { HostAccessDenied, withHost } from "@/lib/server/database";
import { privateJson, sameOriginRequest, unavailable } from "@/lib/server/http";

const schema = z.object({ action: z.enum(["approve", "reject"]) }).strict();

export async function POST(
  request: Request,
  context: { params: Promise<{ submissionId: string }> },
) {
  if (!sameOriginRequest(request)) return unavailable();
  const { submissionId } = await context.params;
  const parsed = schema.safeParse(await request.json().catch(() => null));
  if (!/^[0-9a-f-]{36}$/i.test(submissionId) || !parsed.success)
    return unavailable();
  try {
    await withHost((db) =>
      db.query("select private.host_clear_submission_review($1,$2)", [
        submissionId,
        parsed.data.action === "approve",
      ]),
    );
    return privateJson({ success: true });
  } catch (error) {
    return error instanceof HostAccessDenied ? unavailable() : unavailable();
  }
}
