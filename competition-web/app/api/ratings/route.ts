import { z } from "zod";
import { withCurrentUser } from "@/lib/server/database";
import { privateJson, sameOriginRequest, unavailable } from "@/lib/server/http";
import { sha256 } from "@/lib/server/webauthn";

const bodySchema = z
  .object({
    competitionId: z.string().uuid(),
    batch: z.number().int().positive().max(20),
    listeningId: z.string().uuid(),
    score: z.number().int().min(1).max(10),
    expectedVersion: z.number().int().nonnegative(),
  })
  .strict();

export async function PUT(request: Request) {
  if (!sameOriginRequest(request)) return unavailable();
  const body = bodySchema.safeParse(await request.json().catch(() => null));
  if (!body.success)
    return privateJson({ error: "Choose a rating from 1 to 10." }, 400);
  try {
    const version = await withCurrentUser(async (db, userId) => {
      const limit = await db.query<{ allowed: boolean }>(
        "select private.rate_limit_hit($1,$2,$3,$4) as allowed",
        ["rating", sha256(userId), 1200, 3600],
      );
      if (!limit.rows[0]?.allowed) throw new Error("RATE_LIMITED");
      const result = await db.query<{ save_listening_rating: string }>(
        "select private.save_listening_rating($1,$2::smallint,$3,$4::smallint,$5::bigint)",
        [
          body.data.competitionId,
          body.data.batch,
          body.data.listeningId,
          body.data.score,
          body.data.expectedVersion,
        ],
      );
      return Number(result.rows[0]?.save_listening_rating);
    });
    return privateJson({ saved: true, version });
  } catch (error) {
    if (error instanceof Error && error.message === "RATE_LIMITED")
      return privateJson(
        { error: "Rating limit reached. Try again later." },
        429,
      );
    if (error instanceof Error && error.message.includes("Stale rating"))
      return privateJson(
        { error: "This rating changed elsewhere. Refresh to sync." },
        409,
      );
    return unavailable();
  }
}
