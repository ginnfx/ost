"use client";

import { Upload } from "tus-js-client";
import { useCallback, useEffect, useRef, useState } from "react";

type Policy = {
  maxUploadBytes: number;
  minClipSeconds: number;
  maxClipSeconds: number;
  entriesPerParticipant: number;
};
type Submission = {
  submissionId: string;
  slot: number;
  franchise: string;
  aniListId: number | null;
  ostTitle: string;
  status: string;
  durationMismatch: boolean;
  version: number;
};
type SlotForm = {
  franchise: string;
  anilistId: string;
  ostTitle: string;
  file?: File;
  duration?: number;
};
type UploadDetails = {
  uploadId: string;
  signature: string;
  accessToken: string;
  endpoint: string;
  bucketName: string;
  objectName: string;
  contentType: string;
  chunkSize: number;
};
type ActiveUpload = { uploader: Upload; info: UploadDetails };
type AnimeResult = { id: number; title: string };
const suffix = (name: string) => name.split(".").at(-1)?.toLowerCase() ?? "";

async function inspectFile(file: File, policy: Policy): Promise<number> {
  const ext = suffix(file.name);
  if (!["mp4", "mov", "webm", "mkv"].includes(ext))
    throw new Error("Choose an MP4, MOV, WebM or MKV video.");
  if (file.size < 1 || file.size > policy.maxUploadBytes)
    throw new Error("This file is larger than the round limit.");
  const url = URL.createObjectURL(file);
  try {
    return await new Promise((resolve, reject) => {
      const video = document.createElement("video");
      video.preload = "metadata";
      video.onloadedmetadata = () => {
        const duration = video.duration;
        video.src = "";
        if (
          !Number.isFinite(duration) ||
          duration < policy.minClipSeconds ||
          duration > policy.maxClipSeconds
        )
          reject(
            new Error(
              `Choose a clip between ${policy.minClipSeconds} and ${policy.maxClipSeconds} seconds.`,
            ),
          );
        else resolve(duration);
      };
      video.onerror = () =>
        reject(new Error("This video could not be read in the browser."));
      video.src = url;
    });
  } finally {
    URL.revokeObjectURL(url);
  }
}

export function SubmissionWorkspace({
  competitionId,
  policy,
  initialSubmissions,
}: {
  competitionId: string;
  policy: Policy;
  initialSubmissions: Submission[];
}) {
  const [submissions, setSubmissions] = useState(initialSubmissions);
  const [forms, setForms] = useState<Record<number, SlotForm>>({});
  const [messages, setMessages] = useState<Record<number, string>>({});
  const [progress, setProgress] = useState<Record<number, number>>({});
  const [busy, setBusy] = useState<Record<number, boolean>>({});
  const [previews, setPreviews] = useState<Record<number, string>>({});
  const activeUploads = useRef(new Map<number, ActiveUpload>());
  const searchTimers = useRef(new Map<number, ReturnType<typeof setTimeout>>());
  const [animeResults, setAnimeResults] = useState<
    Record<number, AnimeResult[]>
  >({});

  const reload = useCallback(async () => {
    const response = await fetch(
      `/api/competitions/${competitionId}/submissions`,
      { cache: "no-store" },
    );
    if (response.ok) setSubmissions((await response.json()).submissions);
  }, [competitionId]);

  useEffect(() => {
    void reload();
  }, [reload]);

  function update(
    slot: number,
    key: keyof SlotForm,
    value: string | File | number | undefined,
  ) {
    setForms((current) => ({
      ...current,
      [slot]: {
        ...(current[slot] ?? { franchise: "", anilistId: "", ostTitle: "" }),
        [key]: value,
      },
    }));
  }
  function existing(slot: number) {
    return submissions.find((submission) => submission.slot === slot);
  }

  function searchFranchise(slot: number, value: string) {
    update(slot, "franchise", value);
    update(slot, "anilistId", "");
    setAnimeResults((current) => ({ ...current, [slot]: [] }));
    const previous = searchTimers.current.get(slot);
    if (previous) clearTimeout(previous);
    if (value.trim().length < 2) return;
    searchTimers.current.set(
      slot,
      setTimeout(() => {
        void fetch("/api/anime/search", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ query: value.trim() }),
          cache: "no-store",
        })
          .then(async (response) =>
            response.ok
              ? ((await response.json()).results as AnimeResult[])
              : [],
          )
          .then((results) =>
            setAnimeResults((current) => ({ ...current, [slot]: results })),
          )
          .catch(() =>
            setAnimeResults((current) => ({ ...current, [slot]: [] })),
          );
      }, 350),
    );
  }

  async function submit(slot: number) {
    const form = forms[slot];
    if (!form?.file || !form.duration || busy[slot]) return;
    setBusy((state) => ({ ...state, [slot]: true }));
    setMessages((state) => ({ ...state, [slot]: "Preparing secure upload…" }));
    setProgress((state) => ({ ...state, [slot]: 0 }));
    try {
      let active = activeUploads.current.get(slot);
      if (!active) {
        const start = await fetch(
          `/api/competitions/${competitionId}/submissions/${slot}/upload`,
          {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
              franchise: form.franchise,
              anilistId: form.anilistId ? Number(form.anilistId) : null,
              ostTitle: form.ostTitle,
              bytes: form.file.size,
              durationSeconds: form.duration,
              contentType: contentType(form.file),
            }),
            cache: "no-store",
          },
        );
        const result = await start.json();
        if (!start.ok)
          throw new Error(result.error || "Upload could not be started.");
        const info = result as UploadDetails;
        const memory = new Map<
          string,
          {
            size: number;
            metadata: Record<string, string>;
            creationTime: string;
            urlStorageKey: string;
            uploadUrl: string | null;
            parallelUploadUrls: string[] | null;
          }
        >();
        const urlStorage = {
          findAllUploads: async () => [...memory.values()],
          findUploadsByFingerprint: async (fingerprint: string) =>
            [...memory.entries()]
              .filter(([key]) => key === fingerprint)
              .map(([, value]) => value),
          removeUpload: async (key: string) => {
            memory.delete(key);
          },
          addUpload: async (
            fingerprint: string,
            upload: {
              size: number;
              metadata: Record<string, string>;
              creationTime: string;
              urlStorageKey: string;
              uploadUrl: string | null;
              parallelUploadUrls: string[] | null;
            },
          ) => {
            memory.set(fingerprint, upload);
            return fingerprint;
          },
        };
        const uploader = new Upload(form.file, {
          endpoint: info.endpoint,
          headers: {
            authorization: `Bearer ${info.accessToken}`,
            "x-signature": info.signature,
            "x-upsert": "false",
          },
          metadata: {
            bucketName: info.bucketName,
            objectName: info.objectName,
            contentType: result.contentType,
            cacheControl: "0",
          },
          chunkSize: info.chunkSize,
          retryDelays: [0, 3000, 5000, 10000, 20000],
          uploadDataDuringCreation: true,
          removeFingerprintOnSuccess: true,
          storeFingerprintForResuming: true,
          fingerprint: async (file) =>
            `${info.objectName}:${file.name}:${file.size}:${file.lastModified}`,
          urlStorage,
          onProgress: (sent, total) =>
            setProgress((state) => ({
              ...state,
              [slot]: total ? Math.round((sent / total) * 100) : 0,
            })),
        });
        active = { uploader, info };
        activeUploads.current.set(slot, active);
      }
      setMessages((state) => ({ ...state, [slot]: "Uploading video…" }));
      await new Promise<void>((resolve, reject) => {
        active!.uploader.options.onError = () =>
          reject(
            new Error("Upload paused or failed. Retry in this tab to resume."),
          );
        active!.uploader.options.onSuccess = () => resolve();
        active!.uploader.start();
      });
      const info = active.info;
      activeUploads.current.delete(slot);
      setMessages((state) => ({ ...state, [slot]: "Processing audio…" }));
      const processResponse = await fetch(
        `/api/submission-uploads/${info.uploadId}/process`,
        {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: "{}",
          cache: "no-store",
        },
      );
      const processed = await processResponse.json();
      if (!processResponse.ok)
        throw new Error(processed.error || "Audio processing failed.");
      let processing = true;
      let completed: { status?: string; errorCode?: string } = {};
      const deadline = Date.now() + 6 * 60 * 1000;
      while (processing && Date.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, 1500));
        const statusResponse = await fetch(
          `/api/submission-uploads/${info.uploadId}`,
          { cache: "no-store" },
        );
        if (!statusResponse.ok)
          throw new Error(
            "Processing status could not be loaded. Refresh to check again.",
          );
        completed = await statusResponse.json();
        processing =
          completed.status === "processing" || completed.status === "uploading";
        if (processing)
          setMessages((state) => ({
            ...state,
            [slot]: "Processing audio… This can take a minute.",
          }));
      }
      if (processing)
        throw new Error(
          "Processing is taking longer than expected. Refresh this page to check again.",
        );
      if (completed.status === "failed")
        throw new Error(
          "This video could not be processed. Check its format, audio track, size and duration, then retry.",
        );
      setMessages((state) => ({
        ...state,
        [slot]:
          completed.status === "needs_review"
            ? "Audio is waiting for a private host review."
            : "Audio is ready. Preview it, then confirm your entry.",
      }));
      await reload();
    } catch (error) {
      setMessages((state) => ({
        ...state,
        [slot]:
          error instanceof Error
            ? error.message
            : "Submission failed. Try again.",
      }));
    } finally {
      setBusy((state) => ({ ...state, [slot]: false }));
    }
  }

  async function chooseFile(slot: number, file?: File) {
    const active = activeUploads.current.get(slot);
    if (active) {
      await active.uploader.abort(true).catch(() => undefined);
      activeUploads.current.delete(slot);
    }
    update(slot, "file", undefined);
    update(slot, "duration", undefined);
    if (!file) return;
    setMessages((state) => ({
      ...state,
      [slot]: "Checking video size and duration…",
    }));
    try {
      const duration = await inspectFile(file, policy);
      update(slot, "file", file);
      update(slot, "duration", duration);
      setMessages((state) => ({
        ...state,
        [slot]: `${Math.round(duration)} seconds · ${(file.size / 1024 / 1024).toFixed(1)} MB`,
      }));
    } catch (error) {
      setMessages((state) => ({
        ...state,
        [slot]:
          error instanceof Error ? error.message : "This file cannot be used.",
      }));
    }
  }

  async function preview(item: Submission) {
    const response = await fetch(
      `/api/submissions/${item.submissionId}/preview`,
      { cache: "no-store" },
    );
    if (!response.ok) {
      setMessages((state) => ({
        ...state,
        [item.slot]: "Processed audio is not ready yet.",
      }));
      return;
    }
    const result = await response.json();
    setPreviews((state) => ({
      ...state,
      [item.slot]: result.url,
    }));
  }

  async function confirm(item: Submission) {
    const response = await fetch(
      `/api/submissions/${item.submissionId}/confirm`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: "{}",
      },
    );
    if (!response.ok) {
      setMessages((state) => ({
        ...state,
        [item.slot]: "Entry could not be confirmed. Refresh and try again.",
      }));
      return;
    }
    setPreviews((state) => {
      const next = { ...state };
      delete next[item.slot];
      return next;
    });
    await reload();
    setMessages((state) => ({ ...state, [item.slot]: "Entry confirmed." }));
  }

  return (
    <div className="submission-workspace">
      <p className="muted-small">
        The browser checks the size and duration before uploading. An upload can
        resume while this tab stays open. Replacing an entry keeps the previous
        confirmed entry until the new audio is processed.
      </p>
      {Array.from({ length: policy.entriesPerParticipant }, (_, index) => {
        const slot = index + 1;
        const item = existing(slot);
        const canReplace =
          !item ||
          ["awaiting_confirmation", "confirmed", "rejected"].includes(
            item.status,
          );
        const form = forms[slot] ?? {
          franchise: "",
          anilistId: "",
          ostTitle: "",
        };
        return (
          <article className="submission-slot" key={slot}>
            <div className="submission-slot-heading">
              <h2>Entry {slot}</h2>
              <span>
                {item?.status.replaceAll("_", " ") ?? "not submitted"}
              </span>
            </div>
            {item && (
              <div className="submission-existing">
                <strong>{item.ostTitle}</strong>
                <p>{item.franchise}</p>
                {item.status === "needs_review" && (
                  <p role="status">
                    This clip needs private host review for duration mismatch.
                  </p>
                )}
                {(item.status === "awaiting_confirmation" ||
                  item.status === "confirmed") && (
                  <button
                    className="button secondary"
                    onClick={() => void preview(item)}
                  >
                    Preview processed audio
                  </button>
                )}
                {previews[slot] && (
                  // Anonymous OST audio is intentionally not accompanied by lyrics or transcript.
                  // eslint-disable-next-line jsx-a11y/media-has-caption
                  <audio
                    controls
                    preload="none"
                    src={previews[slot]}
                    onError={() => void preview(item)}
                  />
                )}
                {item.status === "awaiting_confirmation" && (
                  <button
                    className="button primary"
                    onClick={() => void confirm(item)}
                  >
                    Confirm entry {slot}
                  </button>
                )}
                {item.status === "confirmed" && (
                  <p className="muted-small">
                    Confirmed. You can replace it until the host locks
                    submissions.
                  </p>
                )}
              </div>
            )}
            {canReplace && (
              <form
                className="submission-form"
                onSubmit={(event) => {
                  event.preventDefault();
                  void submit(slot);
                }}
              >
                <label htmlFor={`franchise-${slot}`}>Anime or franchise</label>
                <input
                  id={`franchise-${slot}`}
                  required
                  maxLength={120}
                  autoComplete="off"
                  value={form.franchise}
                  onChange={(event) =>
                    searchFranchise(slot, event.target.value)
                  }
                />
                {animeResults[slot]?.length ? (
                  <div
                    className="anime-suggestions"
                    role="listbox"
                    aria-label={`AniList results for entry ${slot}`}
                  >
                    {animeResults[slot].map((result) => (
                      <button
                        type="button"
                        role="option"
                        aria-selected="false"
                        key={result.id}
                        onClick={() => {
                          update(slot, "franchise", result.title);
                          update(slot, "anilistId", String(result.id));
                          setAnimeResults((current) => ({
                            ...current,
                            [slot]: [],
                          }));
                        }}
                      >
                        {result.title}
                      </button>
                    ))}
                  </div>
                ) : null}
                <label htmlFor={`anilist-${slot}`}>
                  AniList ID <span className="muted-small">optional</span>
                </label>
                <input
                  id={`anilist-${slot}`}
                  type="number"
                  min="1"
                  value={form.anilistId}
                  onChange={(event) =>
                    update(slot, "anilistId", event.target.value)
                  }
                />
                <label htmlFor={`title-${slot}`}>OST title</label>
                <input
                  id={`title-${slot}`}
                  required
                  maxLength={160}
                  value={form.ostTitle}
                  onChange={(event) =>
                    update(slot, "ostTitle", event.target.value)
                  }
                />
                <label htmlFor={`file-${slot}`}>Video clip</label>
                <input
                  id={`file-${slot}`}
                  type="file"
                  accept=".mp4,.mov,.webm,.mkv,video/mp4,video/quicktime,video/webm,video/x-matroska"
                  onChange={(event) =>
                    void chooseFile(slot, event.target.files?.[0])
                  }
                />
                {busy[slot] && (
                  <progress
                    max={100}
                    value={progress[slot] ?? 0}
                    aria-label={`Entry ${slot} upload progress`}
                  />
                )}
                <button
                  className="button primary"
                  disabled={
                    busy[slot] ||
                    !form.file ||
                    !form.franchise.trim() ||
                    !form.ostTitle.trim()
                  }
                >
                  {busy[slot]
                    ? "Uploading or processing…"
                    : item
                      ? `Replace entry ${slot}`
                      : `Upload entry ${slot}`}
                </button>
              </form>
            )}
            <p role="status" aria-live="polite">
              {messages[slot] ??
                (item?.status === "needs_review"
                  ? "Waiting for host review."
                  : "")}
            </p>
          </article>
        );
      })}
    </div>
  );
}

function contentType(file: File): string {
  if (
    ["video/mp4", "video/quicktime", "video/webm", "video/x-matroska"].includes(
      file.type,
    )
  )
    return file.type;
  return (
    (
      {
        mp4: "video/mp4",
        mov: "video/quicktime",
        webm: "video/webm",
        mkv: "video/x-matroska",
      } as Record<string, string>
    )[suffix(file.name)] ?? "video/mp4"
  );
}
