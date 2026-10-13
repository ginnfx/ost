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
        revealGroups: string[][];
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
      expect(result.revealGroups.map((group) => group.entryIds)).toEqual(
        fixture.expected.revealGroups,
      );
      expect(
        result.ranked.find((entry) => entry.id === "self-ten"),
      ).toMatchObject({ sum: 17, count: 2, mean: "8.50", tens: 1 });
      expect(result.revealGroups.map((group) => group.number)).toEqual([
        1, 2, 3,
      ]);
      expect(
        result.revealGroups.every((group) => group.entryIds.length > 0),
      ).toBe(true);
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

  it("caps group count to entry count and puts the remainder in the last group", () => {
    const base = fixtures[0].input;
    const result = scoreCompetition({ ...base, revealGroupCount: 6 });
    expect(result.revealGroups.map((group) => group.entryIds.length)).toEqual([
      1, 1, 1, 1, 1, 2,
    ]);
    expect(
      result.revealGroups.every((group) => group.entryIds.length > 0),
    ).toBe(true);
  });
});
