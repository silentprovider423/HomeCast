import Foundation

/// Fehler des Server-Clients
enum APIError: LocalizedError, Equatable {
    case http(Int, String)
    case invalidLogin
    case badURL
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let msg): return String(localized: "Serverfehler \(code): \(msg)")
        case .invalidLogin: return String(localized: "Benutzername oder Passwort falsch.")
        case .badURL: return String(localized: "Ungültige Serveradresse.")
        case .decoding(let s): return String(localized: "Unerwartete Antwort vom Server (\(s)).")
        }
    }

    /// true, wenn der Server gar nicht erreichbar war (dann landet die Aktion in der Offline-Warteschlange)
    static func isOffline(_ error: Error) -> Bool {
        if let u = error as? URLError {
            return [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                    .timedOut, .dataNotAllowed, .internationalRoamingOff, .secureConnectionFailed].contains(u.code)
        }
        return false
    }
}

/// Client für die REST-API von PinePods (getestet mit 0.9.2). Header `Api-Key`.
/// Endpunkte siehe Analyse §4.1 („Wichtigste Endpunkte“).
struct PinePodsClient: Sendable {
    let account: ServerAccount
    var session: URLSession = .shared

    var userID: Int { account.userID }

    // MARK: Anmeldung

    /// Meldet sich per Basic Auth an und liefert API-Schlüssel + Nutzer-ID (`GET /api/data/get_key`).
    static func login(server: URL, username: String, password: String, session: URLSession = .shared) async throws -> ServerAccount {
        var req = URLRequest(url: server.appending(path: "api/data/get_key"))
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw APIError.invalidLogin }
        guard code == 200 else { throw APIError.http(code, String(decoding: data.prefix(200), as: UTF8.self)) }
        struct LoginResponse: Decodable { let status: String; let retrieved_key: String?; let user_id: Int?; let mfa_required: Bool? }
        let r = try JSONDecoder().decode(LoginResponse.self, from: data)
        if r.mfa_required == true { throw APIError.http(401, String(localized: "Zwei-Faktor-Anmeldung wird noch nicht unterstützt.")) }
        guard let key = r.retrieved_key, let uid = r.user_id else { throw APIError.invalidLogin }
        return ServerAccount(server: server, apiKey: key, userID: uid, username: username)
    }

    /// Anmeldung nur mit API-Schlüssel (Debug-Start, Tests): Nutzer-ID über `get_user` holen.
    static func account(server: URL, apiKey: String, session: URLSession = .shared) async throws -> ServerAccount {
        var req = URLRequest(url: server.appending(path: "api/data/get_user"))
        req.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw APIError.invalidLogin }
        struct R: Decodable { let retrieved_id: Int }
        let r = try JSONDecoder().decode(R.self, from: data)
        return ServerAccount(server: server, apiKey: apiKey, userID: r.retrieved_id, username: "")
    }

    func verify() async throws -> Bool {
        struct R: Decodable { let status: String }
        let r: R = try await get("verify_key")
        return r.status == "success"
    }

    // MARK: Abos

    func shows() async throws -> [Show] {
        struct R: Decodable { let pods: [PodDTO]? }
        let r: R = try await get("return_pods_extra/\(userID)")
        return (r.pods ?? []).enumerated().map { $1.show(order: $0) }
    }

    func showDetails(_ podcastID: Int) async throws -> ShowDetails {
        struct R: Decodable { let details: ShowDetails }
        let r: R = try await get("get_podcast_details", query: ["user_id": "\(userID)", "podcast_id": "\(podcastID)"])
        return r.details
    }

    /// Folgt einer Sendung (`add_podcast`) und liefert die neue podcastid.
    @discardableResult
    func follow(_ show: Show) async throws -> Int {
        guard let feed = show.feedURL else { throw APIError.badURL }
        var cats: [String: String] = [:]
        for (i, c) in show.categories.enumerated() { cats["\(i)"] = c }
        let values: [String: Any] = [
            "pod_title": show.title, "pod_artwork": show.artworkURL?.absoluteString ?? "", "pod_author": show.author,
            "categories": cats, "pod_description": show.summary, "pod_episode_count": show.episodeCount,
            "pod_feed_url": feed.absoluteString, "pod_website": show.websiteURL?.absoluteString ?? "",
            "pod_explicit": show.explicit, "user_id": userID,
        ]
        struct R: Decodable { let success: Bool?; let podcast_id: Int? }
        let r: R = try await post("add_podcast", ["podcast_values": values, "podcast_index_id": NSNull()])
        if let id = r.podcast_id, id > 0 { return id }
        // Bereits abonniert → ID nachschlagen
        if let id = try await podcastID(feed: feed, title: show.title) { return id }
        throw APIError.decoding("add_podcast")
    }

    func unfollow(_ podcastID: Int) async throws {
        struct R: Decodable { let success: Bool? }
        let _: R = try await post("remove_podcast_id", ["user_id": userID, "podcast_id": podcastID])
    }

    func podcastID(feed: URL, title: String) async throws -> Int? {
        struct R: Decodable { let podcast_id: Int? }
        let r: R = try await get("get_podcast_id", query: ["user_id": "\(userID)", "podcast_feed": feed.absoluteString, "podcast_title": title])
        return (r.podcast_id ?? 0) > 0 ? r.podcast_id : nil
    }

    /// Feed einer Sendung neu einlesen (für normale Nutzer erlaubt; `refresh_pods` ist nur für Admins).
    func refresh(_ podcastID: Int) async throws {
        struct R: Decodable { let success: Bool? }
        let _: R = try await post("refresh_podcast_details", ["podcast_id": podcastID, "reset_edits": false])
    }

    // MARK: Folgen

    /// Folgen einer Sendung, seitenweise (neueste zuerst bzw. `oldestFirst`).
    func episodes(podcastID: Int, limit: Int = 50, offset: Int = 0, oldestFirst: Bool = false, search: String? = nil) async throws -> (episodes: [Episode], total: Int) {
        struct R: Decodable { let episodes: [ShowEpisodeDTO]?; let total: Int? }
        var q = ["user_id": "\(userID)", "podcast_id": "\(podcastID)", "limit": "\(limit)", "offset": "\(offset)",
                 "sort_order": oldestFirst ? "asc" : "desc"]
        if let search, !search.isEmpty { q["search"] = search }
        let r: R = try await get("podcast_episodes", query: q)
        return ((r.episodes ?? []).compactMap { $0.episode(podcastID: podcastID) }, r.total ?? 0)
    }

    /// Neueste Folgen aller Abos (`return_episodes`)
    func recentEpisodes(limit: Int = 100) async throws -> [Episode] {
        struct R: Decodable { let episodes: [EpisodeDTO]? }
        let r: R = try await get("return_episodes/\(userID)", query: ["limit": "\(limit)"])
        return (r.episodes ?? []).compactMap { $0.episode() }
    }

    func episodeMetadata(_ episodeID: Int) async throws -> Episode? {
        struct R: Decodable { let episode: EpisodeDTO? }
        let r: R = try await post("get_episode_metadata", ["episode_id": episodeID, "user_id": userID, "person_episode": false, "is_youtube": false])
        return r.episode?.episode()
    }

    func home() async throws -> HomeOverview {
        struct R: Decodable { let in_progress_episodes: [EpisodeDTO]?; let recent_episodes: [EpisodeDTO]?; let queue_count: Int? }
        let r: R = try await get("home_overview", query: ["user_id": "\(userID)"])
        return HomeOverview(inProgress: (r.in_progress_episodes ?? []).compactMap { $0.episode() },
                            recent: (r.recent_episodes ?? []).compactMap { $0.episode() })
    }

    func history(limit: Int = 50) async throws -> [Episode] {
        struct R: Decodable { let data: [EpisodeDTO]? }
        let r: R = try await get("user_history/\(userID)", query: ["limit": "\(limit)"])
        return (r.data ?? []).compactMap { $0.episode() }
    }

    func saved(limit: Int = 200) async throws -> [Episode] {
        struct R: Decodable { let saved_episodes: [EpisodeDTO]? }
        let r: R = try await get("saved_episode_list/\(userID)", query: ["limit": "\(limit)"])
        return (r.saved_episodes ?? []).compactMap { $0.episode() }
    }

    // MARK: Fortschritt & Status

    /// Position melden. `record_listen_duration` nimmt nur größere Werte an (Hörzeit-Statistik, gpodder),
    /// `record_podcast_history` setzt die Position exakt – nötig, wenn zurückgespult wurde.
    func recordPosition(episodeID: Int, position: TimeInterval, duration: TimeInterval?) async throws {
        var body: [String: Any] = ["episode_id": episodeID, "user_id": userID, "listen_duration": position.rounded(), "is_youtube": false]
        body["episode_duration"] = duration.map { $0 as Any } ?? NSNull()
        try await postIgnoring("record_listen_duration", body)
        try await postIgnoring("record_podcast_history", ["episode_id": episodeID, "user_id": userID, "episode_pos": position.rounded(), "is_youtube": false])
    }

    func setCompleted(_ episodeID: Int, _ completed: Bool) async throws {
        try await postIgnoring(completed ? "mark_episode_completed" : "mark_episode_uncompleted",
                               ["episode_id": episodeID, "user_id": userID, "is_youtube": false])
    }

    func setCompleted(_ ids: [Int], _ completed: Bool) async throws {
        guard !ids.isEmpty else { return }
        if completed {
            try await postIgnoring("bulk_mark_episodes_completed", ["episode_ids": ids, "user_id": userID, "is_youtube": false])
        } else {
            for id in ids { try await setCompleted(id, false) }
        }
    }

    func setSaved(_ episodeID: Int, _ saved: Bool) async throws {
        try await postIgnoring(saved ? "save_episode" : "remove_saved_episode",
                               ["episode_id": episodeID, "user_id": userID, "is_youtube": false])
    }

    // MARK: Warteliste („Als Nächstes“)

    func queue() async throws -> [Episode] {
        struct R: Decodable { let data: [EpisodeDTO]? }
        let r: R = try await get("get_queued_episodes", query: ["user_id": "\(userID)"])
        return (r.data ?? []).sorted { ($0.queueposition ?? 0) < ($1.queueposition ?? 0) }.compactMap { $0.episode() }
    }

    func enqueue(_ episodeID: Int) async throws {
        try await postIgnoring("queue_pod", ["episode_id": episodeID, "user_id": userID, "is_youtube": false])
    }

    func dequeue(_ episodeID: Int) async throws {
        try await postIgnoring("remove_queued_pod", ["episode_id": episodeID, "user_id": userID, "is_youtube": false])
    }

    /// An den Anfang der Warteliste („Als Nächstes wiedergeben“)
    func bump(_ episodeID: Int) async throws {
        try await postIgnoring("queue_bump", ["episode_id": episodeID, "user_id": userID, "is_youtube": false])
    }

    func reorderQueue(_ ids: [Int]) async throws {
        try await postIgnoring("reorder_queue?user_id=\(userID)", ["episode_ids": ids])
    }

    func clearQueue() async throws {
        try await postIgnoring("clear_queue", ["user_id": userID])
    }

    // MARK: Tempo, Einstellungen

    func playbackSpeed(podcastID: Int?) async throws -> Double {
        struct R: Decodable { let playback_speed: Double? }
        let r: R = try await post("get_playback_speed", ["user_id": userID, "podcast_id": podcastID.map { $0 as Any } ?? NSNull()])
        return r.playback_speed ?? 1
    }

    func playDetails(podcastID: Int) async throws -> (speed: Double, customized: Bool) {
        struct R: Decodable { let playback_speed: Double?; let playback_speed_customized: Bool? }
        let r: R = try await post("get_play_episode_details", ["podcast_id": podcastID, "user_id": userID, "is_youtube": false])
        return (r.playback_speed ?? 1, r.playback_speed_customized ?? false)
    }

    func setDefaultSpeed(_ speed: Double) async throws {
        try await postIgnoring("user/set_playback_speed", ["user_id": userID, "playback_speed": speed])
    }

    func setShowSpeed(_ speed: Double?, podcastID: Int) async throws {
        if let speed {
            try await postIgnoring("podcast/set_playback_speed", ["user_id": userID, "podcast_id": podcastID, "playback_speed": speed])
        } else {
            try await postIgnoring("clear_podcast_playback_speed", ["user_id": userID, "podcast_id": podcastID])
        }
    }

    // MARK: Kapitel (Podcasting 2.0)

    func chapters(episodeID: Int) async throws -> [Chapter] {
        struct C: Decodable { let startTime: Double?; let title: String?; let img: String?; let url: String? }
        struct R: Decodable { let chapters: [C]? }
        let r: R = try await get("fetch_podcasting_2_data", query: ["episode_id": "\(episodeID)", "user_id": "\(userID)"])
        return (r.chapters ?? []).compactMap { c in
            guard let s = c.startTime else { return nil }
            return Chapter(start: s, title: c.title ?? "", imageURL: c.img.flatMap(URL.init(string:)), url: c.url.flatMap(URL.init(string:)))
        }.sorted { $0.start < $1.start }
    }

    // MARK: Transport

    private func url(_ path: String, _ query: [String: String] = [:]) throws -> URL {
        guard var comps = URLComponents(url: account.server.appending(path: "api/data/"), resolvingAgainstBaseURL: false) else { throw APIError.badURL }
        let parts = path.split(separator: "?", maxSplits: 1)
        comps.path += parts[0]
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }.sorted { $0.name < $1.name }
        if parts.count > 1 { items += URLComponents(string: "?" + parts[1])?.queryItems ?? [] }
        if !items.isEmpty { comps.queryItems = items }
        // „+“ in Werten (z. B. Feed-URLs) sonst als Leerzeichen gelesen
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let u = comps.url else { throw APIError.badURL }
        return u
    }

    private func send(_ req: URLRequest) async throws -> Data {
        var req = req
        req.setValue(account.apiKey, forHTTPHeaderField: "Api-Key")
        req.timeoutInterval = 30
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            if code == 401 { throw APIError.invalidLogin }
            throw APIError.http(code, String(decoding: data.prefix(300), as: UTF8.self))
        }
        return data
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        let data = try await send(URLRequest(url: try url(path, query)))
        return try decode(data, path)
    }

    func post<T: Decodable>(_ path: String, _ body: [String: Any]) async throws -> T {
        var req = URLRequest(url: try url(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try decode(try await send(req), path)
    }

    private func postIgnoring(_ path: String, _ body: [String: Any]) async throws {
        var req = URLRequest(url: try url(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await send(req)
    }

    private func decode<T: Decodable>(_ data: Data, _ path: String) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            throw APIError.decoding("\(path): \(error)")
        }
    }
}

struct HomeOverview: Sendable {
    var inProgress: [Episode]
    var recent: [Episode]
}

struct ShowDetails: Decodable, Sendable {
    let podcastid: Int
    let podcastname: String?
    let description: String?
    let author: String?
    let artworkurl: String?
    let websiteurl: String?
    let feedurl: String?
    let episodecount: Int?
    let playbackspeed: Double?
    let playbackspeedcustomized: Bool?
    let notificationsenabled: Bool?
    let autodownload: Bool?
}

// MARK: - DTOs (Feldnamen wie im PinePods-JSON)

enum PPDate {
    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    static let plain: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()
    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let d = iso.date(from: s) { return d }
        return plain.date(from: String(s.prefix(19)))
    }
}

/// Kategorien kommen als {"0": "News", "1": "…"} oder gelegentlich als String
private struct Categories: Decodable {
    var list: [String] = []
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode([String: String].self) {
            list = d.sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }.map(\.value)
        } else if let s = try? c.decode(String.self) {
            list = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }
}

struct PodDTO: Decodable {
    let podcastid: Int
    let podcastname: String
    let artworkurl: String?
    let description: String?
    let episodecount: Int?
    let websiteurl: String?
    let feedurl: String
    let author: String?
    fileprivate let categories: Categories?
    let explicit: Bool?
    let episodes_played: Int?
    let newest_episode_date: String?

    func show(order: Int) -> Show {
        Show(serverID: podcastid, itunesID: nil, title: podcastname, author: author ?? "", summary: description ?? "",
             artworkURL: artworkurl.flatMap(URL.init(string:)), feedURL: URL(string: feedurl),
             websiteURL: websiteurl.flatMap(URL.init(string:)), categories: categories?.list ?? [],
             episodeCount: episodecount ?? 0, explicit: explicit ?? false,
             newestEpisodeDate: PPDate.parse(newest_episode_date), addedOrder: order, episodesPlayed: episodes_played ?? 0)
    }
}

/// Folgen-Objekt aus return_episodes / get_queued_episodes / saved / history / home_overview / get_episode_metadata
struct EpisodeDTO: Decodable {
    let episodeid: Int
    let podcastid: Int?
    let podcastname: String?
    let episodetitle: String
    let episodepubdate: String?
    let episodedescription: String?
    let episodeartwork: String?
    let artworkurl: String?
    let episodeurl: String
    let episodeduration: Int?
    let listenduration: Int?
    let completed: Bool?
    let saved: Bool?
    let is_saved: Bool?
    let queued: Bool?
    let is_queued: Bool?
    let is_video: Bool?
    let queueposition: Int?
    let feedurl: String?
    let websiteurl: String?

    func episode() -> Episode? {
        guard let audio = URL(string: episodeurl) else { return nil }
        return Episode(serverID: episodeid, showServerID: podcastid, showTitle: podcastname ?? "", title: episodetitle,
                       pubDate: PPDate.parse(episodepubdate), summaryHTML: episodedescription ?? "",
                       artworkURL: (episodeartwork ?? artworkurl).flatMap(URL.init(string:)), audioURL: audio,
                       duration: TimeInterval(episodeduration ?? 0), position: TimeInterval(listenduration ?? 0),
                       completed: completed ?? false, saved: saved ?? is_saved ?? false, queued: queued ?? is_queued ?? false,
                       isVideo: is_video ?? false, showFeedURL: feedurl.flatMap(URL.init(string:)),
                       websiteURL: websiteurl.flatMap(URL.init(string:)))
    }
}

/// podcast_episodes nutzt großgeschriebene Feldnamen
struct ShowEpisodeDTO: Decodable {
    let podcastname: String?
    let Episodetitle: String
    let Episodepubdate: String?
    let Episodedescription: String?
    let Episodeartwork: String?
    let Episodeurl: String
    let Episodeduration: Int?
    let Listenduration: Int?
    let Episodeid: Int
    let Completed: Bool?
    let saved: Bool?
    let queued: Bool?
    let is_video: Bool?

    func episode(podcastID: Int) -> Episode? {
        guard let audio = URL(string: Episodeurl) else { return nil }
        return Episode(serverID: Episodeid, showServerID: podcastID, showTitle: podcastname ?? "", title: Episodetitle,
                       pubDate: PPDate.parse(Episodepubdate), summaryHTML: Episodedescription ?? "",
                       artworkURL: Episodeartwork.flatMap(URL.init(string:)), audioURL: audio,
                       duration: TimeInterval(Episodeduration ?? 0), position: TimeInterval(Listenduration ?? 0),
                       completed: Completed ?? false, saved: saved ?? false, queued: queued ?? false, isVideo: is_video ?? false)
    }
}
