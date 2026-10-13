import { randomBytes } from "node:crypto";
import { z } from "zod";
import { withCurrentUser } from "@/lib/server/database";
import { privateJson, sameOriginRequest, unavailable } from "@/lib/server/http";
import { SupabasePrivateObjectStore } from "@/lib/server/storage";
import { sha256 } from "@/lib/server/webauthn";

const schema = z
  .object({
    franchise: z.string().trim().min(1).max(120),
    anilistId: z
      .number()
      .int()
      .positive()
      .max(Number.MAX_SAFE_INTEGER)
      .nullable(),
    ostTitle: z.string().trim().min(1).max(160),
    bytes: z.number().int().positive().max(524288000),
    durationSeconds: z.number().finite().positive(),
    contentType: z.enum([
      "video/mp4",
      "video/quicktime",
      "video/webm",
      "video/x-matroska",
    ]),
  })
  .strict();

export async function POST(
  request: Request,
  context: { params: Promise<{ competitionId: string; slot: string }> },
) {
  if (!sameOriginRequest(request)) return unavailable();
  const { competitionId, slot: slotText } = await context.params;
  const slot = Number(slotText);
  const parsed = schema.safeParse(await request.json().catch(() => null));
  if (
    !/^[0-9a-f-]{36}$/i.test(competitionId) ||
    !Number.isInteger(slot) ||
    slot < 1 ||
    slot > 5 ||
    !parsed.success
  )
    return privateJson(
      { error: "Check the submission details and selected clip." },
      400,
    );
  const extension =
    parsed.data.contentType === "video/quicktime"
      ? "mov"
      : parsed.data.contentType === "video/webm"
        ? "webm"
        : parsed.data.contentType === "video/x-matroska"
          ? "mkv"
          : "mp4";
  const objectKey = `${randomBytes(16).toString("hex")}/${randomBytes(16).toString("hex")}.${extension}`;
  try {
    const result = await withCurrentUser(async (db, userId, accessToken) => {
      const limit = await db.query<{ allowed: boolean }>(
        "select private.rate_limit_hit($1,$2,$3,$4) as allowed",
        ["upload", sha256(userId), 30, 3600],
      );
      if (!limit.rows[0]?.allowed) throw new Error("RATE_LIMITED");
      const { rows } = await db.query<{
        upload_id: string;
        storage_key: string;
        old_storage_key: string | null;
        max_upload_bytes: string;
        min_clip_seconds: string;
        max_clip_seconds: string;
        normalize_loudness: boolean;
      }>(
        "select * from private.start_submission_upload($1,$2::smallint,$3,$4::bigint,$5,$6::bigint,$7::numeric,$8)",
        [
          competitionId,
          slot,
          parsed.data.franchise,
          parsed.data.anilistId,
          parsed.data.ostTitle,
          parsed.data.bytes,
          parsed.data.durationSeconds,
          objectKey,
        ],
      );
      const info = rows[0];
      if (!info) throw new Error("RESOURCE_UNAVAILABLE");
      return { ...info, userId, accessToken };
    });
    const storage = new SupabasePrivateObjectStore();
    const upload = await storage.signedUploadUrl(result.storage_key);
    if (result.old_storage_key)
      await storage.remove([result.old_storage_key]).catch(() => undefined);
    return privateJson(
      {
        uploadId: result.upload_id,
        key: result.storage_key,
        signature: upload.token,
        accessToken: result.accessToken,
        endpoint: storage.resumableEndpoint(),
        bucketName: storage.bucketName(),
        objectName: result.storage_key,
        contentType: parsed.data.contentType,
        chunkSize: 6 * 1024 * 1024,
        maxUploadBytes: Number(result.max_upload_bytes),
        minClipSeconds: Number(result.min_clip_seconds),
        maxClipSeconds: Number(result.max_clip_seconds),
        normalizeLoudness: result.normalize_loudness,
      },
      201,
    );
  } catch (error) {
    if (error instanceof Error && error.message === "RATE_LIMITED")
      return privateJson(
        { error: "Upload limit reached. Try again later." },
        429,
      );
    if (error instanceof Error && error.message === "RESOURCE_UNAVAILABLE")
      return unavailable();
    return privateJson(
      {
        error:
          "Upload could not be started. Check the round status and file limits.",
      },
      400,
    );
  }
}
