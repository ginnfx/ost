declare module "@/scripts/media-worker.mjs" {
  export type MediaWorkerMetadata = {
    ok: true;
    original_seconds: number;
    audio_seconds: number;
    duration_mismatch: boolean;
    audio_codec: string;
    sample_rate: number;
    channels: number;
  };
  export function processClip(
    inputPath: string,
    outputPath: string,
    normalize?: boolean,
    limits?: {
      maxUploadBytes?: number;
      minClipSeconds?: number;
      maxClipSeconds?: number;
    },
  ): Promise<MediaWorkerMetadata>;
}
