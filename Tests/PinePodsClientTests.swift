import XCTest
@testable import HomeCast

/// Tests gegen ein echtes PinePods-Testkonto.
/// Zugang über die Umgebung (nie im Code):  TEST_RUNNER_PODCAST_SERVER, TEST_RUNNER_PODCAST_API_KEY,
/// TEST_RUNNER_PODCAST_USER, TEST_RUNNER_PODCAST_PASSWORD (xcodebuild reicht TEST_RUNNER_-Variablen ohne Präfix durch).
@MainActor final class PinePodsClientTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    private func client() async throws -> PinePodsClient {
        guard let s = env["PODCAST_SERVER"].flatMap(URL.init(string:)), let key = env["PODCAST_API_KEY"], !key.isEmpty else {
            throw XCTSkip("Kein Test-Backend konfiguriert (PODCAST_SERVER / PODCAST_API_KEY)")
        }
        return PinePodsClient(account: try await PinePodsClient.account(server: s, apiKey: key))
    }

    private func anyEpisode(_ c: PinePodsClient, show: String? = nil) async throws -> Episode {
        let shows = try await c.shows()
        let pick = shows.first { show == nil || $0.title.localizedCaseInsensitiveContains(show!) } ?? shows.first
        let sid = try XCTUnwrap(pick?.serverID, "keine Sendung im Testkonto")
        let eps = try await c.episodes(podcastID: sid, limit: 5)
        return try XCTUnwrap(eps.episodes.first)
    }

    func testLoginWithPassword() async throws {
        guard let s = env["PODCAST_SERVER"].flatMap(URL.init(string:)), let u = env["PODCAST_USER"], let p = env["PODCAST_PASSWORD"] else {
            throw XCTSkip("Kein Passwort konfiguriert")
        }
        let acc = try await PinePodsClient.login(server: s, username: u, password: p)
        XCTAssertFalse(acc.apiKey.isEmpty)
        XCTAssertGreaterThan(acc.userID, 0)
        let ok = try await PinePodsClient(account: acc).verify()
        XCTAssertTrue(ok)
        do {
            _ = try await PinePodsClient.login(server: s, username: u, password: p + "falsch")
            XCTFail("falsches Passwort angenommen")
        } catch let e as APIError { XCTAssertEqual(e, .invalidLogin) }
    }

    func testShowsAndEpisodePaging() async throws {
        let c = try await client()
        let shows = try await c.shows()
        XCTAssertGreaterThanOrEqual(shows.count, 5, "Testkonto sollte 5–8 Sendungen haben")
        let s = try XCTUnwrap(shows.max { $0.episodeCount < $1.episodeCount })
        let id = try XCTUnwrap(s.serverID)
        let p1 = try await c.episodes(podcastID: id, limit: 10)
        let p2 = try await c.episodes(podcastID: id, limit: 10, offset: 10)
        XCTAssertEqual(p1.episodes.count, 10)
        XCTAssertGreaterThan(p1.total, 10)
        XCTAssertTrue(Set(p1.episodes.map(\.id)).isDisjoint(with: p2.episodes.map(\.id)))
        let newest = try XCTUnwrap(p1.episodes.first?.pubDate), older = try XCTUnwrap(p2.episodes.first?.pubDate)
        XCTAssertGreaterThan(newest, older)
        let oldest = try await c.episodes(podcastID: id, limit: 1, oldestFirst: true)
        let oldestDate = try XCTUnwrap(oldest.episodes.first?.pubDate)
        XCTAssertLessThan(oldestDate, older)
        let recent = try await c.recentEpisodes(limit: 20)
        XCTAssertFalse(recent.isEmpty)
        XCTAssertNotNil(recent.first?.showServerID)
    }

    func testPositionRoundTrip() async throws {
        let c = try await client()
        let e = try await anyEpisode(c)
        let id = try XCTUnwrap(e.serverID)
        try await c.recordPosition(episodeID: id, position: 321, duration: e.duration)
        let meta = try await c.episodeMetadata(id)
        XCTAssertEqual(meta?.position, 321)
        // zurückspulen muss ebenfalls ankommen
        try await c.recordPosition(episodeID: id, position: 120, duration: e.duration)
        let back = try await c.episodeMetadata(id)
        XCTAssertEqual(back?.position, 120)
        let hist = try await c.history(limit: 20)
        XCTAssertTrue(hist.contains { $0.serverID == id })
        let home = try await c.home()
        XCTAssertTrue(home.inProgress.contains { $0.serverID == id })
    }

    func testCompletedRoundTrip() async throws {
        let c = try await client()
        let ep = try await anyEpisode(c, show: "Invisible")
        let id = try XCTUnwrap(ep.serverID)
        try await c.setCompleted(id, true)
        let done = try await c.episodeMetadata(id)
        XCTAssertEqual(done?.completed, true)
        try await c.setCompleted(id, false)
        let undone = try await c.episodeMetadata(id)
        XCTAssertEqual(undone?.completed, false)
    }

    func testSavedRoundTrip() async throws {
        let c = try await client()
        let ep = try await anyEpisode(c, show: "Syntax")
        let id = try XCTUnwrap(ep.serverID)
        try await c.setSaved(id, true)
        let saved = try await c.saved().map(\.serverID)
        XCTAssertTrue(saved.contains(id))
        try await c.setSaved(id, false)
        let after = try await c.saved().map(\.serverID)
        XCTAssertFalse(after.contains(id))
    }

    func testQueueAddReorderBumpRemoveClear() async throws {
        let c = try await client()
        let shows = try await c.shows()
        let sid = try XCTUnwrap(shows.first { $0.title.contains("Podcasting") }?.serverID ?? shows.first?.serverID)
        let ids = try await c.episodes(podcastID: sid, limit: 3).episodes.compactMap(\.serverID)
        XCTAssertEqual(ids.count, 3)
        let before = try await c.queue().compactMap(\.serverID)
        try await c.clearQueue()
        let empty = try await c.queue()
        XCTAssertTrue(empty.isEmpty)
        // PinePods fügt ohne laufende Folge vorne ein (wie „Als Nächstes“)
        for id in ids { try await c.enqueue(id) }
        let q1 = try await c.queue().compactMap(\.serverID)
        XCTAssertEqual(q1, ids.reversed())
        try await c.reorderQueue([ids[2], ids[0], ids[1]])
        let q2 = try await c.queue().compactMap(\.serverID)
        XCTAssertEqual(q2, [ids[2], ids[0], ids[1]])
        try await c.bump(ids[1])
        let q3 = try await c.queue().compactMap(\.serverID)
        XCTAssertEqual(q3.first, ids[1])
        try await c.dequeue(ids[0])
        let q4 = try await c.queue().compactMap(\.serverID)
        XCTAssertFalse(q4.contains(ids[0]))
        // Ausgangszustand wiederherstellen
        try await c.clearQueue()
        for id in before.reversed() { try await c.enqueue(id) }
    }

    func testFollowAndUnfollow() async throws {
        let c = try await client()
        let found = try await CatalogClient(country: "de").searchShows("Forschergeist", limit: 3)
        let cat = try XCTUnwrap(found.first { $0.feedURL != nil })
        var show = cat.asShow()
        show.summary = "Test"
        if let existing = try await c.podcastID(feed: cat.feedURL!, title: cat.title) { try await c.unfollow(existing) }
        let id = try await c.follow(show)
        XCTAssertGreaterThan(id, 0)
        let after = try await c.shows()
        XCTAssertTrue(after.contains { $0.serverID == id })
        try await c.unfollow(id)
        let gone = try await c.shows()
        XCTAssertFalse(gone.contains { $0.serverID == id })
    }

    func testChaptersFromServer() async throws {
        let c = try await client()
        let e = try await anyEpisode(c, show: "Lage der Nation")
        let eid = try XCTUnwrap(e.serverID)
        let ch = try await c.chapters(episodeID: eid)
        XCTAssertGreaterThan(ch.count, 2, "Lage der Nation liefert Kapitel")
        XCTAssertEqual(ch.first?.start, 0)
        XCTAssertEqual(ch.map(\.start), ch.map(\.start).sorted())
    }

    func testPlaybackSpeedPerShow() async throws {
        let c = try await client()
        let all = try await c.shows()
        let sid = try XCTUnwrap(all.first?.serverID)
        try await c.setShowSpeed(1.5, podcastID: sid)
        let d = try await c.playDetails(podcastID: sid)
        XCTAssertEqual(d.speed, 1.5)
        XCTAssertTrue(d.customized)
        try await c.setShowSpeed(nil, podcastID: sid)
        let d2 = try await c.playDetails(podcastID: sid)
        XCTAssertFalse(d2.customized)
    }

    func testCatalogChartsAndSearch() async throws {
        let cat = CatalogClient(country: "de")
        let top = try await cat.topShows(limit: 10)
        XCTAssertEqual(top.count, 10)
        let genre = try await cat.topShows(genre: 1318, limit: 5)
        XCTAssertFalse(genre.isEmpty)
        let looked = try await cat.lookup(top[0].itunesID)
        XCTAssertNotNil(looked?.feedURL)
        let eps = try await cat.searchEpisodes("Lage der Nation", limit: 5)
        XCTAssertFalse(eps.isEmpty)
        XCTAssertNotNil(eps.first?.audioURL)
    }

    /// Ohne Netz landen Aktionen in der Warteschlange und werden nachgesendet
    func testOfflineQueueAndFlush() async throws {
        let real = try await client()
        let e = try await anyEpisode(real, show: "Freakonomics")
        let id = try XCTUnwrap(e.serverID)
        let lib = LibraryStore()
        lib.account = ServerAccount(server: URL(string: "http://127.0.0.1:9")!, apiKey: "x", userID: real.userID, username: "")
        lib.pending = []
        lib.setSaved(e, true)
        lib.reportPosition(e, position: 77, duration: e.duration)
        lib.reportPosition(e, position: 88, duration: e.duration)
        await lib.flushPending()
        XCTAssertTrue(lib.isOffline)
        XCTAssertEqual(lib.pending.count, 2, "Positionen werden zusammengefasst")
        XCTAssertEqual(lib.pendingPosition(e), 88)
        // Netz wieder da → nachsenden
        lib.account = real.account
        await lib.flushPending()
        XCTAssertTrue(lib.pending.isEmpty)
        let meta = try await real.episodeMetadata(id)
        XCTAssertEqual(meta?.position, 88)
        let saved = try await real.saved().map(\.serverID)
        XCTAssertTrue(saved.contains(id))
        try await real.setSaved(id, false)
    }
}
