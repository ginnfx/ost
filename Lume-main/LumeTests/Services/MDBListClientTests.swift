import Foundation
@testable import Lume
import Testing

struct MDBListClientTests {
    // MARK: - isConfigured

    @Test func `not configured when key is nil`() {
        let client = MDBListClient(session: .shared, key: nil)
        #expect(client.isConfigured == false)
    }

    @Test func `not configured when key is empty`() {
        let client = MDBListClient(session: .shared, key: "")
        #expect(client.isConfigured == false)
    }

    @Test func `not configured when key is placeholder`() {
        let client = MDBListClient(session: .shared, key: "$(MDBListAPIKey)")
        #expect(client.isConfigured == false)
    }

    @Test func `configured when key is valid`() {
        let client = MDBListClient(session: .shared, key: "abc123def456")
        #expect(client.isConfigured == true)
    }

    @Test func `ratings throws missingKey when unconfigured`() async {
        let client = MDBListClient(session: .shared, key: nil)
        await #expect(throws: MDBListError.self) {
            _ = try await client.ratings(tmdbId: 1_339_713, type: .movie)
        }
    }

    // MARK: - Source mapping

    @Test func `source maps known MDBList identifiers`() {
        #expect(ExternalRating.Source(mdbListSource: "imdb") == .imdb)
        #expect(ExternalRating.Source(mdbListSource: "tomatoes") == .rottenTomatoes)
        #expect(ExternalRating.Source(mdbListSource: "popcorn") == .rtAudience)
        #expect(ExternalRating.Source(mdbListSource: "metacritic") == .metacritic)
        #expect(ExternalRating.Source(mdbListSource: "trakt") == .trakt)
        #expect(ExternalRating.Source(mdbListSource: "letterboxd") == .letterboxd)
        #expect(ExternalRating.Source(mdbListSource: "tmdb") == .tmdb)
    }

    @Test func `source returns nil for undisplayed identifiers`() {
        #expect(ExternalRating.Source(mdbListSource: "metacriticuser") == nil)
        #expect(ExternalRating.Source(mdbListSource: "rogerebert") == nil)
        #expect(ExternalRating.Source(mdbListSource: "myanimelist") == nil)
        #expect(ExternalRating.Source(mdbListSource: "") == nil)
    }

    // MARK: - mapRatings

    @Test func `mapRatings formats each source the way its brand does`() {
        let entries = [
            MDBListRatingEntry(source: "imdb", value: 8.0),
            MDBListRatingEntry(source: "metacritic", value: 76),
            MDBListRatingEntry(source: "trakt", value: 82),
            MDBListRatingEntry(source: "tomatoes", value: 94),
            MDBListRatingEntry(source: "popcorn", value: 91),
            MDBListRatingEntry(source: "tmdb", value: 83),
            MDBListRatingEntry(source: "letterboxd", value: 4.1)
        ]
        let ratings = MDBListClient.mapRatings(entries)
        let bySource = Dictionary(uniqueKeysWithValues: ratings.map { ($0.source, $0.value) })
        #expect(bySource[.imdb] == "8.0/10")
        #expect(bySource[.metacritic] == "76/100")
        #expect(bySource[.trakt] == "82%")
        #expect(bySource[.rottenTomatoes] == "94%")
        #expect(bySource[.rtAudience] == "91%")
        #expect(bySource[.tmdb] == "83%")
        #expect(bySource[.letterboxd] == "4.1/5")
    }

    @Test func `mapRatings orders by display priority`() {
        let entries = [
            MDBListRatingEntry(source: "tmdb", value: 83),
            MDBListRatingEntry(source: "letterboxd", value: 4.1),
            MDBListRatingEntry(source: "imdb", value: 8.0),
            MDBListRatingEntry(source: "popcorn", value: 91),
            MDBListRatingEntry(source: "tomatoes", value: 94)
        ]
        let ratings = MDBListClient.mapRatings(entries)
        #expect(ratings.map(\.source) == [.imdb, .rottenTomatoes, .rtAudience, .letterboxd, .tmdb])
    }

    @Test func `mapRatings drops unknown sources`() {
        let entries = [
            MDBListRatingEntry(source: "imdb", value: 8.0),
            MDBListRatingEntry(source: "rogerebert", value: 3.0)
        ]
        let ratings = MDBListClient.mapRatings(entries)
        #expect(ratings.count == 1)
        #expect(ratings.first?.source == .imdb)
    }

    @Test func `mapRatings drops null values`() {
        let entries = [MDBListRatingEntry(source: "tomatoes", value: nil)]
        #expect(MDBListClient.mapRatings(entries).isEmpty)
    }

    @Test func `mapRatings deduplicates by source keeping first`() {
        let entries = [
            MDBListRatingEntry(source: "tomatoes", value: 85),
            MDBListRatingEntry(source: "tomatoes", value: 12)
        ]
        let ratings = MDBListClient.mapRatings(entries)
        #expect(ratings.count == 1)
        #expect(ratings.first?.value == "85%")
    }

    // MARK: - Response decoding

    @Test func `decodes ratings from a successful response`() throws {
        let json = Data(Self.sampleResponse.utf8)
        let decoded = try JSONDecoder().decode(MDBListResponse.self, from: json)
        #expect(decoded.ratings?.count == 10)

        let ratings = MDBListClient.mapRatings(decoded.ratings ?? [])
        #expect(ratings.map(\.source) == [
            .imdb, .rottenTomatoes, .rtAudience, .metacritic, .trakt, .letterboxd, .tmdb
        ])
        #expect(ratings.map(\.value) == ["8.0/10", "94%", "94%", "76/100", "82%", "4.1/5", "82%"])
    }

    @Test func `decodes a response without ratings`() throws {
        let json = Data(#"{ "title": "Unknown", "type": "movie" }"#.utf8)
        let decoded = try JSONDecoder().decode(MDBListResponse.self, from: json)
        #expect(decoded.ratings == nil)
    }

    // MARK: - ExternalRating display

    @Test func `compact value strips denominator`() {
        #expect(ExternalRating(source: .imdb, value: "7.6/10").compactValue == "7.6")
        #expect(ExternalRating(source: .metacritic, value: "67/100").compactValue == "67")
        #expect(ExternalRating(source: .letterboxd, value: "4.1/5").compactValue == "4.1")
        #expect(ExternalRating(source: .rottenTomatoes, value: "85%").compactValue == "85%")
    }

    @Test func `display names are the brand names`() {
        #expect(ExternalRating.Source.imdb.displayName == "IMDb")
        #expect(ExternalRating.Source.rottenTomatoes.displayName == "Rotten Tomatoes")
        #expect(ExternalRating.Source.rtAudience.displayName == "RT Audience")
        #expect(ExternalRating.Source.metacritic.displayName == "Metacritic")
        #expect(ExternalRating.Source.trakt.displayName == "Trakt")
        #expect(ExternalRating.Source.letterboxd.displayName == "Letterboxd")
        #expect(ExternalRating.Source.tmdb.displayName == "TMDB")
    }

    @Test func `legacy OMDb-era raw values still decode`() throws {
        // Persisted `externalRatingsData` blobs predate the MDBList switch;
        // their raw source strings must keep decoding.
        let json = Data(#"[{ "source": "rottenTomatoes", "value": "85%" }]"#.utf8)
        let decoded = try JSONDecoder().decode([ExternalRating].self, from: json)
        #expect(decoded.first?.source == .rottenTomatoes)
    }

    @Test func `external rating round-trips through Codable`() throws {
        let original = [
            ExternalRating(source: .imdb, value: "7.6/10"),
            ExternalRating(source: .rtAudience, value: "91%"),
            ExternalRating(source: .letterboxd, value: "4.1/5")
        ]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([ExternalRating].self, from: data)
        #expect(decoded == original)
    }

    // MARK: - Fixtures

    /// Trimmed from a real `GET /tmdb/movie/{id}` response.
    private static let sampleResponse = """
    {
      "title": "Obsession",
      "year": 2026,
      "ids": { "imdb": "tt37287335", "trakt": 1095879, "tmdb": 1339713 },
      "type": "movie",
      "ratings": [
        { "source": "imdb", "value": 8.0, "score": 80, "votes": 165006 },
        { "source": "metacritic", "value": 76, "score": 76, "votes": 5 },
        { "source": "metacriticuser", "value": null, "score": null, "votes": null },
        { "source": "trakt", "value": 82, "score": 82, "votes": 7636 },
        { "source": "tomatoes", "value": 94, "score": 94, "votes": 286 },
        { "source": "popcorn", "value": 94, "score": 94, "votes": 3711 },
        { "source": "tmdb", "value": 82, "score": 82, "votes": 1996 },
        { "source": "letterboxd", "value": 4.1, "score": 82, "votes": 2593903 },
        { "source": "rogerebert", "value": 3.0, "score": null, "votes": null },
        { "source": "myanimelist", "value": null, "score": null, "votes": null }
      ]
    }
    """
}
