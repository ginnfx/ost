import "server-only";
import { createClient } from "@supabase/supabase-js";
import { createWriteStream } from "node:fs";
import { readFile } from "node:fs/promises";
import { Readable } from "node:stream";
import { Transform } from "node:stream";
import type { ReadableStream as NodeReadableStream } from "node:stream/web";
import { pipeline } from "node:stream/promises";

export interface PrivateObjectStore {
  signedReadUrl(key: string, expiresInSeconds: number): Promise<string>;
  signedUploadUrl(
    key: string,
    upsert?: boolean,
  ): Promise<{ url: string; token: string }>;
  remove(keys: string[]): Promise<void>;
  resumableEndpoint(): string;
  bucketName(): string;
  downloadToFile(
    key: string,
    destination: string,
    maxBytes: number,
  ): Promise<void>;
  uploadAudio(key: string, source: string): Promise<void>;
}

/** Swap this adapter for R2 without changing competition services. */
export class SupabasePrivateObjectStore implements PrivateObjectStore {
  private readonly client = createClient(
    required("SUPABASE_URL"),
    required("SUPABASE_SERVICE_ROLE_KEY"),
    {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
        detectSessionInUrl: false,
      },
    },
  );
  private readonly bucket = required("SUPABASE_STORAGE_BUCKET");

  resumableEndpoint(): string {
    const url = new URL(required("SUPABASE_URL"));
    if (url.hostname.endsWith(".supabase.co"))
      url.hostname = url.hostname.replace(
        ".supabase.co",
        ".storage.supabase.co",
      );
    url.pathname = "/storage/v1/upload/resumable";
    url.search = "";
    return url.toString();
  }
  bucketName(): string {
    return this.bucket;
  }

  async signedReadUrl(key: string, expiresInSeconds: number): Promise<string> {
    assertOpaqueStorageKey(key);
    const { data, error } = await this.client.storage
      .from(this.bucket)
      .createSignedUrl(key, Math.min(Math.max(expiresInSeconds, 15), 7200));
    if (error || !data?.signedUrl)
      throw new Error("Media could not be made available.");
    return data.signedUrl;
  }
  async signedUploadUrl(
    key: string,
    upsert = false,
  ): Promise<{ url: string; token: string }> {
    assertOpaqueStorageKey(key);
    const { data, error } = await this.client.storage
      .from(this.bucket)
      .createSignedUploadUrl(key, { upsert });
    if (error || !data) throw new Error("Upload could not be started.");
    return { url: data.signedUrl, token: data.token };
  }
  async remove(keys: string[]): Promise<void> {
    if (keys.some((key) => !isOpaqueStorageKey(key)))
      throw new Error("Media could not be removed.");
    const { error } = await this.client.storage.from(this.bucket).remove(keys);
    if (error) throw new Error("Media could not be removed.");
  }

  async downloadToFile(
    key: string,
    destination: string,
    maxBytes: number,
  ): Promise<void> {
    assertOpaqueStorageKey(key);
    const url = await this.signedReadUrl(key, 300);
    const response = await fetch(url, { cache: "no-store", redirect: "error" });
    if (!response.ok || !response.body)
      throw new Error("Media could not be downloaded for processing.");
    const declaredLength = Number(response.headers.get("content-length"));
    if (Number.isFinite(declaredLength) && declaredLength > maxBytes)
      throw new Error("Media file exceeds the configured size limit.");
    let received = 0;
    const limiter = new Transform({
      transform(chunk: Buffer, _encoding, callback) {
        received += chunk.length;
        if (received > maxBytes)
          callback(new Error("Media file exceeds the configured size limit."));
        else callback(null, chunk);
      },
    });
    await pipeline(
      Readable.fromWeb(response.body as unknown as NodeReadableStream),
      limiter,
      createWriteStream(destination, { flags: "wx", mode: 0o600 }),
    );
  }

  async uploadAudio(key: string, source: string): Promise<void> {
    assertOpaqueStorageKey(key);
    const content = await readFile(source);
    const { error } = await this.client.storage
      .from(this.bucket)
      .upload(key, content, {
        contentType: "audio/mp4",
        cacheControl: "0",
        upsert: false,
      });
    if (error) throw new Error("Processed audio could not be stored.");
  }
}

function isOpaqueStorageKey(key: string): boolean {
  return /^[a-f0-9]{32,64}\/(?:[a-f0-9]{32,64})\.(?:mp4|mov|webm|mkv|m4a)$/.test(
    key,
  );
}
function assertOpaqueStorageKey(key: string): void {
  if (!isOpaqueStorageKey(key)) throw new Error("Media is unavailable.");
}
function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error("Server storage configuration is missing.");
  return value;
}
