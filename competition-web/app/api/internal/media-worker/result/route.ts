import { createHmac, timingSafeEqual } from "node:crypto";
import { z } from "zod";
import { withAppRole } from "@/lib/server/database";
import { privateJson, unavailable } from "@/lib/server/http";

const resultSchema = z.discriminatedUnion("status", [
  z
    .object({
      uploadId: z.string().uuid(),
      status: z.literal("complete"),
      audioKey: z.string().regex(/^[a-f0-9]{32}\/[a-f0-9]{32}\.m4a$/),
      originalSeconds: z.number().finite().positive(),
      audioSeconds: z.number().finite().positive(),
      durationMismatch: z.boolean(),
      attempt: z.number().int().nonnegative(),
    })
    .strict(),
  z
    .object({
      uploadId: z.string().uuid(),
      status: z.literal("failed"),
      errorCode: z.string().regex(/^[a-z0-9_]{1,48}$/),
      attempt: z.number().int().nonnegative(),
    })
    .strict(),
]);

export async function POST(request: Request) {
  const timestamp = request.headers.get("x-ost-worker-timestamp") ?? "";
  const supplied = request.headers.get("x-ost-worker-signature") ?? "";
  if (
    !/^\d{10}$/.test(timestamp) ||
    Math.abs(Date.now() / 1000 - Number(timestamp)) > 300
  )
    return unavailable();
  const declaredLength = Number(request.headers.get("content-length"));
  if (Number.isFinite(declaredLength) && declaredLength > 16_384)
    return unavailable();
  const reader = request.body?.getReader();
  if (!reader) return unavailable();
  const chunks: Uint8Array[] = [];
  let length = 0;
  while (true) {
    const chunk = await reader.read();
    if (chunk.done) break;
    length += chunk.value.length;
    if (length > 16_384) {
      await reader.cancel();
      return unavailable();
    }
    chunks.push(chunk.value);
  }
  const raw = Buffer.concat(chunks.map((chunk) => Buffer.from(chunk)));
  const expected = createHmac(
    "sha256",
    required("MEDIA_WORKER_CALLBACK_SECRET"),
  )
    .update(`${timestamp}.`)
    .update(raw)
    .digest();
  let actual: Buffer;
  try {
    actual = Buffer.from(supplied, "hex");
  } catch {
    return unavailable();
  }
  if (actual.length !== expected.length || !timingSafeEqual(actual, expected))
    return unavailable();

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw.toString("utf8"));
  } catch {
    return unavailable();
  }
  const result = resultSchema.safeParse(parsed);
  if (!result.success) return unavailable();
  const value = result.data;
  try {
    if (value.status === "complete") {
      const { rows } = await withAppRole((db) =>
        db.query(
          "select * from private.media_worker_complete($1,$2,$3,$4,$5,$6)",
          [
            value.uploadId,
            value.audioKey,
            value.originalSeconds,
            value.audioSeconds,
            value.durationMismatch,
            value.attempt,
          ],
        ),
      );
      if (!rows[0]) return unavailable();
      return privateJson({ accepted: true });
    }
    await withAppRole((db) =>
      db.query("select private.media_worker_fail($1,$2,$3)", [
        value.uploadId,
        value.errorCode,
        value.attempt,
      ]),
    );
    return privateJson({ accepted: true });
  } catch {
    return privateJson({ error: "Worker result could not be recorded." }, 503);
  }
}

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error("Media worker configuration is missing.");
  return value;
}
