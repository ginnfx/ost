import { HostAccessDenied, withHost } from "@/lib/server/database";
import { privateJson, sameOriginRequest, unavailable } from "@/lib/server/http";

export async function GET() {
  try {
    const trials = await withHost(async (db) => {
      const { rows } = await db.query(
        "select * from private.host_list_trials()",
      );
      return rows.map((row) => ({
        competitionId: row.competition_id,
        name: row.name,
        status: row.status,
        createdAt: row.created_at,
        submissionDeadline: row.submission_deadline,
        ratingDeadline: row.rating_deadline,
        participantCount: Number(row.participant_count),
      }));
    });
    return privateJson({ trials });
  } catch (error) {
    if (error instanceof HostAccessDenied) return unavailable();
    return unavailable();
  }
}

export async function POST(request: Request) {
  if (!sameOriginRequest(request)) return unavailable();
  try {
    const competitionId = await withHost(async (db) => {
      const { rows } = await db.query<{ host_create_trial: string }>(
        "select private.host_create_trial()",
      );
      return rows[0]?.host_create_trial;
    });
    return privateJson({ competitionId }, 201);
  } catch (error) {
    if (error instanceof HostAccessDenied) return unavailable();
    return privateJson(
      {
        error:
          "A trial round could not be created. Delete or archive the existing trial first.",
      },
      409,
    );
  }
}
