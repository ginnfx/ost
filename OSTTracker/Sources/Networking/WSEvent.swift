// The /ws envelope: {"type": ..., "payload": ...}, decoded as a
// discriminated union. Python's api.py is the single writer of these shapes.

import Foundation

nonisolated enum ResolutionPhase: String, Decodable, Sendable {
    case externalLink
    case searchingYouTube
    case searchingSpotifyMeta
    case searchingBing
    case extracting
    case ready
    case failed
}

nonisolated enum WSEvent: Sendable {
    case playbackState(PlaybackState)
    case resolutionProgress(ostID: Int, phase: ResolutionPhase)
    case ratingUpdated(ostID: Int, raterID: Int, score: Double?)
    case leaderboardResorted([RankEntry])
    case coverArtReady(ostID: Int, path: String?, accentHex: String?)
    case revealState(unlocked: Bool)
}

extension WSEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, payload
    }

    private struct ResolutionPayload: Decodable {
        let ostId: Int
        let phase: ResolutionPhase
    }

    private struct RatingPayload: Decodable {
        let ostId: Int
        let raterId: Int
        let score: Double?
    }

    private struct CoverPayload: Decodable {
        let ostId: Int
        let path: String?
        let accentHex: String?
    }

    private struct RevealPayload: Decodable {
        let unlocked: Bool
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "playbackState":
            self = .playbackState(try container.decode(PlaybackState.self, forKey: .payload))
        case "resolutionProgress":
            let p = try container.decode(ResolutionPayload.self, forKey: .payload)
            self = .resolutionProgress(ostID: p.ostId, phase: p.phase)
        case "ratingUpdated":
            let p = try container.decode(RatingPayload.self, forKey: .payload)
            self = .ratingUpdated(ostID: p.ostId, raterID: p.raterId, score: p.score)
        case "leaderboardResorted":
            self = .leaderboardResorted(try container.decode([RankEntry].self, forKey: .payload))
        case "coverArtReady":
            let p = try container.decode(CoverPayload.self, forKey: .payload)
            self = .coverArtReady(ostID: p.ostId, path: p.path, accentHex: p.accentHex)
        case "revealState":
            let p = try container.decode(RevealPayload.self, forKey: .payload)
            self = .revealState(unlocked: p.unlocked)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown /ws event type: \(type)"
            )
        }
    }
}
