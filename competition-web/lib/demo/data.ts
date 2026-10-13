import type { DemoState, Entry, Participant } from "../domain";

const names = [
  "Mira Solis",
  "Theo Maren",
  "Nia Calder",
  "Jun Vale",
  "Ari Linden",
  "Sora Bell",
  "Lena Rowan",
  "Kai Mercer",
  "Eden Park",
  "Noah Wynn",
];
const franchises = [
  "Ember Meridian",
  "Glass Harbor",
  "Aster Circuit",
  "Moonlit Archive",
  "Copper Skies",
  "Winter Signal",
  "Paper Comet",
  "Quiet Voltage",
  "Blue Orchard",
  "Lantern Atlas",
];
const titles = [
  "First Light",
  "Letters in Snow",
  "The Long Way Home",
  "A Map of Quiet",
  "Small Constellation",
];
function cryptoLabels(): string[] {
  const ids = Array.from({ length: 50 }, (_, i) => i + 1);
  for (let i = ids.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [ids[i], ids[j]] = [ids[j], ids[i]];
  }
  return ids.map((n) => `Mystery OST #${n}`);
}

export function createDemoState(): DemoState {
  const labelOrder = cryptoLabels();
  const participants: Participant[] = names.map((name, i) => ({
    id: `person-${i + 1}`,
    name,
    submitted: i === 0 ? 0 : 5,
    rated: 0,
    finalized: 0,
  }));
  const entries: Entry[] = participants.flatMap((person, pi) =>
    pi === 0
      ? []
      : Array.from({ length: 5 }, (_, slot) => {
          const n = pi * 5 + slot;
          return {
            id: `entry-${String(n + 1).padStart(2, "0")}`,
            listeningId: `listen-${crypto.randomUUID()}`,
            label: labelOrder[n],
            title: `${titles[(pi + slot) % titles.length]}: Movement ${slot + 1}`,
            franchise: franchises[pi],
            submitterId: person.id,
            duration: 86 + ((n * 17) % 90),
            batch: slot,
            confirmed: true,
            own: person.id === "person-1",
            score: 54 + ((n * 19) % 430) / 100,
            ratings: 8,
          };
        }),
  );
  return {
    phase: "submissions",
    role: "participant",
    entries,
    participants,
    batch: 0,
    ratingByEntry: {},
    finalized: [],
    revealed: 0,
    authorizedRevealGroup: -1,
    published: false,
    passkeyPrompt: false,
    hostTab: "overview",
    toast: "",
    online: true,
    failNextUpload: false,
    mismatchNext: false,
    guide: false,
    audit: ["Trial round created", "Invited participants joined"],
    credentials: ["Primary passkey", "Backup security key"],
    recoveryCodes: [],
    recoveryShown: false,
    recoveryConsumed: false,
    reopenedFor: null,
    reopenedBatch: null,
    tourDone: false,
  };
}
