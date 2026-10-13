import { z } from "zod";
import { HostAccessDenied, withHost } from "@/lib/server/database";
import { supabaseAdmin } from "@/lib/server/admin-auth";
import { privateJson, sameOriginRequest, unavailable } from "@/lib/server/http";
import { SupabasePrivateObjectStore } from "@/lib/server/storage";

const schema = z.object({ confirmation: z.literal("DELETE TRIAL") }).strict();

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
    const { keys, unusedUsers } = await withHost(async (db) => {
      const media = await db.query<{ storage_key: string }>(
        "select * from private.host_trial_media_keys($1)",
        [competitionId],
      );
      const users = await db.query<{ user_id: string }>(
        "select * from private.host_trial_unused_invite_users($1)",
        [competitionId],
      );
      return {
        keys: media.rows.map((row) => row.storage_key),
        unusedUsers: users.rows.map((row) => row.user_id),
      };
    });
    const admin = supabaseAdmin();
    for (const userId of unusedUsers) {
      const result = await admin.auth.admin.deleteUser(userId);
      if (result.error) throw new Error("TRIAL_CLEANUP_FAILED");
    }
    if (keys.length) await new SupabasePrivateObjectStore().remove(keys);
    await withHost((db) =>
      db.query("select private.host_delete_trial($1)", [competitionId]),
    );
    return privateJson({ deleted: true });
  } catch (error) {
    if (error instanceof HostAccessDenied) return unavailable();
    return privateJson(
      {
        error:
          "Trial data could not be fully deleted. Retry cleanup or check Storage.",
      },
      409,
    );
  }
}
