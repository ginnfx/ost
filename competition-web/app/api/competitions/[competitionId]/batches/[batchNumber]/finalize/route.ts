import { withCurrentUser } from "@/lib/server/database";
import { privateJson, sameOriginRequest, unavailable } from "@/lib/server/http";

export async function POST(
  request: Request,
  context: { params: Promise<{ competitionId: string; batchNumber: string }> },
) {
  if (!sameOriginRequest(request)) return unavailable();
  const { competitionId, batchNumber: batchText } = await context.params;
  const batchNumber = Number(batchText);
  if (!/^[0-9a-f-]{36}$/i.test(competitionId) || !Number.isInteger(batchNumber))
    return unavailable();
  try {
    await withCurrentUser((db) =>
      db.query("select private.finalize_listening_batch($1,$2::smallint)", [
        competitionId,
        batchNumber,
      ]),
    );
    return privateJson({ finalized: true });
  } catch {
    return unavailable();
  }
}
