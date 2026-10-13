import { createHash } from "node:crypto";
import { z } from "zod";
import { dispatchMediaTask } from "@/lib/server/media-tasks";
import { withCurrentUser } from "@/lib/server/database";
import { privateJson, sameOriginRequest, unavailable } from "@/lib/server/http";
import { SupabasePrivateObjectStore } from "@/lib/server/storage";
import { sha256 } from "@/lib/server/webauthn";

const schema = z.object({}).strict();

export async function POST(
  request: Request,
  context: { params: Promise<{ uploadId: string }> },
) {
  if (!sameOriginRequest(request)) {
    console.error(
      JSON.stringify({ event: "media_task_rejected", reason: "origin" }),
    );
    return unavailable();
  }
  if (!schema.safeParse(await request.json().catch(() => null)).success) {
    console.error(
      JSON.stringify({ event: "media_task_rejected", reason: "body" }),
    );
    return unavailable();
  }
  const { uploadId } = await context.params;
  if (!/^[0-9a-f-]{36}$/i.test(uploadId)) {
    console.error(
      JSON.stringify({ event: "media_task_rejected", reason: "id" }),
    );
    return unavailable();
  }
  const store = new SupabasePrivateObjectStore();
  try {
    const data = await withCurrentUser(async (db, _userId) => {
      const limit = await db.query<{ allowed: boolean }>(
        "select private.rate_limit_hit($1,$2,$3,$4) as allowed",
        ["upload", sha256(_userId), 30, 3600],
      );
      if (!limit.rows[0]?.allowed) throw new Error("RATE_LIMITED");
      const { rows } = await db.query<{
        upload_id: string;
        storage_key: string;
        min_clip_seconds: string;
        max_clip_seconds: string;
        max_upload_bytes: string;
        normalize_loudness: boolean;
      }>("select * from private.begin_submission_processing($1)", [uploadId]);
      if (!rows[0]) {
        console.error(
          JSON.stringify({
            event: "media_task_rejected",
            reason: "upload_scope",
          }),
        );
        throw new Error("RESOURCE_UNAVAILABLE");
      }
      return rows[0];
    });

    const audioKey = `${createHash("sha256").update(`${uploadId}:audio-folder`).digest("hex").slice(0, 32)}/${createHash("sha256").update(`${uploadId}:audio-file`).digest("hex").slice(0, 32)}.m4a`;
    const [sourceUrl, destination] = await Promise.all([
      store.signedReadUrl(data.storage_key, 7200),
      store.signedUploadUrl(audioKey, true),
    ]);
    const callbackUrl = process.env.NEXT_PUBLIC_SITE_URL
      ? new URL(
          "/api/internal/media-worker/result",
          process.env.NEXT_PUBLIC_SITE_URL,
        ).toString()
      : new URL("/api/internal/media-worker/result", request.url).toString();

    const queued = await withCurrentUser((db) =>
      db.query<{ media_worker_queued: number }>(
        "select private.media_worker_queued($1)",
        [uploadId],
      ),
    );
    const dispatchAttempt =
      Number(queued.rows[0]?.media_worker_queued ?? 1) - 1;
    await dispatchMediaTask({
      uploadId,
      dispatchAttempt,
      sourceUrl,
      destinationUrl: destination.url,
      audioKey,
      normalize: data.normalize_loudness,
      minClipSeconds: Number(data.min_clip_seconds),
      maxClipSeconds: Number(data.max_clip_seconds),
      maxUploadBytes: Number(data.max_upload_bytes),
      callbackUrl,
    });
    return privateJson({ uploadId, status: "processing" }, 202);
  } catch (error) {
    const errorCode =
      error instanceof Error && error.message === "RATE_LIMITED"
        ? "rate_limited"
        : error instanceof Error && error.message === "RESOURCE_UNAVAILABLE"
          ? "resource_unavailable"
          : "task_dispatch_failed";
    console.error(
      JSON.stringify({ event: "media_task_start_failed", reason: errorCode }),
    );
    await withCurrentUser((db) =>
      db.query("select private.media_worker_fail($1,$2,$3)", [
        uploadId,
        errorCode,
        -1,
      ]),
    ).catch(() => undefined);
    if (errorCode === "resource_unavailable") return unavailable();
    if (errorCode === "rate_limited")
      return privateJson(
        { error: "Upload limit reached. Try again later." },
        429,
      );
    return privateJson(
      { error: "Processing could not be queued. Retry this upload." },
      503,
    );
  }
}
