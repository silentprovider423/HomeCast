import Foundation
import Observation
import SwiftUI

/// Aktion, die beim Server ankommen muss. Ohne Netz landet sie in einer Warteschlange
/// und wird beim nächsten Abgleich nachgesendet (Analyse §5 P1.2 „offline in eine Warteschlange“).
enum PendingOp: Codable, Equatable, Sendable {
    case position(id: Int, position: Double, duration: Double)
    case completed(id: Int, value: Bool)
    case saved(id: Int, value: Bool)
    case enqueue(id: Int)
    case dequeue(id: Int)
    case bump(id: Int)
    case reorder(ids: [Int])
    case clearQueue

    /// Nur die letzte Position je Folge muss nachgesendet werden
    func supersedes(_ other: PendingOp) -> Bool {
        switch (self, other) {
        case (.position(let a, _, _), .position(let b, _, _)): return a == b
        case (.completed(let a, _), .completed(let b, _)): return a == b
        case (.saved(let a, _), .saved(let b, _)): return a == b
        case (.reorder, .reorder): return true
        default: return false
        }
    }
}

/// Mediathek: Abos, Folgen, Warteliste, Gesichert, Verlauf. Quelle der Wahrheit ist der PinePods-Server,
/// lokal liegt ein Abbild für den Offline-Betrieb.
@MainActor @Observable
final class LibraryStore {
    var account: ServerAccount?
    var shows: [Show] = []
    var episodesByShow: [Int: [Episode]] = [:]
    var queue: [Episode] = []
    var saved: [Episode] = []
    var inProgress: [Episode] = []
    var recent: [Episode] = []
    var history: [Episode] = []
    var hiddenUpNext: Set<String> = []
    var pending: [PendingOp] = []
    var isRefreshing = false
    var lastSync: Date?
    var lastError: String?
    var isOffline = false
    /// Demo-Modus für Screenshots (keine Serverzugriffe)
    var demo = false

    @ObservationIgnored private var flushing = false

    var client: PinePodsClient? { account.map { PinePodsClient(account: $0) } }
    var isLoggedIn: Bool { account != nil || demo }

    init() {
        account = Keychain.load()
        loadSnapshot()
    }

    // MARK: Anmeldung

    func login(_ acc: ServerAccount) {
        account = acc
        Keychain.save(acc)
        Task { await refresh() }
    }

    func logout() {
        Keychain.delete()
        account = nil
        shows = []; episodesByShow = [:]; queue = []; saved = []; inProgress = []; recent = []; history = []; pending = []
        try? FileManager.default.removeItem(at: Self.snapshotURL)
    }

    // MARK: Abgleich

    /// Voller Abgleich: erst ausstehende Aktionen senden, dann alles neu holen
    func refresh() async {
        guard !demo, let client, AppSettings.shared.syncEnabled else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await flushPending()
        do {
            async let s = client.shows()
            async let h = client.home()
            async let q = client.queue()
            async let sv = client.saved()
            async let hi = client.history()
            async let re = client.recentEpisodes(limit: 150)
            let (shows, home, queue, saved, history, recent) = try await (s, h, q, sv, hi, re)
            self.shows = shows
            self.queue = queue
            self.saved = saved
            self.history = history
            self.inProgress = home.inProgress.filter { !$0.completed }
            self.recent = recent
            // Zuletzt aktualisiert: neueste Folge je Sendung aus den neuen Folgen
            for i in self.shows.indices {
                let sid = self.shows[i].serverID
                if let newest = recent.filter({ $0.showServerID == sid }).compactMap(\.pubDate).max() {
                    self.shows[i].newestEpisodeDate = max(newest, self.shows[i].newestEpisodeDate ?? .distantPast)
                }
            }
            lastSync = .now
            lastError = nil
            isOffline = false
            saveSnapshot()
        } catch {
            isOffline = APIError.isOffline(error)
            lastError = isOffline ? nil : error.localizedDescription
        }
    }

    /// Folgen einer abonnierten Sendung laden (erste Seite oder weitere)
    func loadEpisodes(showID: Int, more: Bool = false, oldestFirst: Bool = false) async -> Int {
        guard !demo, let client else { return episodesByShow[showID]?.count ?? 0 }
        let offset = more ? (episodesByShow[showID]?.count ?? 0) : 0
        do {
            let r = try await client.episodes(podcastID: showID, limit: 60, offset: offset, oldestFirst: oldestFirst)
            let merged = r.episodes.map(applyPending)
            episodesByShow[showID] = more ? (episodesByShow[showID] ?? []) + merged : merged
            if !more { saveSnapshot() }
            return r.total
        } catch {
            isOffline = APIError.isOffline(error)
            return episodesByShow[showID]?.count ?? 0
        }
    }

    // MARK: Abgeleitete Listen

    /// „Als Nächstes“ der Startseite: neueste ungespielte Folge jeder Sendung (ohne laufende), selbst gerechnet
    var upNext: [Episode] {
        var seen = Set<Int>()
        let progressIDs = Set(inProgress.map(\.id))
        return recent.sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }.filter { e in
            guard let sid = e.showServerID, !e.completed, !progressIDs.contains(e.id), !hiddenUpNext.contains(e.id) else { return false }
            return seen.insert(sid).inserted
        }
    }

    /// Weiterhören (laufende Folgen), ohne ausgeblendete
    var continueListening: [Episode] { inProgress.filter { !hiddenUpNext.contains($0.id) && !$0.completed } }

    func show(serverID: Int?) -> Show? { shows.first { $0.serverID == serverID && serverID != nil } }
    func show(feed: URL?) -> Show? {
        guard let feed else { return nil }
        let key = Self.normalize(feed)
        return shows.first { $0.feedURL.map(Self.normalize) == key }
    }
    static func normalize(_ u: URL) -> String {
        u.absoluteString.lowercased().replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Aktueller Stand einer Folge aus allen Listen (für Ansichten, die eine alte Kopie halten)
    func current(_ e: Episode) -> Episode {
        if let sid = e.showServerID, let hit = episodesByShow[sid]?.first(where: { $0.id == e.id }) { return hit }
        for list in [queue, inProgress, saved, recent, history] { if let hit = list.first(where: { $0.id == e.id }) { return hit } }
        return e
    }

    // MARK: Aktionen (optimistisch lokal, dann Server)

    func setCompleted(_ e: Episode, _ value: Bool) {
        mutate(e) { $0.completed = value; if value { $0.position = 0 } }
        if value { inProgress.removeAll { $0.id == e.id } }
        guard let id = e.serverID else { return }
        send(.completed(id: id, value: value))
    }

    func markAll(_ episodes: [Episode], completed: Bool) {
        for e in episodes { mutate(e) { $0.completed = completed } }
        if completed { inProgress.removeAll { x in episodes.contains { $0.id == x.id } } }
        for e in episodes { if let id = e.serverID { enqueuePending(.completed(id: id, value: completed)) } }
        Task { await flushPending() }
    }

    func setSaved(_ e: Episode, _ value: Bool) {
        mutate(e) { $0.saved = value }
        if value { if !saved.contains(where: { $0.id == e.id }) { var c = current(e); c.saved = true; saved.insert(c, at: 0) } }
        else { saved.removeAll { $0.id == e.id } }
        guard let id = e.serverID else { return }
        send(.saved(id: id, value: value))
    }

    /// „Als Nächstes wiedergeben“ (vorne) bzw. „Zuletzt wiedergeben“ (hinten)
    func addToQueue(_ e: Episode, next: Bool) {
        guard let id = e.serverID else { return }
        queue.removeAll { $0.id == e.id }
        var c = current(e); c.queued = true
        if next { queue.insert(c, at: 0) } else { queue.append(c) }
        mutate(e) { $0.queued = true }
        send(.enqueue(id: id))
        if next { send(.bump(id: id)) }
    }

    func removeFromQueue(_ e: Episode) {
        queue.removeAll { $0.id == e.id }
        mutate(e) { $0.queued = false }
        guard let id = e.serverID else { return }
        send(.dequeue(id: id))
    }

    func moveQueue(from: IndexSet, to: Int) {
        queue.move(fromOffsets: from, toOffset: to)
        send(.reorder(ids: queue.compactMap(\.serverID)))
    }

    func clearQueue() {
        for e in queue { mutate(e) { $0.queued = false } }
        queue = []
        send(.clearQueue)
    }

    /// Erste Folge der Warteliste entnehmen (für kontinuierliche Wiedergabe)
    func popQueue(after current: Episode?) -> Episode? {
        let next = queue.first { $0.id != current?.id && !$0.completed }
        if let next { removeFromQueue(next) }
        return next
    }

    func hideFromUpNext(_ e: Episode) { hiddenUpNext.insert(e.id); saveSnapshot() }

    /// Position melden (Player alle 15 s, beim Anhalten usw.)
    func reportPosition(_ e: Episode, position: TimeInterval, duration: TimeInterval) {
        mutate(e) { $0.position = position; if duration > 0 { $0.duration = duration } }
        if position > 5, !inProgress.contains(where: { $0.id == e.id }) {
            var c = current(e); c.position = position
            inProgress.insert(c, at: 0)
        }
        guard let id = e.serverID else { return }
        send(.position(id: id, position: position, duration: duration))
    }

    /// Hat das Gerät eine noch nicht gesendete Position für diese Folge? Dann gilt die lokale.
    func pendingPosition(_ e: Episode) -> TimeInterval? {
        guard let id = e.serverID else { return nil }
        for op in pending.reversed() { if case .position(id, let p, _) = op { return p } }
        return nil
    }

    // MARK: Folgen / Entfolgen

    @discardableResult
    func follow(_ show: Show) async throws -> Show {
        if demo { var s = show; s.serverID = (shows.compactMap(\.serverID).max() ?? 0) + 1; shows.append(s); return s }
        guard let client else { throw APIError.invalidLogin }
        let id = try await client.follow(show)
        var s = show; s.serverID = id
        if !shows.contains(where: { $0.serverID == id }) { shows.append(s) }
        await refresh()
        return self.show(serverID: id) ?? s
    }

    func unfollow(_ show: Show) async throws {
        guard let id = show.serverID else { return }
        shows.removeAll { $0.serverID == id }
        episodesByShow[id] = nil
        queue.removeAll { $0.showServerID == id }
        recent.removeAll { $0.showServerID == id }
        inProgress.removeAll { $0.showServerID == id }
        saveSnapshot()
        if demo { return }
        try await client?.unfollow(id)
    }

    // MARK: intern

    private func mutate(_ e: Episode, _ change: (inout Episode) -> Void) {
        func apply(_ list: inout [Episode]) { for i in list.indices where list[i].id == e.id { change(&list[i]) } }
        apply(&queue); apply(&saved); apply(&inProgress); apply(&recent); apply(&history)
        if let sid = e.showServerID, var l = episodesByShow[sid] { apply(&l); episodesByShow[sid] = l }
        else { for k in episodesByShow.keys { apply(&episodesByShow[k]!) } }
    }

    /// Lokale, noch nicht gesendete Änderungen auf frisch geladene Folgen legen
    private func applyPending(_ e: Episode) -> Episode {
        guard let id = e.serverID else { return e }
        var e = e
        for op in pending {
            switch op {
            case .position(id, let p, _): e.position = p
            case .completed(id, let v): e.completed = v
            case .saved(id, let v): e.saved = v
            default: break
            }
        }
        return e
    }

    private func send(_ op: PendingOp) {
        guard !demo else { return }
        enqueuePending(op)
        Task { await flushPending() }
    }

    private func enqueuePending(_ op: PendingOp) {
        pending.removeAll { op.supersedes($0) }
        pending.append(op)
        savePending()
    }

    /// Ausstehende Aktionen der Reihe nach senden; bei Netzfehler abbrechen und später erneut versuchen
    func flushPending() async {
        guard !flushing, let client, AppSettings.shared.syncEnabled else { return }
        flushing = true
        defer { flushing = false }
        while let op = pending.first {
            do {
                switch op {
                case .position(let id, let p, let d): try await client.recordPosition(episodeID: id, position: p, duration: d > 0 ? d : nil)
                case .completed(let id, let v): try await client.setCompleted(id, v)
                case .saved(let id, let v): try await client.setSaved(id, v)
                case .enqueue(let id): try await client.enqueue(id)
                case .dequeue(let id): try await client.dequeue(id)
                case .bump(let id): try await client.bump(id)
                case .reorder(let ids): try await client.reorderQueue(ids)
                case .clearQueue: try await client.clearQueue()
                }
                if pending.first == op { pending.removeFirst() }
                isOffline = false
            } catch {
                if APIError.isOffline(error) { isOffline = true; break }
                // Server lehnt ab (z. B. Folge gelöscht): verwerfen, damit die Schlange nicht hängt
                lastError = error.localizedDescription
                if pending.first == op { pending.removeFirst() }
            }
            savePending()
        }
    }

    // MARK: Abbild auf der Platte

    private struct Snapshot: Codable {
        var shows: [Show]; var episodesByShow: [Int: [Episode]]; var queue: [Episode]; var saved: [Episode]
        var inProgress: [Episode]; var recent: [Episode]; var history: [Episode]; var hidden: Set<String>; var lastSync: Date?
    }

    nonisolated static var supportDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    nonisolated private static var snapshotURL: URL { supportDir.appending(path: "library.json") }
    nonisolated private static var pendingURL: URL { supportDir.appending(path: "pending.json") }

    func saveSnapshot() {
        guard !demo else { return }
        let s = Snapshot(shows: shows, episodesByShow: episodesByShow, queue: queue, saved: saved, inProgress: inProgress,
                         recent: recent, history: history, hidden: hiddenUpNext, lastSync: lastSync)
        Task.detached(priority: .utility) { if let d = try? JSONEncoder().encode(s) { try? d.write(to: Self.snapshotURL, options: .atomic) } }
    }

    private func loadSnapshot() {
        if let d = try? Data(contentsOf: Self.snapshotURL), let s = try? JSONDecoder().decode(Snapshot.self, from: d) {
            shows = s.shows; episodesByShow = s.episodesByShow; queue = s.queue; saved = s.saved; inProgress = s.inProgress
            recent = s.recent; history = s.history; hiddenUpNext = s.hidden; lastSync = s.lastSync
        }
        if let d = try? Data(contentsOf: Self.pendingURL), let p = try? JSONDecoder().decode([PendingOp].self, from: d) { pending = p }
    }

    private func savePending() {
        guard let d = try? JSONEncoder().encode(pending) else { return }
        try? d.write(to: Self.pendingURL, options: .atomic)
    }
}
