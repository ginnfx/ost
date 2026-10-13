import { randomBytes } from "node:crypto";
import { mkdtemp, mkdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { z } from "zod";
import { processClip } from "@/scripts/media-worker.mjs";
import { withCurrentUser } from "@/lib/server/database";
import { privateJson, sameOriginRequest, unavailable } from "@/lib/server/http";
import { SupabasePrivateObjectStore } from "@/lib/server/storage";

const schema = z.object({}).strict();

export async function POST(
  request: Request,
  context: { params: Promise<{ uploadId: string }> },
) {
  if (!sameOriginRequest(request)) return unavailable();
  if (!schema.safeParse(await request.json().catch(() => null)).success)
    return unavailable();
  const { uploadId } = await context.params;
  if (!/^[0-9a-f-]{36}$/i.test(uploadId)) return unavailable();
  const root = process.env.MEDIA_WORKER_TEMP_DIR ?? tmpdir();
  let work = "";
  let audioKey = "";
  let audioUploaded = false;
  const store = new SupabasePrivateObjectStore();
  try {
    const contextData = await withCurrentUser(async (db) => {
      const { rows } = await db.query<{
        upload_id: string;
        storage_key: string;
        upload_bytes: string;
        min_clip_seconds: string;
        max_clip_seconds: string;
        max_upload_bytes: string;
        normalize_loudness: boolean;
      }>("select * from private.begin_submission_processing($1)", [uploadId]);
      if (!rows[0]) throw new Error("RESOURCE_UNAVAILABLE");
      return rows[0];
    });
    await mkdir(root, { recursive: true });
    work = await mkdtemp(join(root, "ost-web-process-"));
    const source = join(work, "original.video");
    const output = join(work, "processed.m4a");
    await store.downloadToFile(
      contextData.storage_key,
      source,
      Number(contextData.max_upload_bytes),
    );
    const metadata = await processClip(
      source,
      output,
      contextData.normalize_loudness,
      {
        maxUploadBytes: Number(contextData.max_upload_bytes),
        minClipSeconds: Number(contextData.min_clip_seconds),
        maxClipSeconds: Number(contextData.max_clip_seconds),
      },
    );
    audioKey = `${randomBytes(16).toString("hex")}/${randomBytes(16).toString("hex")}.m4a`;
    await store.uploadAudio(audioKey, output);
    audioUploaded = true;
    const finished = await withCurrentUser(async (db) => {
      const { rows } = await db.query<{
        submission_id: string;
        status: string;
        old_original_key: string | null;
        old_audio_key: string | null;
      }>("select * from private.finish_submission_processing($1,$2,$3,$4,$5)", [
        uploadId,
        audioKey,
        metadata.original_seconds,
        metadata.audio_seconds,
        metadata.duration_mismatch,
      ]);
      if (!rows[0]) throw new Error("RESOURCE_UNAVAILABLE");
      return rows[0];
    });
    await store
      .remove(
        [finished.old_original_key, finished.old_audio_key].filter(
          (key): key is string =>
            !!key && key !== contextData.storage_key && key !== audioKey,
        ),
      )
      .catch(() => undefined);
    return privateJson({
      submissionId: finished.submission_id,
      status: finished.status,
      durationMismatch: metadata.duration_mismatch,
    });
  } catch (error) {
    if (audioUploaded && audioKey)
      await store.remove([audioKey]).catch(() => undefined);
    const code =
      error instanceof Error &&
      error.message.startsWith("Media processing rejected:")
        ? error.message
            .slice("Media processing rejected: ".length)
            .replace(/\.$/, "")
        : "processing_failed";
    await withCurrentUser((db) =>
      db.query("select private.fail_submission_processing($1,$2)", [
        uploadId,
        code,
      ]),
    ).catch(() => undefined);
    if (error instanceof Error && error.message === "RESOURCE_UNAVAILABLE")
      return unavailable();
    return privateJson(
      {
        error:
          "This video could not be processed. Check its format, audio track, size and duration.",
      },
      422,
    );
  } finally {
    if (work)
      await rm(work, { recursive: true, force: true }).catch(() => undefined);
  }
}
