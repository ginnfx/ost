//
//  MDBListClient.swift
//  Lume
//
//  Lightweight read-only client for the MDBList API (https://mdblist.com).
//  Used to fetch aggregator ratings (IMDb, Rotten Tomatoes critic + audience,
//  Metacritic, Trakt, Letterboxd, TMDB) for a title, keyed directly by its
//  TMDB id, to enrich the detail screens beyond TMDB's single vote average.
//
//  The API key lives in the git-ignored `.env` file (MDBLIST_API_KEY) and is
//  injected into Info.plist at build time by Scripts/inject-env.sh — it is
//  never committed to source control.
//

import Foundation

enum MDBListError: Error {
    case missingKey
    case invalidURL
    case invalidResponse
    case serverError(Int)
    case notFound
    case decodingError(Error)
}

/// Read-only MDBList client. Only the ratings lookup the detail screens need
/// is implemented.
nonisolated struct MDBListClient {
    static let shared = MDBListClient()

    /// The two media kinds MDBList's `/tmdb/{type}/{id}` endpoint accepts.
    nonisolated enum MediaType: String {
        case movie
        case show
    }

    private let baseURL = "https://api.mdblist.com"
    private let session: URLSession
    private let key: String?

    init(
        session: URLSession = .shared,
        key: String? = MDBListClient.keyFromBundle()
    ) {
        self.session = session
        self.key = key
    }

    /// Whether a usable API key is present. When false the ratings section is
    /// simply hidden rather than surfacing an error to the user.
    var isConfigured: Bool {
        guard let key, !key.isEmpty else { return false }
        // Guard against an unsubstituted Info.plist variable (no .env present).
        return !key.hasPrefix("$(")
    }

    static func keyFromBundle() -> String? {
        let raw = Bundle.main.object(forInfoDictionaryKey: "MDBListAPIKey") as? String
        return raw?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fetches the aggregator ratings for a title by its TMDB id. Sources
    /// MDBList returns that we don't recognise (or that carry no value) are
    /// dropped; the result is ordered by ``ExternalRating/Source`` display
    /// priority.
    func ratings(tmdbId: Int, type: MediaType) async throws -> [ExternalRating] {
        guard isConfigured, let key else { throw MDBListError.missingKey }

        var components = URLComponents(string: "\(baseURL)/tmdb/\(type.rawValue)/\(tmdbId)")
        components?.queryItems = [URLQueryItem(name: "apikey", value: key)]
        guard let url = components?.url else { throw MDBListError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "accept")

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw MDBListError.invalidResponse
        }
        guard http.statusCode != 404 else { throw MDBListError.notFound }
        guard (200 ... 299).contains(http.statusCode) else {
            throw MDBListError.serverError(http.statusCode)
        }

        let decoded: MDBListResponse
        do {
            decoded = try JSONDecoder().decode(MDBListResponse.self, from: data)
        } catch {
            throw MDBListError.decodingError(error)
        }

        return MDBListClient.mapRatings(decoded.ratings ?? [])
    }

    /// Maps MDBList's rating entries to our known sources, dropping
    /// unrecognised or empty ones, de-duplicating by source (first wins), and
    /// ordering by display priority so the best-known aggregators lead the row.
    static func mapRatings(_ entries: [MDBListRatingEntry]) -> [ExternalRating] {
        var seen = Set<ExternalRating.Source>()
        var result: [ExternalRating] = []
        for entry in entries {
            guard let source = ExternalRating.Source(mdbListSource: entry.source),
                  let value = entry.value,
                  !seen.contains(source) else { continue }
            seen.insert(source)
            result.append(ExternalRating(source: source, value: source.formattedValue(value)))
        }
        return result.sorted { $0.source.displayPriority < $1.source.displayPriority }
    }
}

private nonisolated extension ExternalRating.Source {
    /// Formats MDBList's numeric value the way each aggregator brands its
    /// scores (e.g. `7.6/10`, `85%`, `67/100`, `4.1/5`).
    func formattedValue(_ value: Double) -> String {
        switch self {
        case .imdb: String(format: "%.1f/10", value)
        case .metacritic: "\(Int(value))/100"
        case .letterboxd: String(format: "%.1f/5", value)
        case .rottenTomatoes, .rtAudience, .trakt, .tmdb: "\(Int(value))%"
        }
    }
}

// MARK: - DTOs

/// The subset of the MDBList title response we decode.
nonisolated struct MDBListResponse: Decodable {
    let ratings: [MDBListRatingEntry]?
}

/// One `{ "source": …, "value": … }` entry from MDBList's `ratings` array.
/// `value` is null when the aggregator has no score for the title.
nonisolated struct MDBListRatingEntry: Decodable {
    let source: String
    let value: Double?
}
