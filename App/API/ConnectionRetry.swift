import Foundation

/// Neuversuche nach Verbindungsfehlern (2, 5, 15 s). Anlass: Beim allerersten Netzwerkzugriff fragt iOS nach
/// dem lokalen Netzwerk, und die laufende Anfrage scheitert, solange der Dialog offen ist.
/// Wird die App wieder aktiv (der Dialog macht sie kurz inaktiv), weckt `RetryWaker.wake()` alle Wartenden sofort.
enum ConnectionRetry {
    static let defaultDelays: [Double] = [2, 5, 15]

    /// Nur echte Verbindungsfehler werden wiederholt – falsches Passwort/Schlüssel nie.
    static func isConnectionError(_ error: Error) -> Bool {
        guard let u = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .timedOut].contains(u.code)
    }

    @MainActor static func run<T>(delays: [Double] = defaultDelays, onRetry: (@MainActor (Int) -> Void)? = nil,
                       _ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch where isConnectionError(error) && attempt < delays.count {
                if let onRetry { await onRetry(attempt + 1) }
                await RetryWaker.shared.wait(seconds: delays[attempt])
                attempt += 1
            }
        }
    }
}

/// Unterbrechbares Warten: `wake()` beendet alle laufenden Wartezeiten sofort.
@MainActor final class RetryWaker {
    static let shared = RetryWaker()
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func wait(seconds: Double) async {
        let id = UUID()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters[id] = c
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                self.waiters.removeValue(forKey: id)?.resume()
            }
        }
    }

    func wake() {
        let all = waiters
        waiters = [:]
        for c in all.values { c.resume() }
    }
}
