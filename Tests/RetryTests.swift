import XCTest
@testable import HomeCast

/// Neuversuche nach Verbindungsfehlern (erster Start: iOS fragt nach dem lokalen Netzwerk)
@MainActor final class RetryTests: XCTestCase {
    func testRetriesConnectionErrorsThenSucceeds() async throws {
        var calls = 0
        let r: Int = try await ConnectionRetry.run(delays: [0.01, 0.01, 0.01]) {
            calls += 1
            if calls < 3 { throw URLError(.cannotConnectToHost) }
            return 42
        }
        XCTAssertEqual(r, 42)
        XCTAssertEqual(calls, 3)
    }

    func testGivesUpAfterLastDelay() async {
        var calls = 0
        do {
            _ = try await ConnectionRetry.run(delays: [0.01, 0.01, 0.01]) { () async throws -> Int in calls += 1; throw URLError(.timedOut) }
            XCTFail("hätte scheitern müssen")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertEqual(calls, 4, "1 Versuch + 3 Neuversuche")
    }

    func testWrongPasswordFailsImmediately() async {
        var calls = 0
        do {
            _ = try await ConnectionRetry.run(delays: [5, 5, 5]) { () async throws -> Int in calls += 1; throw APIError.invalidLogin }
            XCTFail("hätte scheitern müssen")
        } catch {
            XCTAssertEqual(error as? APIError, .invalidLogin)
        }
        XCTAssertEqual(calls, 1)
    }

    func testWakeShortensWait() async throws {
        var calls = 0
        let start = Date()
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(200)); RetryWaker.shared.wake() }
        let r: Int = try await ConnectionRetry.run(delays: [30]) {
            calls += 1
            if calls == 1 { throw URLError(.notConnectedToInternet) }
            return 1
        }
        XCTAssertEqual(r, 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "App wieder aktiv → sofort neu versucht")
    }

    /// Abgleich: erst offline (Server nicht erreichbar), dann holt der automatische Neuversuch die Mediathek
    func testLibrarySyncRetriesAutomatically() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let s = env["PODCAST_SERVER"].flatMap(URL.init(string:)), let key = env["PODCAST_API_KEY"] else {
            throw XCTSkip("Kein Test-Backend konfiguriert")
        }
        let real = try await PinePodsClient.account(server: s, apiKey: key)
        let lib = LibraryStore()
        lib.pending = []
        lib.shows = []
        lib.retryDelays = [0.3, 0.3, 0.3]
        lib.account = ServerAccount(server: URL(string: "http://127.0.0.1:9")!, apiKey: "x", userID: real.userID, username: "")
        await lib.refresh()
        XCTAssertTrue(lib.isOffline)
        XCTAssertNil(lib.lastError, "offline: kein Fehlerdialog, nur Status")
        lib.account = real   // Netz „wieder da“
        for _ in 0..<50 where lib.isOffline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(lib.isOffline)
        XCTAssertFalse(lib.shows.isEmpty)
    }
}
