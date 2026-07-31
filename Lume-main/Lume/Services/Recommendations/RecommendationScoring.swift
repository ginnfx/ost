//
//  RecommendationScoring.swift
//  Lume
//
//  Pure vector math behind the on-device recommendations engine. Kept free of
//  SwiftData so the ranking logic can be exercised in isolation: it turns the
//  embeddings of liked/disliked titles into a taste profile and scores
//  candidate embeddings against it. All cosine-similarity in the shared
//  `NLContextualEmbedding` space the content index already produces.
//

import Foundation

nonisolated enum RecommendationScoring {
    /// A title the user has signalled a preference for, paired with how strongly
    /// it should pull the taste profile (favorite/upvote outweighs a passive
    /// watch).
    struct Signal {
        let vector: [Float]
        let weight: Float
    }

    /// How much a candidate's similarity to the disliked centroid is subtracted
    /// from its score. Tuned so a strong resemblance to downvoted content sinks a
    /// title without a faint one burying it.
    static let dislikeWeight: Float = 0.5

    /// The weighted, unit-normalized centroid of `signals` — the user's taste
    /// vector. Nil when there are no usable signals (empty, all-zero, or
    /// zero-weight), in which case there's nothing to recommend from.
    static func centroid(of signals: [Signal]) -> [Float]? {
        guard let dimension = signals.first(where: { !$0.vector.isEmpty })?.vector.count else { return nil }
        var sum = [Float](repeating: 0, count: dimension)
        var totalWeight: Float = 0
        for signal in signals where signal.vector.count == dimension && signal.weight > 0 {
            for index in 0 ..< dimension {
                sum[index] += signal.vector[index] * signal.weight
            }
            totalWeight += signal.weight
        }
        guard totalWeight > 0 else { return nil }
        return normalized(sum)
    }

    /// Cosine similarity of two vectors (−1...1). Zero when either is empty, a
    /// zero vector, or the lengths disagree.
    static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot: Float = 0
        var normLhs: Float = 0
        var normRhs: Float = 0
        for index in 0 ..< lhs.count {
            dot += lhs[index] * rhs[index]
            normLhs += lhs[index] * lhs[index]
            normRhs += rhs[index] * rhs[index]
        }
        guard normLhs > 0, normRhs > 0 else { return 0 }
        return dot / (normLhs.squareRoot() * normRhs.squareRoot())
    }

    /// A candidate's recommendation score: how close it sits to the taste
    /// centroid, minus a penalty for resembling disliked content. Only positive
    /// dislike similarity penalizes, so a title that's merely unlike the dislikes
    /// isn't rewarded for it.
    static func score(candidate: [Float], taste: [Float], dislike: [Float]?) -> Float {
        var value = cosineSimilarity(candidate, taste)
        if let dislike {
            value -= dislikeWeight * max(0, cosineSimilarity(candidate, dislike))
        }
        return value
    }

    private static func normalized(_ vector: [Float]) -> [Float]? {
        var norm: Float = 0
        for value in vector {
            norm += value * value
        }
        norm = norm.squareRoot()
        guard norm > 0 else { return nil }
        return vector.map { $0 / norm }
    }
}
