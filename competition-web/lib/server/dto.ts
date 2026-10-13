/** Participant-safe shapes. Never return raw submission, participant, or rating rows. */
export type ParticipantEntryDTO = {
  listeningId: string;
  label: string;
  durationSeconds: number;
  audioUrl: string;
  own: boolean;
  automaticScore?: 10;
};
export type ParticipantBatchDTO = {
  number: number;
  releasedAt: string;
  entries: ParticipantEntryDTO[];
  finalized: boolean;
};
export type ParticipantResultDTO = {
  listeningId: string;
  label: string;
  rank: number;
  meanScore: string;
  ratingCount: number;
  group: number;
  publishedAt: string;
};
export type ParticipantRoundDTO = {
  name: string;
  status:
    | "submissions_open"
    | "submissions_locked"
    | "listening"
    | "rating_closed"
    | "scored"
    | "revealing"
    | "complete"
    | "archived";
  deadline: string | null;
  participant: {
    nickname: string;
    submittedCount: number;
    finalizedBatches: number;
  };
  batches: ParticipantBatchDTO[];
  publishedResults: ParticipantResultDTO[];
};

export function notFoundShape<T extends object>(value: T | null): T {
  if (!value) throw new Error("RESOURCE_UNAVAILABLE");
  return value;
}
