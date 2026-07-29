// Unit tests for the pure/testable pieces: AppStore's static presentation
// helpers (rosterOrder, index) and the extracted Add-OST validation rule
// (AddOstRules.canSubmit). No sidecar/backend involved — everything here is
// a synchronous, deterministic function of its inputs.

import Testing
@testable import OSTTracker

// MARK: - Fixtures

private func makeOst(
    id: Int, title: String, submitterId: Int? = nil
) -> Ost {
    Ost(
        id: id, title: title, source: nil, submitterId: submitterId, submitterName: nil,
        coverImagePath: nil, coverAccentHex: nil, externalLink: nil, createdAt: "2026-01-01T00:00:00Z"
    )
}

private func makeEntry(id: Int, title: String, rank: Int?) -> RankEntry {
    RankEntry(
        ost: makeOst(id: id, title: title), ratingCount: 0, average: nil, minimum: nil,
        maximum: nil, stddev: nil, rank: rank
    )
}

// MARK: - rosterOrder

@Suite("AppStore.rosterOrder")
struct RosterOrderTests {
    @Test("ranked entries sort before unranked entries")
    func rankedBeforeUnranked() {
        let unranked = makeEntry(id: 1, title: "Aardvark Anthem", rank: nil)
        let ranked = makeEntry(id: 2, title: "Zzz Lullaby", rank: 5)

        let ordered = AppStore.rosterOrder([unranked, ranked])

        #expect(ordered.map(\.id) == [2, 1])
    }

    @Test("ranked entries sort by ascending rank")
    func rankOrder() {
        let third = makeEntry(id: 1, title: "C", rank: 3)
        let first = makeEntry(id: 2, title: "A", rank: 1)
        let second = makeEntry(id: 3, title: "B", rank: 2)

        let ordered = AppStore.rosterOrder([third, first, second])

        #expect(ordered.map(\.id) == [2, 3, 1])
    }

    @Test("unranked entries tiebreak on lowercased title")
    func unrankedTitleTiebreak() {
        let bravo = makeEntry(id: 1, title: "Bravo", rank: nil)
        let alpha = makeEntry(id: 2, title: "ALPHA", rank: nil)
        let charlie = makeEntry(id: 3, title: "charlie", rank: nil)

        let ordered = AppStore.rosterOrder([bravo, alpha, charlie])

        #expect(ordered.map(\.id) == [2, 1, 3])
    }
}

// MARK: - index

@Suite("AppStore.index")
struct IndexTests {
    @Test("groups ratings by ost then rater")
    func groupsByOstThenRater() {
        let ratings = [
            Rating(ostId: 1, raterId: 10, raterName: "A", score: 8, updatedAt: "t1"),
            Rating(ostId: 1, raterId: 11, raterName: "B", score: 9, updatedAt: "t2"),
            Rating(ostId: 2, raterId: 10, raterName: "A", score: 5, updatedAt: "t3"),
        ]

        let indexed = AppStore.index(ratings)

        #expect(indexed[1]?[10] == 8)
        #expect(indexed[1]?[11] == 9)
        #expect(indexed[2]?[10] == 5)
    }

    @Test("last write wins for duplicate ost/rater pairs")
    func lastWriteWins() {
        let ratings = [
            Rating(ostId: 1, raterId: 10, raterName: "A", score: 3, updatedAt: "t1"),
            Rating(ostId: 1, raterId: 10, raterName: "A", score: 7, updatedAt: "t2"),
        ]

        let indexed = AppStore.index(ratings)

        #expect(indexed[1]?[10] == 7)
    }
}

// MARK: - AddOstRules.canSubmit

@Suite("AddOstRules.canSubmit")
struct AddOstRulesTests {
    private let alice = Person(id: 1, name: "Alice")
    private let bob = Person(id: 2, name: "Bob")

    @Test("valid title, valid submitter, not submitting is submittable")
    func validInputIsSubmittable() {
        let result = AddOstRules.canSubmit(
            title: "Song", submitterID: 1, people: [alice, bob], isSubmitting: false
        )
        #expect(result)
    }

    @Test("empty or whitespace-only title is not submittable")
    func emptyTitleIsNotSubmittable() {
        #expect(!AddOstRules.canSubmit(
            title: "", submitterID: 1, people: [alice], isSubmitting: false
        ))
        #expect(!AddOstRules.canSubmit(
            title: "   ", submitterID: 1, people: [alice], isSubmitting: false
        ))
    }

    @Test("nil submitter is not submittable")
    func nilSubmitterIsNotSubmittable() {
        let result = AddOstRules.canSubmit(
            title: "Song", submitterID: nil, people: [alice, bob], isSubmitting: false
        )
        #expect(!result)
    }

    @Test("submitter id not present in the roster is not submittable")
    func staleSubmitterIsNotSubmittable() {
        // Regression: a submitter id left over after that person was deleted
        // from the roster must not slip past validation.
        let result = AddOstRules.canSubmit(
            title: "Song", submitterID: 99, people: [alice, bob], isSubmitting: false
        )
        #expect(!result)
    }

    @Test("empty roster is not submittable")
    func emptyPeopleIsNotSubmittable() {
        let result = AddOstRules.canSubmit(
            title: "Song", submitterID: 1, people: [], isSubmitting: false
        )
        #expect(!result)
    }

    @Test("already submitting is not submittable")
    func isSubmittingIsNotSubmittable() {
        let result = AddOstRules.canSubmit(
            title: "Song", submitterID: 1, people: [alice], isSubmitting: true
        )
        #expect(!result)
    }

    @Test("a known history conflict is not submittable")
    func historyConflictIsNotSubmittable() {
        let result = AddOstRules.canSubmit(
            title: "Song", submitterID: 1, people: [alice], isSubmitting: false,
            hasHistoryConflict: true
        )
        #expect(!result)
    }

    @Test("no history conflict defaults to submittable")
    func noHistoryConflictIsSubmittable() {
        let result = AddOstRules.canSubmit(
            title: "Song", submitterID: 1, people: [alice], isSubmitting: false,
            hasHistoryConflict: false
        )
        #expect(result)
    }
}

@Suite("AddOstRules.historyConflict")
struct AddOstRulesHistoryConflictTests {
    private func entry(_ title: String, _ source: String?) -> HistoryEntry {
        HistoryEntry(id: 1, title: title, source: source, batchLabel: "Batch 1", sender: nil, createdAt: "")
    }

    @Test("same title, different sources do not conflict")
    func differentSourcesDoNotConflict() {
        let result = AddOstRules.historyConflict(
            title: "Main Theme", source: "God of War", history: [entry("Main Theme", "FF7")]
        )
        #expect(result == nil)
    }

    @Test("same title and source, different casing/padding conflicts")
    func caseAndPaddingInsensitiveMatch() {
        let result = AddOstRules.historyConflict(
            title: "  main theme  ", source: " ff7 ", history: [entry("Main Theme", "FF7")]
        )
        #expect(result != nil)
    }

    @Test("blank incoming source conflicts with a sourced entry")
    func blankIncomingSourceMatchesAnySource() {
        let result = AddOstRules.historyConflict(
            title: "Main Theme", source: "", history: [entry("Main Theme", "FF7")]
        )
        #expect(result != nil)
    }

    @Test("blank entry source conflicts with a sourced input")
    func blankEntrySourceMatchesAnyIncomingSource() {
        let result = AddOstRules.historyConflict(
            title: "Untitled Track", source: "Some Game", history: [entry("Untitled Track", nil)]
        )
        #expect(result != nil)
    }

    @Test("blank title never conflicts")
    func blankTitleIsNil() {
        let result = AddOstRules.historyConflict(
            title: "   ", source: "FF7", history: [entry("Main Theme", "FF7")]
        )
        #expect(result == nil)
    }
}
