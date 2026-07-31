//
//  ExternalRating.swift
//  Lume
//
//  A critic/audience score for a title from an external aggregator (IMDb,
//  Rotten Tomatoes, Metacritic, Trakt, Letterboxd, TMDB), sourced from the
//  MDBList API's `ratings` array. Stored on the SwiftData models as a Codable
//  value (in a `Data` blob, like `TitleVideo`) so the detail screens can
//  render a ratings row without a refetch.
//

import Foundation
import SwiftUI

/// A single external rating with the metadata the detail screens need to render
/// it (display name, brand tint, formatted value).
///
/// `nonisolated` because it is decoded and mapped inside the `nonisolated`
/// ``MDBListClient`` — under this project's default-MainActor isolation a plain
/// type would otherwise pick up a main-actor-isolated `Equatable`/`Hashable`
/// conformance that can't be used off the main actor.
nonisolated struct ExternalRating: Codable, Hashable, Identifiable {
    /// The aggregators we recognise. MDBList reports more (e.g. Roger Ebert,
    /// MyAnimeList), but these are the ones worth surfacing. Raw values are
    /// persisted inside `externalRatingsData` blobs — never change them.
    nonisolated enum Source: String, Codable, CaseIterable {
        case imdb
        case rottenTomatoes
        case rtAudience
        case metacritic
        case trakt
        case letterboxd
        case tmdb

        /// Maps MDBList's `source` identifier to a known source, or nil for
        /// ones we don't display (e.g. `metacriticuser`, `rogerebert`,
        /// `myanimelist`).
        init?(mdbListSource: String) {
            switch mdbListSource {
            case "imdb": self = .imdb
            case "tomatoes": self = .rottenTomatoes
            case "popcorn": self = .rtAudience
            case "metacritic": self = .metacritic
            case "trakt": self = .trakt
            case "letterboxd": self = .letterboxd
            case "tmdb": self = .tmdb
            default: return nil
            }
        }
    }

    let source: Source
    /// The value formatted the way the aggregator brands its scores
    /// (e.g. `7.6/10`, `85%`, `67/100`, `4.1/5`).
    let value: String

    var id: String {
        source.rawValue
    }
}

nonisolated extension ExternalRating.Source {
    /// Short label shown beneath the value.
    var displayName: String {
        switch self {
        case .imdb: "IMDb"
        case .rottenTomatoes: "Rotten Tomatoes"
        case .rtAudience: "RT Audience"
        case .metacritic: "Metacritic"
        case .trakt: "Trakt"
        case .letterboxd: "Letterboxd"
        case .tmdb: "TMDB"
        }
    }

    /// Row order for the ratings chips — the best-known aggregators lead, so
    /// truncated layouts (the tvOS 10-foot row) keep the most recognisable ones.
    var displayPriority: Int {
        switch self {
        case .imdb: 0
        case .rottenTomatoes: 1
        case .rtAudience: 2
        case .metacritic: 3
        case .trakt: 4
        case .letterboxd: 5
        case .tmdb: 6
        }
    }
}

nonisolated extension ExternalRating {
    /// The numeric portion of `value`, normalised to a 0…100 percentage where it
    /// makes sense — used to colour-code the Rotten Tomatoes / Metacritic chips.
    /// Returns nil for sources with a fixed brand tint.
    private var percentScore: Double? {
        switch source {
        case .imdb, .trakt, .letterboxd, .tmdb:
            nil
        case .rottenTomatoes, .rtAudience:
            // "85%"
            Double(value.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
        case .metacritic:
            // "67/100"
            Double(value.split(separator: "/").first.map(String.init) ?? "")
        }
    }

    /// A compact value for the chip, dropping the denominator
    /// (e.g. `7.6/10` → `7.6`, `67/100` → `67`). Percentages keep their sign.
    var compactValue: String {
        if let slash = value.firstIndex(of: "/") {
            return String(value[value.startIndex ..< slash])
        }
        return value
    }

    /// Brand-ish tint for the chip. Rotten Tomatoes (critic + audience) and
    /// Metacritic are colour-coded by score (fresh/rotten · good/mixed/bad);
    /// the others use their brand colour.
    var tint: Color {
        switch source {
        case .imdb:
            Color(red: 0.96, green: 0.77, blue: 0.13) // IMDb gold
        case .rottenTomatoes:
            // "Fresh" at 60%+.
            if (percentScore ?? 0) >= 60 {
                Color(red: 0.98, green: 0.36, blue: 0.22)
            } else {
                Color(red: 0.45, green: 0.62, blue: 0.86)
            }
        case .rtAudience:
            // Upright popcorn at 60%+.
            if (percentScore ?? 0) >= 60 {
                Color(red: 0.98, green: 0.83, blue: 0.16)
            } else {
                Color(red: 0.45, green: 0.62, blue: 0.86)
            }
        case .metacritic:
            switch percentScore ?? 0 {
            case 61...: Color(red: 0.40, green: 0.73, blue: 0.30) // green
            case 40 ..< 61: Color(red: 0.98, green: 0.79, blue: 0.20) // yellow
            default: Color(red: 0.90, green: 0.30, blue: 0.27) // red
            }
        case .trakt:
            Color(red: 0.93, green: 0.11, blue: 0.14) // Trakt red
        case .letterboxd:
            Color(red: 0.00, green: 0.88, blue: 0.33) // Letterboxd green
        case .tmdb:
            Color(red: 0.01, green: 0.71, blue: 0.89) // TMDB blue
        }
    }
}
