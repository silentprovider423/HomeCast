import Foundation

/// Kleiner RSS-Parser für die Vorschau nicht abonnierter Sendungen
/// (Apple: `MTFeedIngester`). Liest die üblichen iTunes- und Podcasting-2.0-Felder.
final class FeedParser: NSObject, XMLParserDelegate {
    struct Result: Sendable {
        var show: Show
        var episodes: [Episode]
        /// podcast:chapters-URL je Audio-URL
        var chapterURLs: [URL: URL]
        var serial: Bool
    }

    private var show = Show(title: "", author: "", summary: "", categories: [], episodeCount: 0, explicit: false)
    private var episodes: [Episode] = []
    private var chapterURLs: [URL: URL] = [:]
    private var serial = false
    private var path: [String] = []
    private var text = ""
    private var item: [String: String]?
    private var itemImage: String?
    private var enclosure: (url: String, type: String)?
    private var chapterURL: String?
    private var feedURL: URL?

    static func fetch(_ url: URL, session: URLSession = .shared) async throws -> Result {
        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        let (data, _) = try await session.data(for: req)
        return parse(data, feedURL: url)
    }

    static func parse(_ data: Data, feedURL: URL?) -> Result {
        let p = FeedParser()
        p.feedURL = feedURL
        let xml = XMLParser(data: data)
        xml.delegate = p
        xml.shouldProcessNamespaces = false
        xml.parse()
        p.show.feedURL = feedURL
        p.show.episodeCount = p.episodes.count
        p.show.newestEpisodeDate = p.episodes.compactMap(\.pubDate).max()
        return Result(show: p.show, episodes: p.episodes, chapterURLs: p.chapterURLs, serial: p.serial)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        path.append(name)
        text = ""
        switch name {
        case "item": item = [:]; itemImage = nil; enclosure = nil; chapterURL = nil
        case "enclosure": if let u = a["url"] { enclosure = (u, a["type"] ?? "") }
        case "itunes:image":
            if item != nil { itemImage = a["href"] } else if show.artworkURL == nil { show.artworkURL = a["href"].flatMap(URL.init(string:)) }
        case "itunes:category": if item == nil, let t = a["text"], !show.categories.contains(t) { show.categories.append(t) }
        case "podcast:chapters": if item != nil { chapterURL = a["url"] }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { path.removeLast() }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "item" {
            finishItem()
            item = nil
            return
        }
        if item != nil {
            // „description“ nicht durch eine leere zweite Fassung überschreiben
            if item?[name] == nil || !(value.isEmpty) { item?[name] = value }
            return
        }
        guard path.count >= 2, path[path.count - 2] == "channel" else {
            if name == "url", path.suffix(2).first == "image", show.artworkURL == nil { show.artworkURL = URL(string: value) }
            return
        }
        switch name {
        case "title": show.title = value
        case "itunes:author": show.author = value
        case "description", "itunes:summary": if show.summary.isEmpty { show.summary = value }
        case "link": show.websiteURL = URL(string: value)
        case "itunes:type": serial = value.lowercased() == "serial"
        case "itunes:explicit": show.explicit = ["yes", "true", "explicit"].contains(value.lowercased())
        default: break
        }
    }

    private func finishItem() {
        guard let item, let enc = enclosure, let audio = URL(string: enc.url) else { return }
        let summary = item["content:encoded"].flatMap { $0.isEmpty ? nil : $0 } ?? item["description"] ?? item["itunes:summary"] ?? ""
        let ep = Episode(serverID: nil, showServerID: nil, showTitle: show.title, title: item["title"] ?? "",
                         pubDate: item["pubDate"].flatMap(Self.rfc822), summaryHTML: summary,
                         artworkURL: itemImage.flatMap(URL.init(string:)) ?? show.artworkURL, audioURL: audio,
                         duration: Self.duration(item["itunes:duration"]), position: 0, completed: false, saved: false, queued: false,
                         isVideo: enc.type.hasPrefix("video"), season: item["itunes:season"].flatMap { Int($0) },
                         number: item["itunes:episode"].flatMap { Int($0) }, episodeType: item["itunes:episodeType"],
                         showFeedURL: feedURL, websiteURL: item["link"].flatMap(URL.init(string:)))
        if let c = chapterURL.flatMap(URL.init(string:)) { chapterURLs[audio] = c }
        episodes.append(ep)
    }

    /// itunes:duration als Sekunden oder [[HH:]MM:]SS
    static func duration(_ s: String?) -> TimeInterval {
        guard let s, !s.isEmpty else { return 0 }
        let parts = s.split(separator: ":").compactMap { Double($0) }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private static let rfcFormats = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz",
                                     "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z", "yyyy-MM-dd'T'HH:mm:ssZ"]
    nonisolated(unsafe) private static let rfcFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    static func rfc822(_ s: String) -> Date? {
        for fmt in rfcFormats {
            rfcFormatter.dateFormat = fmt
            if let d = rfcFormatter.date(from: s) { return d }
        }
        return nil
    }
}

/// Podcasting-2.0-Kapitel-JSON (`podcast:chapters`)
enum ChapterJSON {
    static func load(_ url: URL, session: URLSession = .shared) async throws -> [Chapter] {
        let (data, _) = try await session.data(from: url)
        return parse(data)
    }
    static func parse(_ data: Data) -> [Chapter] {
        struct C: Decodable { let startTime: Double?; let title: String?; let img: String?; let url: String?; let toc: Bool? }
        struct R: Decodable { let chapters: [C] }
        guard let r = try? JSONDecoder().decode(R.self, from: data) else { return [] }
        return r.chapters.filter { $0.toc != false }.compactMap { c in
            c.startTime.map { Chapter(start: $0, title: c.title ?? "", imageURL: c.img.flatMap(URL.init(string:)), url: c.url.flatMap(URL.init(string:))) }
        }.sorted { $0.start < $1.start }
    }
}
