import { z } from "zod";
import { HostAccessDenied, withHost } from "@/lib/server/database";
import { privateJson, sameOriginRequest, unavailable } from "@/lib/server/http";
import { SupabasePrivateObjectStore } from "@/lib/server/storage";

const schema = z
  .object({
    confirmation: z.literal("ARCHIVE VERIFIED"),
    digest: z.string().regex(/^[a-f0-9]{64}$/),
  })
  .strict();

export async function POST(
  request: Request,
  context: { params: Promise<{ competitionId: string }> },
) {
  if (!sameOriginRequest(request)) return unavailable();
  const { competitionId } = await context.params;
  const parsed = schema.safeParse(await request.json().catch(() => null));
  if (!/^[0-9a-f-]{36}$/i.test(competitionId) || !parsed.success)
    return unavailable();
  try {
    const keys = await withHost(async (db) => {
      const { rows } = await db.query<{ storage_key: string }>(
        "select * from private.host_archived_original_keys($1)",
        [competitionId],
      );
      return rows.map((row) => row.storage_key);
    });
    if (!keys.length) return privateJson({ archivedOriginals: 0 });
    await new SupabasePrivateObjectStore().remove(keys);
    await withHost((db) =>
      db.query("select private.host_mark_originals_archived($1,$2)", [
        competitionId,
        Buffer.from(parsed.data.digest, "hex"),
      ]),
    );
    return privateJson({ archivedOriginals: keys.length });
  } catch (error) {
    if (error instanceof HostAccessDenied) return unavailable();
    return privateJson(
      {
        error:
          "Original media could not be removed. The local archive remains available.",
      },
      409,
    );
  }
}
