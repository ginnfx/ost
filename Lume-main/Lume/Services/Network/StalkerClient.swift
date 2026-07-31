//
//  StalkerClient.swift
//  Lume
//
//  Stalker (Ministra) portal API client. Authenticates by MAC address via the
//  handshake → token flow, fetches the live / VOD / series catalog, and resolves
//  short-lived play URLs on demand through `create_link`. Mirrors the shape and
//  retry behaviour of `XtreamClient`.
//

import Foundation
import OSLog

// MARK: - StalkerClient

class StalkerClient {
    nonisolated struct Configuration {
        let portalURL: String
        let macAddress: String
        let username: String
        let password: String
        let timeout: TimeInterval

        init(
            portalURL: String,
            macAddress: String,
            username: String = "",
            password: String = "",
            timeout: TimeInterval = 30
        ) {
            self.portalURL = portalURL
            self.macAddress = macAddress
            self.username = username
            self.password = password
            self.timeout = timeout
        }

        /// A configuration built from a playlist's stored fields.
        init(playlist: Playlist, timeout: TimeInterval = 30) {
            self.init(
                portalURL: playlist.serverURL,
                macAddress: playlist.macAddress ?? "",
                username: playlist.username,
                password: playlist.password,
                timeout: timeout
            )
        }
    }

    let configuration: Configuration
    let session: URLSession

    nonisolated init(configuration: Configuration, urlSession: URLSession? = nil) {
        self.configuration = configuration
        session = urlSession ?? Self.makeSession(timeout: configuration.timeout)
    }

    private nonisolated static func makeSession(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 1
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = 120
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }

    /// Cache key isolating one portal+MAC session from another.
    private var sessionKey: String {
        "\(configuration.portalURL)|\(configuration.macAddress)"
    }

    // MARK: - Endpoint resolution

    /// Candidate middleware endpoints derived from the user-supplied portal URL.
    /// Portals expose the API at either `…/portal.php` or
    /// `…/server/load.php`, sometimes under a `/stalker_portal/` or `/c/` path.
    /// The handshake tries these in order and the working one is pinned for the
    /// session.
    private func candidateEndpoints() -> [URL] {
        let raw = configuration.portalURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: raw), components.host != nil else { return [] }
        // Reduce to scheme://host:port — the path the user pasted (`/c/`,
        // `/stalker_portal/`, a trailing slash) is just a hint at the variant.
        let pastedPath = components.path.lowercased()
        components.query = nil
        components.fragment = nil

        let paths: [String] = if pastedPath.contains("stalker_portal") {
            ["/stalker_portal/server/load.php", "/portal.php", "/server/load.php"]
        } else {
            ["/portal.php", "/server/load.php", "/stalker_portal/server/load.php"]
        }

        return paths.compactMap { path in
            var copy = components
            copy.path = path
            return copy.url
        }
    }

    /// scheme://host:port of the portal, used for the `Referer` header.
    private var portalOrigin: String {
        guard var components = URLComponents(string: configuration.portalURL) else {
            return configuration.portalURL
        }
        components.path = "/c/"
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString ?? configuration.portalURL
    }

    // MARK: - Session / handshake

    /// Returns a valid session (bearer token + pinned endpoint), handshaking if
    /// none is cached. `forceRefresh` discards a cached session first — used when
    /// a request comes back unauthorized (an expired token).
    private func authorizedSession(forceRefresh: Bool = false) async throws -> StalkerSessionStore.Session {
        if forceRefresh {
            await StalkerSessionStore.shared.clear(sessionKey)
        } else if let cached = await StalkerSessionStore.shared.session(for: sessionKey) {
            return cached
        }
        let session = try await handshake()
        await StalkerSessionStore.shared.store(session, for: sessionKey)
        return session
    }

    /// Performs the Stalker handshake against each candidate endpoint until one
    /// returns a token, then primes the session with `get_profile` (some portals
    /// only activate the token once the profile is fetched).
    private func handshake() async throws -> StalkerSessionStore.Session {
        let endpoints = candidateEndpoints()
        guard !endpoints.isEmpty else { throw StalkerError.invalidURL }

        var lastError: Error = StalkerError.handshakeFailed
        for endpoint in endpoints {
            // Bail immediately if a caller deadline (e.g. the add-playlist
            // connection-test timeout) cancelled us, rather than racing through
            // the remaining endpoints.
            try Task.checkCancellation()
            do {
                let url = appendingQuery(to: endpoint, [
                    URLQueryItem(name: "type", value: "stb"),
                    URLQueryItem(name: "action", value: "handshake"),
                    URLQueryItem(name: "token", value: ""),
                    URLQueryItem(name: "JsHttpRequest", value: "1-xml")
                ])
                let envelope: StalkerEnvelope<StalkerHandshake> = try await perform(url: url, token: nil)
                guard let token = envelope.js.token, !token.isEmpty else {
                    lastError = StalkerError.handshakeFailed
                    continue
                }
                let session = StalkerSessionStore.Session(token: token, endpoint: endpoint)
                // Prime the profile; ignore failures — many portals don't require
                // it and some return a sparse profile that still authorizes.
                _ = try? await getProfile(using: session)
                return session
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    // MARK: - Request plumbing

    private func appendingQuery(to endpoint: URL, _ items: [URLQueryItem]) -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return endpoint
        }
        components.queryItems = (components.queryItems ?? []) + items
        return components.url ?? endpoint
    }

    private static let maxAttempts = 3

    /// Issues an authorized request for the given action, retrying once on an
    /// auth failure with a fresh handshake, and with backoff on transient
    /// network errors.
    private func request<T: Decodable>(
        type: String,
        action: String,
        extraQuery: [URLQueryItem] = []
    ) async throws -> T {
        var refreshedAuth = false
        var attempt = 0
        while true {
            attempt += 1
            let session = try await authorizedSession(forceRefresh: refreshedAuth)
            let query = [
                URLQueryItem(name: "type", value: type),
                URLQueryItem(name: "action", value: action)
            ] + extraQuery + [URLQueryItem(name: "JsHttpRequest", value: "1-xml")]
            let url = appendingQuery(to: session.endpoint, query)
            do {
                return try await perform(url: url, token: session.token)
            } catch let error as StalkerError {
                if error.isAuthFailure, !refreshedAuth {
                    refreshedAuth = true
                    continue
                }
                guard error.isRetriable, attempt < Self.maxAttempts else { throw error }
                let delay = pow(2.0, Double(attempt))
                Logger.network.warning(
                    "Stalker request failed (\(error.localizedDescription)); retry \(attempt)/\(Self.maxAttempts - 1) in \(delay)s"
                )
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// A single request attempt. Sets the MAC cookie, bearer token and MAG
    /// headers the portal requires, and maps transport/HTTP failures onto
    /// `StalkerError`.
    private func perform<T: Decodable>(url: URL, token: String?) async throws -> T {
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue(stalkerUserAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.setValue("Model: MAG250; Link: WiFi", forHTTPHeaderField: "X-User-Agent")
        urlRequest.setValue(portalOrigin, forHTTPHeaderField: "Referer")
        urlRequest.setValue(
            "mac=\(configuration.macAddress); stb_lang=en; timezone=Europe/London",
            forHTTPHeaderField: "Cookie"
        )
        if let token {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw StalkerError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw StalkerError.invalidResponse
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw StalkerError.authenticationFailed
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw StalkerError.serverError(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw StalkerError.decodingError(error)
        }
    }

    // MARK: - Profile

    private func getProfile(using session: StalkerSessionStore.Session) async throws -> StalkerProfile {
        let url = appendingQuery(to: session.endpoint, [
            URLQueryItem(name: "type", value: "stb"),
            URLQueryItem(name: "action", value: "get_profile"),
            URLQueryItem(name: "JsHttpRequest", value: "1-xml")
        ])
        let envelope: StalkerEnvelope<StalkerProfile> = try await perform(url: url, token: session.token)
        return envelope.js
    }

    /// Validates the portal connection by handshaking and reading the profile.
    /// Used by the add-playlist flow as the connection test.
    func authenticate() async throws -> StalkerProfile {
        let session = try await authorizedSession()
        return try await getProfile(using: session)
    }

    // MARK: - Live TV (itv)

    func getLiveGenres() async throws -> [StalkerCategory] {
        let envelope: StalkerEnvelope<[StalkerCategory]> = try await request(type: "itv", action: "get_genres")
        return envelope.js
    }

    /// All live channels in one call. Returns the full channel list; the genre id
    /// on each channel maps it to a genre fetched via `getLiveGenres`.
    func getAllChannels() async throws -> [StalkerChannel] {
        let envelope: StalkerEnvelope<StalkerPage<StalkerChannel>> = try await request(
            type: "itv",
            action: "get_all_channels"
        )
        return envelope.js.data
    }

    // MARK: - VOD (vod) / Series (series)

    func getCategories(type: String) async throws -> [StalkerCategory] {
        let envelope: StalkerEnvelope<[StalkerCategory]> = try await request(type: type, action: "get_categories")
        return envelope.js
    }

    /// A single page of an ordered list for `type` (`vod` or `series`) within a
    /// category. Returns the page items and the reported total (for pagination).
    func getOrderedList(
        type: String,
        categoryId: String,
        page: Int,
        movieId: String? = nil
    ) async throws -> (items: [StalkerVODItem], totalItems: Int?, pageSize: Int?) {
        var query = [
            URLQueryItem(name: "category", value: categoryId),
            URLQueryItem(name: "genre", value: categoryId),
            URLQueryItem(name: "sortby", value: "added"),
            URLQueryItem(name: "p", value: String(page))
        ]
        if let movieId {
            query.append(URLQueryItem(name: "movie_id", value: movieId))
        }
        let envelope: StalkerEnvelope<StalkerPage<StalkerVODItem>> = try await request(
            type: type,
            action: "get_ordered_list",
            extraQuery: query
        )
        return (envelope.js.data, envelope.js.totalItems, envelope.js.maxPageItems)
    }

    /// Walks every page of an ordered list and returns the combined items.
    /// `maxItems` caps the walk so a runaway `total_items` can't loop forever.
    func getAllOrderedItems(
        type: String,
        categoryId: String,
        movieId: String? = nil,
        maxItems: Int = 20000
    ) async throws -> [StalkerVODItem] {
        var all: [StalkerVODItem] = []
        var page = 1
        var pageSize = 14
        while all.count < maxItems {
            let result = try await getOrderedList(type: type, categoryId: categoryId, page: page, movieId: movieId)
            if let size = result.pageSize, size > 0 { pageSize = size }
            all.append(contentsOf: result.items)

            if result.items.isEmpty { break }
            if let total = result.totalItems {
                let lastPage = max(1, Int(ceil(Double(total) / Double(pageSize))))
                if page >= lastPage { break }
            } else if result.items.count < pageSize {
                break
            }
            page += 1
        }
        return all
    }

    // MARK: - Stream resolution

    /// Resolves a `cmd` into a short-lived playable URL via `create_link`.
    func resolveStreamURL(type: StalkerLink.LinkType, cmd: String) async throws -> URL {
        let envelope: StalkerEnvelope<StalkerCreateLink> = try await request(
            type: type.rawValue,
            action: "create_link",
            extraQuery: [URLQueryItem(name: "cmd", value: cmd)]
        )
        guard let rawCmd = envelope.js.cmd, let url = StalkerLink.resolvedURL(from: rawCmd) else {
            throw StalkerError.noStreamURL
        }
        return url
    }
}
