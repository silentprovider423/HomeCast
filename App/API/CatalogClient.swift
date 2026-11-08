import Foundation

/// Öffentlicher Katalog: iTunes-Search-API (ohne Schlüssel) und Apples öffentliche Chart-Feeds.
/// Keine Anmeldung, keine Personalisierung (Analyse #86–#90).
struct CatalogClient: Sendable {
    var session: URLSession = .shared
    /// Ländercode für Charts und Suche, folgt der Region des iPhones
    var country: String = (Locale.current.region?.identifier ?? "US").lowercased()

    /// iTunes-Genres für „Kategorien durchsuchen“ (Auswahl der Hauptkategorien)
    static let genres: [(id: Int, name: LocalizedStringResource, symbol: String)] = [
        (1489, "Nachrichten", "newspaper"), (1488, "True Crime", "magnifyingglass"), (1303, "Comedy", "face.smiling"),
        (1324, "Gesellschaft und Kultur", "person.3"), (1321, "Wirtschaft", "chart.line.uptrend.xyaxis"),
        (1318, "Technologie", "cpu"), (1533, "Wissenschaft", "atom"), (1487, "Geschichte", "building.columns"),
        (1512, "Gesundheit und Fitness", "heart"), (1545, "Sport", "sportscourt"), (1301, "Kunst", "paintpalette"),
        (1304, "Bildung", "graduationcap"), (1309, "Fernsehen und Film", "film"), (1310, "Musik", "music.note"),
        (1305, "Kinder und Familie", "figure.2.and.child.holdinghands"), (1502, "Freizeit", "gamecontroller"),
    ]

    // MARK: Suche

    func searchShows(_ term: String, limit: Int = 30) async throws -> [CatalogShow] {
        let data = try await fetch("https://itunes.apple.com/search", ["term": term, "media": "podcast", "entity": "podcast",
                                                                      "limit": "\(limit)", "country": country])
        return try JSONDecoder().decode(ITunesResults<ITunesItem>.self, from: data).results.compactMap(\.show)
    }

    func searchEpisodes(_ term: String, limit: Int = 30) async throws -> [CatalogEpisode] {
        let data = try await fetch("https://itunes.apple.com/search", ["term": term, "media": "podcast", "entity": "podcastEpisode",
                                                                      "limit": "\(limit)", "country": country])
        return try JSONDecoder().decode(ITunesResults<ITunesItem>.self, from: data).results.compactMap(\.episode)
    }

    /// Sendung zu einer iTunes-ID nachschlagen (liefert u. a. die Feed-URL)
    func lookup(_ itunesID: Int) async throws -> CatalogShow? {
        let data = try await fetch("https://itunes.apple.com/lookup", ["id": "\(itunesID)", "country": country])
        return try JSONDecoder().decode(ITunesResults<ITunesItem>.self, from: data).results.compactMap(\.show).first
    }

    // MARK: Charts

    /// Top-Sendungen über Apples öffentlichen Marketing-Feed
    func topShows(limit: Int = 50) async throws -> [CatalogShow] {
        let data = try await fetch("https://rss.marketingtools.apple.com/api/v2/\(country)/podcasts/top/\(limit)/podcasts.json", [:])
        return try JSONDecoder().decode(ChartFeed.self, from: data).feed.results.compactMap { r in
            guard let id = Int(r.id) else { return nil }
            return CatalogShow(itunesID: id, title: r.name, author: r.artistName ?? "", artworkURL: r.artwork(600), feedURL: nil,
                               genre: r.genres?.first?.name)
        }
    }

    /// Angesagte Folgen
    func topEpisodes(limit: Int = 25) async throws -> [CatalogEpisode] {
        let data = try await fetch("https://rss.marketingtools.apple.com/api/v2/\(country)/podcasts/top/\(limit)/podcast-episodes.json", [:])
        return try JSONDecoder().decode(ChartFeed.self, from: data).feed.results.map { r in
            CatalogEpisode(id: r.id, title: r.name, showTitle: r.artistName ?? "", showItunesID: r.showID,
                           artworkURL: r.artwork(600), audioURL: nil, pubDate: nil, duration: 0, summary: "", feedURL: nil)
        }
    }

    /// Top-Sendungen einer Kategorie (älterer, weiterhin öffentlicher iTunes-RSS-Feed)
    func topShows(genre: Int, limit: Int = 50) async throws -> [CatalogShow] {
        let data = try await fetch("https://itunes.apple.com/\(country)/rss/toppodcasts/limit=\(limit)/genre=\(genre)/json", [:])
        return try JSONDecoder().decode(LegacyFeed.self, from: data).feed.entry?.compactMap(\.show) ?? []
    }

    // MARK: Transport

    private func fetch(_ base: String, _ query: [String: String]) async throws -> Data {
        guard var c = URLComponents(string: base) else { throw APIError.badURL }
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = c.url else { throw APIError.badURL }
        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        // ein zweiter Versuch bei Zeitüberschreitung (Apples Feeds antworten gelegentlich langsam)
        for attempt in 0..<2 {
            do {
                let (data, resp) = try await session.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 else { throw APIError.http(code, url.host() ?? "") }
                return data
            } catch let e as URLError where e.code == .timedOut && attempt == 0 {
                continue
            }
        }
        throw URLError(.timedOut)
    }
}

// MARK: - iTunes-JSON

private struct ITunesResults<T: Decodable>: Decodable { let results: [T] }

private struct ITunesItem: Decodable {
    let wrapperType: String?
    let kind: String?
    let collectionId: Int?
    let trackId: Int?
    let collectionName: String?
    let trackName: String?
    let artistName: String?
    let artworkUrl600: String?
    let artworkUrl160: String?
    let artworkUrl100: String?
    let feedUrl: String?
    let primaryGenreName: String?
    let episodeUrl: String?
    let releaseDate: String?
    let trackTimeMillis: Int?
    let description: String?
    let shortDescription: String?

    var show: CatalogShow? {
        guard kind == "podcast", let id = collectionId ?? trackId else { return nil }
        return CatalogShow(itunesID: id, title: collectionName ?? trackName ?? "", author: artistName ?? "",
                           artworkURL: (artworkUrl600 ?? artworkUrl100).flatMap(URL.init(string:)),
                           feedURL: feedUrl.flatMap(URL.init(string:)), genre: primaryGenreName)
    }

    var episode: CatalogEpisode? {
        guard kind == "podcast-episode", let tid = trackId else { return nil }
        return CatalogEpisode(id: "\(tid)", title: trackName ?? "", showTitle: collectionName ?? "", showItunesID: collectionId,
                              artworkURL: (artworkUrl600 ?? artworkUrl160 ?? artworkUrl100).flatMap(URL.init(string:)),
                              audioURL: episodeUrl.flatMap(URL.init(string:)), pubDate: PPDate.parse(releaseDate),
                              duration: TimeInterval(trackTimeMillis ?? 0) / 1000, summary: description ?? shortDescription ?? "",
                              feedURL: feedUrl.flatMap(URL.init(string:)))
    }
}

private struct ChartFeed: Decodable {
    struct Feed: Decodable { let results: [Item] }
    struct Genre: Decodable { let name: String? }
    struct Item: Decodable {
        let id: String
        let name: String
        let artistName: String?
        let artworkUrl100: String?
        let url: String?
        let genres: [Genre]?
        func artwork(_ size: Int) -> URL? {
            artworkUrl100.flatMap { URL(string: $0.replacingOccurrences(of: "100x100bb", with: "\(size)x\(size)bb")) }
        }
        /// Sendungs-ID aus der Folgen-URL (…/id1234?i=…)
        var showID: Int? {
            guard let url, let r = url.range(of: #"/id(\d+)"#, options: .regularExpression) else { return nil }
            return Int(url[r].dropFirst(3))
        }
    }
    let feed: Feed
}

private struct LegacyFeed: Decodable {
    struct Label: Decodable { let label: String? }
    struct IDAttr: Decodable { let attributes: [String: String]? }
    struct Entry: Decodable {
        let name: Label
        let image: [Label]?
        let artist: Label?
        let id: IDAttr?
        enum CodingKeys: String, CodingKey { case name = "im:name", image = "im:image", artist = "im:artist", id }
        var show: CatalogShow? {
            guard let s = id?.attributes?["im:id"], let iid = Int(s) else { return nil }
            let art = image?.last?.label.flatMap { URL(string: $0.replacingOccurrences(of: "170x170bb", with: "600x600bb")) }
            return CatalogShow(itunesID: iid, title: name.label ?? "", author: artist?.label ?? "", artworkURL: art, feedURL: nil, genre: nil)
        }
    }
    struct Feed: Decodable { let entry: [Entry]? }
    let feed: Feed
}
