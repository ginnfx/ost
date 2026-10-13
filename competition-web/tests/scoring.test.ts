import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { scoreCompetition, type ScoringInput } from "../lib/scoring";

const fixtures = (
  JSON.parse(
    readFileSync(
      resolve(import.meta.dirname, "../fixtures/scoring.json"),
      "utf8",
    ),
  ) as {
    cases: Array<{
      name: string;
      input: ScoringInput;
      expected: {
        excludedRaters: string[];
        ranked: string[];
        revealGroups: string[];
      };
    }>;
  }
).cases;

describe("authoritative scoring fixtures", () => {
  for (const fixture of fixtures) {
    it(fixture.name, () => {
      const result = scoreCompetition(fixture.input);
      expect(result.excludedRaters).toEqual(fixture.expected.excludedRaters);
      expect(result.ranked.map((entry) => entry.id)).toEqual(
        fixture.expected.ranked,
      );
      expect(result.revealGroups.flatMap((group) => group.entryIds)).toEqual(
        fixture.expected.revealGroups,
      );
      expect(
        result.ranked.find((entry) => entry.id === "self-ten"),
      ).toMatchObject({ sum: 17, count: 2, mean: "8.50", tens: 1 });
      expect(result.revealGroups[0]?.number).toBe(2);
      expect(result.revealGroups[0]?.entryIds).toEqual([
        "higher-spread",
        "low-spread-b",
        "low-spread-a",
        "higher-median",
        "self-ten",
      ]);
      expect(scoreCompetition(fixture.input)).toEqual(result);
    });
  }
  it("rejects non-integer ratings and duplicate records", () => {
    const base = fixtures[0].input;
    expect(() =>
      scoreCompetition({
        ...base,
        ratings: [
          ...base.ratings,
          { raterId: "r1", entryId: "more-tens", score: 4.5 },
        ],
      }),
    ).toThrow(/whole numbers/);
    expect(() =>
      scoreCompetition({
        ...base,
        ratings: [
          ...base.ratings,
          { raterId: "r1", entryId: "fewer-tens", score: 8 },
        ],
      }),
    ).toThrow(/Only one rating/);
  });
});
