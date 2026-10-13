export type RoundPhase = 'submissions' | 'waiting' | 'listening' | 'reveals' | 'complete';
export type Entry = { id: string; listeningId: string; label: string; title: string; franchise: string; submitterId: string; duration: number; batch: number; confirmed: boolean; flagged?: string; own?: boolean; opened?: boolean; score: number; ratings: number };
export type Participant = { id: string; name: string; submitted: number; rated: number; finalized: number; withdrawn?: boolean };
export type DemoState = { phase: RoundPhase; role: 'participant' | 'host'; entries: Entry[]; participants: Participant[]; batch: number; ratingByEntry: Record<string, number>; finalized: number[]; revealed: number; published: boolean; passkeyPrompt: boolean; hostTab: string; toast: string; online: boolean; failNextUpload: boolean; mismatchNext: boolean; guide: boolean; audit: string[]; credentials: string[]; recoveryCodes: string[]; recoveryShown: boolean; recoveryConsumed: boolean; reopenedFor: string|null; reopenedBatch: number|null; tourDone: boolean };

/** Stable data boundary shared by the real server adapter and the isolated demo adapter. */
export interface CompetitionData {
  read(): Promise<DemoState>;
  write(state: DemoState): Promise<void>;
  reset(): Promise<DemoState>;
}
