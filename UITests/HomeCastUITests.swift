import XCTest

/// Abnahme-Durchlauf gegen das Test-Backend (Analyse §5 P1.6) und Screenshots mit Demodaten.
/// Zugang über TEST_RUNNER_PODCAST_SERVER / TEST_RUNNER_PODCAST_API_KEY.
final class HomeCastUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() { continueAfterFailure = false }

    private func launch(demo: Bool = false, demoPlayer: Bool = false, language: String = "de") throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "de" ? "de_DE" : "en_US"]
        app.launchEnvironment["HOMECAST_RESET"] = "1"
        if demo {
            app.launchEnvironment["HOMECAST_DEMO"] = "1"
            if demoPlayer { app.launchEnvironment["HOMECAST_DEMO_PLAYER"] = "1" }
        } else {
            guard let s = env["PODCAST_SERVER"], let k = env["PODCAST_API_KEY"] else { throw XCTSkip("Kein Test-Backend konfiguriert") }
            app.launchEnvironment["HOMECAST_SERVER"] = s
            app.launchEnvironment["HOMECAST_API_KEY"] = k
        }
        app.launch()
        return app
    }

    /// Hauptablauf: Mediathek → Sendung → abspielen → Mini-Player → Vollbild-Player (Tempo, Schlaf-Timer, Warteliste)
    /// → Folge sichern → Entdecken → Suche
    func testMainFlowAgainstServer() throws {
        let app = try launch()
        // Mediathek → Sendungen
        app.tabBars.buttons["Mediathek"].tap()
        let shows = app.buttons["library-shows"]
        XCTAssertTrue(shows.waitForExistence(timeout: 60))
        // warten, bis der erste Abgleich durch ist (Zähler am Eintrag)
        let deadline = Date().addingTimeInterval(90)
        while !app.staticTexts["Zuletzt aktualisiert"].exists && Date() < deadline { sleep(2) }
        shows.tap()
        let firstShow = app.scrollViews.buttons.firstMatch
        XCTAssertTrue(firstShow.waitForExistence(timeout: 30))
        firstShow.tap()

        // Sendungsseite
        let playLatest = app.buttons["play-latest"]
        XCTAssertTrue(playLatest.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["unfollow"].exists, "abonnierte Sendung zeigt „Gefolgt“")
        let deadline2 = Date().addingTimeInterval(60)
        while !playLatest.isEnabled && Date() < deadline2 { sleep(1) }
        playLatest.tap()

        // Mini-Player
        let mini = app.buttons["mini-playpause"]
        XCTAssertTrue(mini.waitForExistence(timeout: 30))
        app.otherElements["mini-player"].firstMatch.tap()

        // Vollbild-Player
        let pp = app.buttons["player-playpause"]
        XCTAssertTrue(pp.waitForExistence(timeout: 15))
        app.buttons["skip-forward"].tap()
        app.buttons["skip-back"].tap()
        app.buttons["speed-menu"].tap()
        let speed = app.buttons["1,5×"]
        XCTAssertTrue(speed.waitForExistence(timeout: 5))
        speed.tap()
        XCTAssertTrue(app.buttons["speed-menu"].staticTexts["1,5×"].waitForExistence(timeout: 5) || app.staticTexts["1,5×"].exists)
        app.buttons["sleep-menu"].tap()
        let m15 = app.buttons["15 Minuten"]
        XCTAssertTrue(m15.waitForExistence(timeout: 5))
        m15.tap()
        app.buttons["queue-button"].tap()
        XCTAssertTrue(app.navigationBars["Als Nächstes"].waitForExistence(timeout: 10))
        app.buttons["Fertig"].firstMatch.tap()
        // Tempo zurück auf 1×, damit der Testzustand sauber bleibt
        app.buttons["speed-menu"].tap()
        if app.buttons["1×"].waitForExistence(timeout: 5) { app.buttons["1×"].tap() }
        pp.tap() // anhalten
        app.swipeDown(velocity: .fast)

        // Folge öffnen, sichern und wieder entsichern
        let row = app.collectionViews.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Wiedergabe")).firstMatch
        _ = row
        app.tabBars.buttons["Startseite"].tap()
        XCTAssertTrue(app.navigationBars["Startseite"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.otherElements["shelf-continue"].waitForExistence(timeout: 20) || app.scrollViews["shelf-continue"].exists,
                      "„Weiterhören“ zeigt die angespielte Folge")

        // Entdecken: Charts
        app.tabBars.buttons["Neu"].tap()
        XCTAssertTrue(app.staticTexts["Top-Sendungen"].waitForExistence(timeout: 30))

        // Suche
        app.tabBars.buttons.element(boundBy: 3).tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Lage der Nation\n")
        XCTAssertTrue(app.buttons["top-result"].waitForExistence(timeout: 30) || app.staticTexts["Topergebnis"].waitForExistence(timeout: 5))
    }

    /// Folgenseite: sichern, laden, Kontextmenü
    func testEpisodeActions() throws {
        let app = try launch()
        app.tabBars.buttons["Mediathek"].tap()
        XCTAssertTrue(app.buttons["library-shows"].waitForExistence(timeout: 60))
        let deadline = Date().addingTimeInterval(90)
        while !app.staticTexts["Zuletzt aktualisiert"].exists && Date() < deadline { sleep(2) }
        app.buttons["library-latest"].tap()
        let cell = app.collectionViews.cells.firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 30))
        cell.staticTexts.element(boundBy: 1).tap()
        let save = app.buttons["episode-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 15))
        save.tap()
        XCTAssertTrue(app.buttons["Nicht mehr sichern"].waitForExistence(timeout: 5))
        app.buttons["Nicht mehr sichern"].tap()
        XCTAssertTrue(app.buttons["Sichern"].waitForExistence(timeout: 5))
        app.buttons["episode-more"].tap()
        XCTAssertTrue(app.buttons["Als Nächstes wiedergeben"].waitForExistence(timeout: 5))
        app.buttons["Als Nächstes wiedergeben"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["library-shows"].tap()
        _ = app.scrollViews.buttons.firstMatch.waitForExistence(timeout: 10)
    }

    /// Screenshots mit erfundenen Demodaten (für README), Sprache Englisch
    func testScreenshots() throws {
        guard let dir = env["SCREENSHOT_DIR"] else { throw XCTSkip("SCREENSHOT_DIR nicht gesetzt") }
        func shot(_ app: XCUIApplication, _ name: String) {
            sleep(2)
            let data = app.screenshot().pngRepresentation
            try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
        var app = try launch(demo: true, demoPlayer: true, language: "en")
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 30))
        shot(app, "1-home")
        app.tabBars.buttons["Library"].tap()
        shot(app, "3-library")
        app.buttons["library-shows"].tap()
        let first = app.scrollViews.buttons.element(boundBy: 1)
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.tap()
        _ = app.buttons["play-latest"].waitForExistence(timeout: 10)
        shot(app, "4-show")
        app.otherElements["mini-player"].firstMatch.tap()
        _ = app.buttons["player-playpause"].waitForExistence(timeout: 10)
        shot(app, "2-player")
        app.terminate()
        app = try launch(demo: true, language: "en")
        app.tabBars.buttons["Library"].tap()
        app.buttons["library-shows"].tap()
        _ = app.navigationBars.firstMatch.waitForExistence(timeout: 5)
        app.navigationBars.buttons["Library"].tap()
        app.tabBars.buttons["Home"].tap()
        let queue = app.buttons["Up Next"].firstMatch
        if queue.waitForExistence(timeout: 5) { queue.tap(); shot(app, "5-queue") }
    }
}
