import Foundation

/// The deterministic slice-elimination calculation shared by the offline
/// iPhone store and the app tests.
nonisolated enum EliminationBuilder {
    static func build(_ entries: [RankEntry], threshold rawThreshold: Int, sliceSize: Int = 10) -> EliminationBoard {
        let threshold = min(20, max(1, rawThreshold))
        let size = max(1, sliceSize)
        let ranked = entries.filter { $0.rank != nil }.sorted { ($0.rank ?? 0) > ($1.rank ?? 0) }
        var submissions: [Int: Int] = [:]
        var names: [Int: String] = [:]
        for entry in entries {
            guard let personID = entry.ost.submitterId else { continue }
            submissions[personID, default: 0] += 1
            names[personID] = entry.ost.submitterName ?? "#\(personID)"
        }

        var totalOut: [Int: Int] = [:]
        var eliminated = Set<Int>()
        var eliminations: [Elimination] = []
        var slices: [RankSlice] = []
        let chunks = stride(from: 0, to: ranked.count, by: size).map { start in
            Array(ranked[start..<min(start + size, ranked.count)])
        }
        for (offset, chunk) in chunks.enumerated() {
            let standing = Set(submissions.keys).subtracting(eliminated)
            var outHere: [Int: Int] = [:]
            var knockedOut = Set<Int>()
            for entry in chunk {
                guard let personID = entry.ost.submitterId, let rank = entry.rank else { continue }
                outHere[personID, default: 0] += 1
                totalOut[personID, default: 0] += 1
                if totalOut[personID, default: 0] >= threshold, !eliminated.contains(personID) {
                    eliminated.insert(personID)
                    knockedOut.insert(personID)
                    eliminations.append(Elimination(personId: personID,
                                                    name: names[personID] ?? "#\(personID)",
                                                    place: submissions.count - eliminations.count,
                                                    sliceIndex: offset + 1,
                                                    outAtRank: rank,
                                                    totalOut: totalOut[personID] ?? 0))
                }
            }
            let tallies = standing.map { personID in
                SliceTally(personId: personID,
                           name: names[personID] ?? "#\(personID)",
                           outHere: outHere[personID] ?? 0,
                           totalOut: totalOut[personID] ?? 0,
                           remaining: max(0, (submissions[personID] ?? 0) - (totalOut[personID] ?? 0)),
                           eliminatedHere: knockedOut.contains(personID))
            }.sorted {
                if $0.totalOut != $1.totalOut { return $0.totalOut > $1.totalOut }
                if $0.outHere != $1.outHere { return $0.outHere > $1.outHere }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            let bottom = chunk.first?.rank ?? 0
            let top = chunk.last?.rank ?? bottom
            slices.append(RankSlice(index: offset + 1,
                                    bottomRank: bottom,
                                    topRank: top,
                                    label: "\(bottom)–\(top)",
                                    ostIds: chunk.map { $0.ost.id },
                                    tallies: tallies))
        }
        let survivors = submissions.keys.filter { !eliminated.contains($0) }.map { personID in
            Survivor(personId: personID,
                     name: names[personID] ?? "#\(personID)",
                     totalOut: totalOut[personID] ?? 0,
                     remaining: max(0, (submissions[personID] ?? 0) - (totalOut[personID] ?? 0)))
        }.sorted {
            if $0.totalOut != $1.totalOut { return $0.totalOut < $1.totalOut }
            if $0.remaining != $1.remaining { return $0.remaining > $1.remaining }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return EliminationBoard(threshold: threshold,
                                sliceSize: size,
                                rankedCount: ranked.count,
                                slices: slices,
                                eliminated: eliminations.sorted { $0.place < $1.place },
                                survivors: survivors)
    }
}
