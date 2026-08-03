// Codable mirror of /shared/CONTRACT.md. Wire keys are snake_case; every
// decoder/encoder in BackendClient uses .convertFromSnakeCase /
// .convertToSnakeCase, so property names here are the camelCase twins.
// No computed business values live here — averages, ranks and the
// submitter auto-10 all arrive precomputed from Python.

import Foundation

nonisolated struct Person: Codable, Sendable, Identifiable, Hashable {
    let id: Int
    let name: String
}

nonisolated struct Ost: Codable, Sendable, Identifiable, Hashable {
    let id: Int
    let title: String
    let source: String?
    let submitterId: Int?
    let submitterName: String?
    let coverImagePath: String?
    let coverAccentHex: String?
    let externalLink: String?
    let createdAt: String
}

nonisolated struct Rating: Codable, Sendable, Hashable {
    let ostId: Int
    let raterId: Int
    let raterName: String
    let score: Double  // 0–10, any decimal (stored rounded to 2 places)
    let updatedAt: String
}

nonisolated extension Double {
    /// Score display without a spurious decimal: 7.0 → "7", 8.66 → "8.66".
    var scoreLabel: String { String(format: "%g", self) }
}

nonisolated struct Note: Codable, Sendable, Identifiable, Hashable {
    let id: Int
    let title: String
    let note: String
    let createdAt: String
}

nonisolated struct RankEntry: Codable, Sendable, Identifiable, Hashable {
    let ost: Ost
    let ratingCount: Int
    let average: Double?
    let minimum: Double?
    let maximum: Double?
    let stddev: Double?
    let rank: Int?

    var id: Int { ost.id }
}

nonisolated struct HistoryEntry: Codable, Sendable, Identifiable, Hashable {
    let id: Int
    let title: String
    let source: String?
    let batchLabel: String?
    let sender: String?
    let createdAt: String
}

nonisolated struct CoverCandidate: Codable, Sendable, Identifiable, Hashable {
    let imageUrl: String
    let thumbUrl: String
    let label: String
    let sourceName: String

    var id: String { imageUrl }
}

// One position in a batch: an OST plus its 1-based slot number (OST 1, OST 2…)
// and whether it's a fixed pin (host-only cue) rather than a shuffled entry.
nonisolated struct BatchSlot: Codable, Sendable, Identifiable, Hashable {
    let slot: Int
    let ost: Ost
    let pinned: Bool

    var id: Int { ost.id }
}

nonisolated struct BatchGroup: Codable, Sendable, Identifiable, Hashable {
    let index: Int  // 1-based batch number
    let day: Int    // listening day (mirrors index)
    let slots: [BatchSlot]

    var id: Int { index }
}

// The private batch key: the whole randomized arrangement, host-facing only.
nonisolated struct Batches: Codable, Sendable, Hashable {
    let generatedAt: String?
    let batches: [BatchGroup]
}

// Slice-elimination board. Every number here — slice bounds, out-counts,
// places — is computed in Python (services/elimination.py); Swift only draws it.

nonisolated struct SliceTally: Codable, Sendable, Identifiable, Hashable {
    let personId: Int
    let name: String
    let outHere: Int      // OSTs of theirs that fell in THIS slice
    let totalOut: Int     // cumulative from the bottom slice up
    let remaining: Int    // submissions still standing
    let eliminatedHere: Bool

    var id: Int { personId }
}

nonisolated struct RankSlice: Codable, Sendable, Identifiable, Hashable {
    let index: Int        // 1-based, slice 1 is the bottom of the table
    let bottomRank: Int   // worst rank in the band (50)
    let topRank: Int      // best rank in the band (41)
    let label: String     // "50–41"
    let ostIds: [Int]     // worst rank first
    let tallies: [SliceTally]

    var id: Int { index }
}

nonisolated struct Elimination: Codable, Sendable, Identifiable, Hashable {
    let personId: Int
    let name: String
    let place: Int        // 1 = winner; counted down from the field size
    let sliceIndex: Int
    let outAtRank: Int
    let totalOut: Int

    var id: Int { personId }
}

nonisolated struct Survivor: Codable, Sendable, Identifiable, Hashable {
    let personId: Int
    let name: String
    let totalOut: Int
    let remaining: Int

    var id: Int { personId }
}

nonisolated struct EliminationBoard: Codable, Sendable, Hashable {
    let threshold: Int
    let sliceSize: Int
    let rankedCount: Int
    let slices: [RankSlice]
    let eliminated: [Elimination]   // best place first
    let survivors: [Survivor]
}

nonisolated enum PlaybackStatus: String, Codable, Sendable {
    case idle, resolving, playing, paused, stopped
}

nonisolated struct PlaybackState: Codable, Sendable, Hashable {
    let status: PlaybackStatus
    let ostId: Int?
    let streamUrl: String?
    let watchUrl: String?
    let position: Double
}

// Request bodies -------------------------------------------------------------

nonisolated struct NewPerson: Encodable, Sendable { let name: String }

nonisolated struct NewOst: Encodable, Sendable {
    let title: String
    let source: String?
    let submitterId: Int?
    let externalLink: String?
}

nonisolated struct CoverSet: Encodable, Sendable { let imageUrl: String }

nonisolated struct RatingUpsert: Encodable, Sendable {
    let ostId: Int
    let raterId: Int
    let score: Double?  // 0–10, any decimal; nil clears the cell

    private enum CodingKeys: String, CodingKey {
        case ostId, raterId, score
    }

    // Custom decode: the synthesized Encodable would omit a nil score
    // (encodeIfPresent), but the backend's RatingIn requires the key —
    // nullable, not optional — so a clear request 422s without it. Clearing
    // must send an explicit "score": null.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ostId, forKey: .ostId)
        try container.encode(raterId, forKey: .raterId)
        if let score {
            try container.encode(score, forKey: .score)
        } else {
            try container.encodeNil(forKey: .score)
        }
    }
}

nonisolated struct RatingUpsertList: Encodable, Sendable {
    let ratings: [RatingUpsert]
}

nonisolated struct RevealState: Codable, Sendable {
    let unlocked: Bool
}

nonisolated struct NewNote: Encodable, Sendable {
    let title: String
    let note: String
}

nonisolated struct NotePatch: Encodable, Sendable {
    var title: String? = nil
    var note: String? = nil
}

nonisolated struct BatchCount: Encodable, Sendable { let count: Int }

nonisolated struct EliminationThreshold: Encodable, Sendable { let threshold: Int }

// Nested OST ids in host-chosen order — the drag-and-drop arrangement.
nonisolated struct BatchArrangement: Encodable, Sendable { let batches: [[Int]] }

nonisolated struct BatchPin: Encodable, Sendable {
    let ostId: Int
    let pinned: Bool
}
