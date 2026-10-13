import { z } from "zod";
import { HostAccessDenied, withHost } from "@/lib/server/database";
import { privateJson, sameOriginRequest, unavailable } from "@/lib/server/http";

const schema = z
  .object({
    sourceId: z.string().uuid(),
    name: z.string().trim().min(1).max(120),
    payload: z
      .object({
        osts: z.array(z.record(z.string(), z.unknown())).max(500),
        ratings: z.array(z.record(z.string(), z.unknown())).max(10000),
        settings: z.array(z.record(z.string(), z.unknown())).max(100),
      })
      .strict(),
  })
  .strict();

export async function POST(request: Request) {
  if (!sameOriginRequest(request)) return unavailable();
  const parsed = schema.safeParse(await request.json().catch(() => null));
  if (!parsed.success || JSON.stringify(parsed.data.payload).length > 5_000_000)
    return unavailable();
  try {
    const imported = await withHost(async (db) => {
      const { rows } = await db.query<{ host_import_legacy_round: boolean }>(
        "select private.host_import_legacy_round($1,$2,$3::jsonb)",
        [
          parsed.data.sourceId,
          parsed.data.name,
          JSON.stringify(parsed.data.payload),
        ],
      );
      return rows[0]?.host_import_legacy_round === true;
    });
    return privateJson({ imported });
  } catch (error) {
    if (error instanceof HostAccessDenied) return unavailable();
    return unavailable();
  }
}
