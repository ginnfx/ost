import { withCurrentUser } from "@/lib/server/database";
import { privateJson, unavailable } from "@/lib/server/http";

export async function GET() {
  try {
    const competitions = await withCurrentUser(async (db) => {
      const { rows } = await db.query(
        "select * from private.my_competition_memberships()",
      );
      return rows.map((row) => ({
        competitionId: row.competition_id,
        name: row.round_name,
        status: row.round_status,
        nickname: row.nickname,
        isTrial: row.is_trial,
        entriesPerParticipant: Number(row.entries_per_participant),
      }));
    });
    return privateJson({ competitions });
  } catch {
    return unavailable();
  }
}
