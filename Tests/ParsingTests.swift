import XCTest
@testable import HomeCast

/// Reine Logik ohne Netz: Feed-Parser, Kapitel, Zeitformate, Shownotes, Offline-Warteschlange
final class ParsingTests: XCTestCase {
    private let feed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:podcast="https://podcastindex.org/namespace/1.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
    <channel>
      <title>Demo Show</title>
      <link>https://example.org</link>
      <description>About the show</description>
      <itunes:author>Demo Author</itunes:author>
      <itunes:type>serial</itunes:type>
      <itunes:image href="https://example.org/cover.jpg"/>
      <itunes:category text="Technology"/>
      <item>
        <title>Second</title>
        <pubDate>Tue, 03 Nov 2026 10:00:00 +0000</pubDate>
        <enclosure url="https://example.org/2.mp3" type="audio/mpeg" length="1"/>
        <itunes:duration>1:02:03</itunes:duration>
        <itunes:season>1</itunes:season><itunes:episode>2</itunes:episode>
        <description><![CDATA[<p>Hello <a href="https://example.org/x">link</a> at 12:34</p>]]></description>
        <podcast:chapters url="https://example.org/2.json" type="application/json+chapters"/>
      </item>
      <item>
        <title>First</title>
        <pubDate>Mon, 2 Nov 2026 10:00:00 GMT</pubDate>
        <enclosure url="https://example.org/1.mp3" type="audio/mpeg" length="1"/>
        <itunes:duration>754</itunes:duration>
        <itunes:episodeType>trailer</itunes:episodeType>
      </item>
    </channel>
    </rss>
    """

    func testFeedParser() {
        let r = FeedParser.parse(Data(feed.utf8), feedURL: URL(string: "https://example.org/feed.xml"))
        XCTAssertEqual(r.show.title, "Demo Show")
        XCTAssertEqual(r.show.author, "Demo Author")
        XCTAssertEqual(r.show.artworkURL?.absoluteString, "https://example.org/cover.jpg")
        XCTAssertEqual(r.show.categories, ["Technology"])
        XCTAssertTrue(r.serial)
        XCTAssertEqual(r.episodes.count, 2)
        let e = r.episodes[0]
        XCTAssertEqual(e.title, "Second")
        XCTAssertEqual(e.duration, 3723)
        XCTAssertEqual(e.season, 1)
        XCTAssertEqual(e.number, 2)
        XCTAssertNotNil(e.pubDate)
        XCTAssertNotNil(r.episodes[1].pubDate)
        XCTAssertEqual(r.episodes[1].duration, 754)
        XCTAssertEqual(r.episodes[1].episodeType, "trailer")
        XCTAssertEqual(r.chapterURLs[e.audioURL]?.absoluteString, "https://example.org/2.json")
        XCTAssertTrue(e.summaryHTML.contains("<a href"))
    }

    func testChapterJSON() {
        let json = #"{"version":"1.2.0","chapters":[{"startTime":60,"title":"B"},{"startTime":0,"title":"A","img":"https://example.org/a.jpg"},{"startTime":90,"title":"hidden","toc":false}]}"#
        let ch = ChapterJSON.parse(Data(json.utf8))
        XCTAssertEqual(ch.map(\.title), ["A", "B"])
        XCTAssertNotNil(ch[0].imageURL)
    }

    func testClockAndDuration() {
        XCTAssertEqual(Fmt.clock(0), "0:00")
        XCTAssertEqual(Fmt.clock(65), "1:05")
        XCTAssertEqual(Fmt.clock(3723), "1:02:03")
        XCTAssertEqual(FeedParser.duration("45:10"), 2710)
        XCTAssertEqual(FeedParser.duration(""), 0)
    }

    func testShowNotesTimestampsAndLinks() {
        let html = "<p>Intro 0:00, Thema 12:34 und 1:02:03 &amp; mehr: <a href=\"https://example.org/q\">Quelle</a></p>"
        let text = ShowNotes.plain(html)
        XCTAssertTrue(text.contains("& mehr"))
        let ts = ShowNotes.timestamps(in: text).map(\.seconds)
        XCTAssertEqual(ts, [0, 754, 3723])
        let a = ShowNotes.attributed(html)
        let links = a.runs.compactMap(\.link)
        XCTAssertTrue(links.contains(URL(string: "https://example.org/q")!))
        XCTAssertTrue(links.contains(URL(string: "homecast://seek?t=754")!))
        XCTAssertTrue(String(a.characters).contains("Quelle"))
        XCTAssertFalse(String(a.characters).contains("\u{E000}"))
    }

    func testPendingSupersedes() {
        XCTAssertTrue(PendingOp.position(id: 1, position: 5, duration: 0).supersedes(.position(id: 1, position: 2, duration: 0)))
        XCTAssertFalse(PendingOp.position(id: 1, position: 5, duration: 0).supersedes(.position(id: 2, position: 2, duration: 0)))
        XCTAssertFalse(PendingOp.enqueue(id: 1).supersedes(.enqueue(id: 1)))
        XCTAssertTrue(PendingOp.reorder(ids: [1]).supersedes(.reorder(ids: [2])))
    }

    func testPinePodsDates() {
        XCTAssertNotNil(PPDate.parse("2026-11-04T19:44:47"))
        XCTAssertNotNil(PPDate.parse("2026-11-04T19:44:47Z"))
        XCTAssertNil(PPDate.parse(""))
    }
}
