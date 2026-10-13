import { createHash } from "node:crypto";

export type ScoringInput = {
  seed: string;
  batchCount: number;
  revealGroupCount: number;
  participants: Array<{
    id: string;
    withdrawn: boolean;
    finalizedBatches: number[];
  }>;
  entries: Array<{ id: string; ownerId: string }>;
  ratings: Array<{ raterId: string; entryId: string; score: number }>;
};
export type ScoredEntry = {
  id: string;
  sum: number;
  count: number;
  mean: string;
  tens: number;
  medianTwice: number;
  varianceNumerator: string;
  varianceDenominator: string;
  rank: number;
  revealGroup: number;
};

/** Integer-only authoritative ranking calculation; display decimals are derived after ordering. */
export function scoreCompetition(input: ScoringInput): {
  ranked: ScoredEntry[];
  revealGroups: Array<{ number: number; entryIds: string[] }>;
  excludedRaters: string[];
} {
  if (
    !input.seed ||
    !Number.isInteger(input.batchCount) ||
    input.batchCount < 1 ||
    !Number.isInteger(input.revealGroupCount) ||
    input.revealGroupCount < 1
  )
    throw new Error("Invalid scoring configuration.");
  const participants = new Map(input.participants.map((p) => [p.id, p]));
  const excludedRaters = input.participants
    .filter(
      (p) =>
        p.withdrawn ||
        new Set(p.finalizedBatches).size !== input.batchCount ||
        Array.from({ length: input.batchCount }, (_, i) => i + 1).some(
          (n) => !p.finalizedBatches.includes(n),
        ),
    )
    .map((p) => p.id)
    .sort();
  const excluded = new Set(excludedRaters);
  const entries = new Map(input.entries.map((e) => [e.id, e]));
  const byEntry = new Map<string, Map<string, number>>();
  for (const rating of input.ratings) {
    if (
      !Number.isInteger(rating.score) ||
      rating.score < 1 ||
      rating.score > 10
    )
      throw new Error("Ratings must be whole numbers from 1 to 10.");
    if (!participants.has(rating.raterId) || !entries.has(rating.entryId))
      throw new Error("A rating refers to an unknown record.");
    if (excluded.has(rating.raterId)) continue;
    const ratings = byEntry.get(rating.entryId) ?? new Map<string, number>();
    if (ratings.has(rating.raterId))
      throw new Error("Only one rating per rater and entry is allowed.");
    ratings.set(rating.raterId, rating.score);
    byEntry.set(rating.entryId, ratings);
  }
  const raw = input.entries.map((entry) => {
    const values = byEntry.get(entry.id) ?? new Map<string, number>();
    // Every participant's own soundtrack always receives a recorded score of ten.
    if (participants.has(entry.ownerId) && !excluded.has(entry.ownerId))
      values.set(entry.ownerId, 10);
    const scores = [...values.values()].sort((a, b) => a - b);
    const sum = scores.reduce((a, b) => a + b, 0),
      count = scores.length,
      tens = scores.filter((s) => s === 10).length;
    const medianTwice =
      count === 0
        ? 0
        : count % 2
          ? scores[(count - 1) / 2] * 2
          : scores[count / 2 - 1] + scores[count / 2];
    const sumSquares = scores.reduce((a, b) => a + b * b, 0);
    return {
      id: entry.id,
      sum,
      count,
      tens,
      medianTwice,
      varianceNumerator: BigInt(count * sumSquares - sum * sum),
      varianceDenominator: BigInt(Math.max(1, count) ** 2),
    };
  });
  const seedOrder = (id: string) =>
    createHash("sha256").update(`${input.seed}:${id}`).digest("hex");
  const compareMean = (a: (typeof raw)[number], b: (typeof raw)[number]) =>
    BigInt(a.sum) * BigInt(b.count || 1) - BigInt(b.sum) * BigInt(a.count || 1);
  const compareScore = (a: (typeof raw)[number], b: (typeof raw)[number]) => {
    const mean = compareMean(a, b);
    if (mean !== 0n) return mean > 0n ? -1 : 1;
    if (a.tens !== b.tens) return b.tens - a.tens;
    if (a.medianTwice !== b.medianTwice) return b.medianTwice - a.medianTwice;
    const deviation =
      a.varianceNumerator * b.varianceDenominator -
      b.varianceNumerator * a.varianceDenominator;
    if (deviation !== 0n) return deviation < 0n ? -1 : 1;
    return seedOrder(a.id).localeCompare(seedOrder(b.id));
  };
  const ordered = [...raw].sort(compareScore);
  const revealOrder = [...ordered].reverse();
  const revealGroups: Array<{ number: number; entryIds: string[] }> = [];
  let start = 0;
  for (
    let group = 1;
    group <= input.revealGroupCount && start < revealOrder.length;
    group++
  ) {
    const targetEnd =
      group === input.revealGroupCount
        ? revealOrder.length
        : Math.round((revealOrder.length * group) / input.revealGroupCount);
    let end = targetEnd;
    while (
      end > start &&
      end < revealOrder.length &&
      compareMean(revealOrder[end - 1], revealOrder[end]) === 0n
    )
      end--;
    if (end <= start) continue;
    revealGroups.push({
      number: group,
      entryIds: revealOrder.slice(start, end).map((e) => e.id),
    });
    start = end;
  }
  if (start < revealOrder.length) {
    const last = revealGroups.at(-1);
    if (last) last.entryIds.push(...revealOrder.slice(start).map((e) => e.id));
    else
      revealGroups.push({
        number: input.revealGroupCount,
        entryIds: revealOrder.slice(start).map((e) => e.id),
      });
  }
  const groupByEntry = new Map(
    revealGroups.flatMap((group) =>
      group.entryIds.map((id) => [id, group.number] as const),
    ),
  );
  const ranked = ordered.map((entry, index) => ({
    id: entry.id,
    sum: entry.sum,
    count: entry.count,
    mean: formatMean(entry.sum, entry.count),
    tens: entry.tens,
    medianTwice: entry.medianTwice,
    varianceNumerator: entry.varianceNumerator.toString(),
    varianceDenominator: entry.varianceDenominator.toString(),
    rank: index + 1,
    revealGroup: groupByEntry.get(entry.id) ?? input.revealGroupCount,
  }));
  return { ranked, revealGroups, excludedRaters };
}

function formatMean(sum: number, count: number): string {
  if (count === 0) return "0.00";
  const hundredths = Math.floor((sum * 100 + Math.floor(count / 2)) / count);
  return `${Math.floor(hundredths / 100)}.${String(hundredths % 100).padStart(2, "0")}`;
}
