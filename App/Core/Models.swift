import Foundation

// Datenmodell der App (entspricht grob MTPodcast / MTEpisode / MTChapter bei Apple).
// Alles Codable, damit der Zwischenspeicher für den Offline-Betrieb einfach als JSON auf die Platte geht.

/// Eine Sendung. `serverID` ist die PinePods-podcastid (nur bei abonnierten Sendungen),
/// `itunesID` kommt aus der iTunes-Suche bzw. den Charts.
struct Show: Codable, Hashable, Identifiable, Sendable {
    var serverID: Int?
    var itunesID: Int?
    var title: String
    var author: String
    var summary: String
    var artworkURL: URL?
    var feedURL: URL?
    var websiteURL: URL?
    var categories: [String]
    var episodeCount: Int
    var explicit: Bool
    var newestEpisodeDate: Date?
    var addedOrder: Int = 0
    var episodesPlayed: Int = 0

    var id: String { feedURL?.absoluteString ?? serverID.map { "pp-\($0)" } ?? itunesID.map { "it-\($0)" } ?? title }
    var isSubscribed: Bool { serverID != nil }
}

/// Eine Folge. Folgen aus dem Server tragen `serverID` (PinePods-episodeid) und werden synchronisiert;
/// Folgen aus einer reinen Vorschau (nicht abonnierte Sendung) nur lokal.
struct Episode: Codable, Hashable, Identifiable, Sendable {
    var serverID: Int?
    var showServerID: Int?
    var showTitle: String
    var title: String
    var pubDate: Date?
    var summaryHTML: String
    var artworkURL: URL?
    var audioURL: URL
    var duration: TimeInterval
    var position: TimeInterval
    var completed: Bool
    var saved: Bool
    var queued: Bool
    var isVideo: Bool = false
    var season: Int?
    var number: Int?
    var episodeType: String?
    var showFeedURL: URL?
    var websiteURL: URL?

    var id: String { serverID.map { "pp-\($0)" } ?? audioURL.absoluteString }

    /// Restzeit wie bei Apple („Noch 12 Min.“)
    var remaining: TimeInterval { max(0, duration - position) }
    var progress: Double { duration > 0 ? min(1, position / duration) : 0 }
    var isInProgress: Bool { position > 5 && !completed }
}

struct Chapter: Codable, Hashable, Identifiable, Sendable {
    var start: TimeInterval
    var title: String
    var imageURL: URL?
    var url: URL?
    var id: Double { start }
}

struct ServerAccount: Codable, Sendable, Equatable {
    var server: URL
    var apiKey: String
    var userID: Int
    var username: String
}

/// Ergebnis aus Suche / Charts (iTunes)
struct CatalogShow: Codable, Hashable, Identifiable, Sendable {
    var itunesID: Int
    var title: String
    var author: String
    var artworkURL: URL?
    var feedURL: URL?
    var genre: String?
    var id: Int { itunesID }

    func asShow() -> Show {
        Show(serverID: nil, itunesID: itunesID, title: title, author: author, summary: "", artworkURL: artworkURL,
             feedURL: feedURL, websiteURL: nil, categories: genre.map { [$0] } ?? [], episodeCount: 0, explicit: false)
    }
}

struct CatalogEpisode: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var showTitle: String
    var showItunesID: Int?
    var artworkURL: URL?
    var audioURL: URL?
    var pubDate: Date?
    var duration: TimeInterval
    var summary: String
    var feedURL: URL?
}
