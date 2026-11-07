import Foundation

#if DEBUG
/// Erfundene Demodaten für Screenshots (HOMECAST_DEMO=1). Keine echten Sendungen, keine Cover Dritter.
enum DemoData {
    @MainActor static func install(into lib: LibraryStore) {
        lib.demo = true
        let defs: [(String, String, String, [String])] = [
            ("Morning Signal", "Signal Studio", "A short, calm look at the day's news.", ["News"]),
            ("The Long Build", "Workbench Media", "Conversations about software that lasts.", ["Technology"]),
            ("Field Notes", "Open Lab Audio", "Scientists explain what they found and why it matters.", ["Science"]),
            ("Kitchen Table Economics", "Pocket Change", "Money questions from real life, answered plainly.", ["Business"]),
            ("Night Shift Stories", "Lantern Audio", "True stories told after dark.", ["Society & Culture"]),
            ("Trail Talk", "Basecamp", "Hiking, gear and the people you meet outside.", ["Sports"]),
        ]
        let topics = ["What changes next week", "A quiet revolution", "The case for slow tools", "Notes from the field",
                      "Why prices stick", "The night the lights went out", "Ten miles in the rain", "Small habits, big data",
                      "Questions you sent in", "Behind the numbers", "An interview with a maker", "The long way home"]
        var shows: [Show] = []
        var all: [Int: [Episode]] = [:]
        for (i, d) in defs.enumerated() {
            let sid = i + 1
            shows.append(Show(serverID: sid, itunesID: nil, title: d.0, author: d.1, summary: d.2, artworkURL: nil,
                              feedURL: URL(string: "https://example.org/demo/\(sid)/feed.xml"), websiteURL: URL(string: "https://example.org"),
                              categories: d.3, episodeCount: 40 + i * 7, explicit: false,
                              newestEpisodeDate: .now.addingTimeInterval(-Double(i) * 30_000), addedOrder: i))
            all[sid] = (0..<12).map { n in
                let id = sid * 100 + n
                return Episode(serverID: id, showServerID: sid, showTitle: d.0, title: "\(topics[(n + i) % topics.count])",
                               pubDate: .now.addingTimeInterval(-Double(n) * 86_400 * Double(i + 2) / 2 - Double(i) * 30_000),
                               summaryHTML: "<p>\(d.2)</p><p>In this episode: 00:00 Intro · 04:12 The main story · 21:30 Your questions · 38:05 Outro</p>",
                               artworkURL: nil, audioURL: URL(string: "https://example.org/demo/\(id).mp3")!,
                               duration: Double(1800 + (id * 37) % 2400), position: 0, completed: n > 6, saved: n == 2, queued: false)
            }
        }
        lib.shows = shows
        lib.episodesByShow = all
        lib.recent = all.values.flatMap { $0.prefix(3) }.sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
        var prog = [all[2]![0], all[3]![1], all[5]![0]]
        for k in prog.indices { prog[k].position = prog[k].duration * [0.35, 0.62, 0.18][k] }
        lib.inProgress = prog
        for p in prog { if let sid = p.showServerID, let idx = all[sid]?.firstIndex(where: { $0.id == p.id }) { lib.episodesByShow[sid]?[idx].position = p.position } }
        var q = [all[4]![0], all[1]![1], all[6]![2]]
        for k in q.indices { q[k].queued = true }
        lib.queue = q
        lib.saved = all.values.flatMap { $0.filter(\.saved) }
        lib.history = prog
        lib.lastSync = .now
    }

    static let chapters: [Chapter] = [
        Chapter(start: 0, title: "Intro"), Chapter(start: 252, title: "The main story"),
        Chapter(start: 1290, title: "Your questions"), Chapter(start: 2285, title: "Outro"),
    ]
}
#endif
