import { z } from "zod";
import { SafeDatabaseError, withCurrentUser } from "@/lib/server/database";
import { privateJson, sameOriginRequest, unavailable } from "@/lib/server/http";
import { sha256 } from "@/lib/server/webauthn";

const schema = z.object({ query: z.string().trim().min(2).max(80) }).strict();
type Result = {
  id: number;
  title: { english: string | null; romaji: string; native: string | null };
};

export async function POST(request: Request) {
  if (!sameOriginRequest(request)) return unavailable();
  const parsed = schema.safeParse(await request.json().catch(() => null));
  if (!parsed.success) return privateJson({ results: [] });
  try {
    const allowed = await withCurrentUser(async (db, userId) => {
      const result = await db.query<{ allowed: boolean }>(
        "select private.rate_limit_hit($1,$2,$3,$4) as allowed",
        ["search", sha256(userId), 40, 3600],
      );
      return result.rows[0]?.allowed === true;
    });
    if (!allowed) throw new SafeDatabaseError("RATE_LIMITED");
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 6000);
    try {
      const response = await fetch("https://graphql.anilist.co", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          accept: "application/json",
        },
        body: JSON.stringify({
          query:
            "query($search:String){Page(perPage:8){media(search:$search,type:ANIME){id title{english romaji native}}}}",
          variables: { search: parsed.data.query },
        }),
        signal: controller.signal,
        cache: "no-store",
      });
      if (!response.ok) return privateJson({ results: [] });
      const data = (await response.json()) as {
        data?: { Page?: { media?: Result[] } };
      };
      return privateJson({
        results: (data.data?.Page?.media ?? []).map((item) => ({
          id: item.id,
          title:
            item.title.english ||
            item.title.romaji ||
            item.title.native ||
            "Anime",
        })),
      });
    } finally {
      clearTimeout(timeout);
    }
  } catch (error) {
    if (error instanceof SafeDatabaseError)
      return privateJson({ results: [] }, 429);
    return privateJson({ results: [] }, 503);
  }
}
