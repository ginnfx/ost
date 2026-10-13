import { HostAccessDenied, withHost } from "@/lib/server/database";
import { privateJson, unavailable } from "@/lib/server/http";

export async function GET(
  _request: Request,
  context: { params: Promise<{ competitionId: string }> },
) {
  const { competitionId } = await context.params;
  if (!/^[0-9a-f-]{36}$/i.test(competitionId)) return unavailable();
  try {
    const state = await withHost(async (db) => {
      const { rows } = await db.query<{ host_round_control_state: unknown }>(
        "select private.host_round_control_state($1)",
        [competitionId],
      );
      return rows[0]?.host_round_control_state;
    });
    return privateJson({ state });
  } catch (error) {
    if (error instanceof HostAccessDenied) return unavailable();
    return unavailable();
  }
}
