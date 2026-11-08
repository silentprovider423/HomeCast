import Foundation
import Observation

/// Folgen aufs Gerät laden (Hintergrund-URLSession), offline abspielen (Analyse #46–#50, #108–#110)
@MainActor @Observable
final class DownloadManager: NSObject {
    static let shared = DownloadManager()

    struct Record: Codable, Sendable {
        var episode: Episode
        var fileName: String
        var bytes: Int64
        var date: Date
        /// Zeitpunkt, an dem die Folge fertig gehört wurde (für „Gespielte Downloads entfernen“)
        var playedAt: Date?
    }

    enum State: Equatable { case none, queued, running(Double), paused, done }

    private(set) var records: [String: Record] = [:]
    private(set) var progress: [String: Double] = [:]
    private(set) var paused: Set<String> = []
    /// Episoden, die gerade laden (für „Geladen“ → Laufende Downloads)
    private(set) var active: [String: Episode] = [:]
    /// Rückfrage wegen Mobilfunk (Episode wartet auf Bestätigung)
    var cellularPrompt: Episode?

    /// Episoden laufender Downloads auf der Platte, damit ein Download einen App-Neustart übersteht
    @ObservationIgnored private var pendingEpisodes: [String: Episode] = (try? JSONDecoder().decode([String: Episode].self, from: Data(contentsOf: DownloadManager.activeURL))) ?? [:]
    @ObservationIgnored private var resumeData: [String: Data] = [:]
    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]
    @ObservationIgnored var backgroundCompletion: (() -> Void)?
    @ObservationIgnored private lazy var session: URLSession = makeSession(cellular: true)
    @ObservationIgnored private lazy var wifiSession: URLSession = makeSession(cellular: false)

    private static var dir: URL {
        let d = LibraryStore.supportDir.appending(path: "Downloads", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        var dd = d; try? dd.setResourceValues(rv)
        return d
    }
    private static var indexURL: URL { LibraryStore.supportDir.appending(path: "downloads.json") }
    nonisolated static var activeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "downloads-active.json")
    }

    private override init() {
        super.init()
        if let d = try? Data(contentsOf: Self.indexURL), let r = try? JSONDecoder().decode([String: Record].self, from: d) {
            records = r.filter { FileManager.default.fileExists(atPath: Self.dir.appending(path: $0.value.fileName).path) }
        }
        // Laufende Hintergrund-Downloads nach App-Neustart wieder aufnehmen
        for s in [session, wifiSession] {
            Self.restoreTasks(s) { tasks in
                for t in tasks {
                    guard let key = t.taskDescription else { continue }
                    self.tasks[key] = t
                    self.progress[key] = self.progress[key] ?? 0
                    if let ep = self.pendingEpisodes[key] { self.active[key] = ep }
                }
            }
        }
    }

    /// URLSession ruft den Block auf einer Hintergrund-Queue auf: außerhalb des MainActors erzeugen
    nonisolated private static func restoreTasks(_ s: URLSession, _ apply: @escaping @MainActor ([URLSessionDownloadTask]) -> Void) {
        s.getAllTasks { tasks in
            let downloads = tasks.compactMap { $0 as? URLSessionDownloadTask }
            Task { @MainActor in apply(downloads) }
        }
    }

    nonisolated private static func cancelKeepingData(_ t: URLSessionDownloadTask, _ apply: @escaping @MainActor (Data?) -> Void) {
        t.cancel { data in Task { @MainActor in apply(data) } }
    }

    private func makeSession(cellular: Bool) -> URLSession {
        let id = "org.homeroll.homecast.downloads" + (cellular ? "" : ".wifi")
        let cfg = URLSessionConfiguration.background(withIdentifier: id)
        cfg.allowsCellularAccess = cellular
        cfg.sessionSendsLaunchEvents = true
        cfg.isDiscretionary = false
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    // MARK: Abfragen

    func state(_ e: Episode) -> State {
        if records[e.id] != nil { return .done }
        if paused.contains(e.id) { return .paused }
        if let p = progress[e.id] { return p > 0 ? .running(p) : .queued }
        return .none
    }

    func localURL(_ e: Episode) -> URL? {
        guard let r = records[e.id] else { return nil }
        let u = Self.dir.appending(path: r.fileName)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    var downloaded: [Episode] {
        records.values.sorted { $0.date > $1.date }.map(\.episode)
    }

    var totalBytes: Int64 { records.values.reduce(0) { $0 + $1.bytes } }

    // MARK: Aktionen

    /// Laden; `force` überspringt die Mobilfunk-Rückfrage
    func download(_ e: Episode, force: Bool = false) {
        guard records[e.id] == nil, tasks[e.id] == nil else { return }
        let policy = AppSettings.shared.cellular
        if !force, policy == .ask, NetworkMonitor.shared.isCellular { cellularPrompt = e; return }
        if !force, policy == .askOver200, NetworkMonitor.shared.isCellular, e.duration * 16_000 > 200_000_000 { cellularPrompt = e; return }
        let task = session.downloadTask(with: e.audioURL)
        task.taskDescription = e.id
        tasks[e.id] = task
        active[e.id] = e
        progress[e.id] = 0
        task.resume()
        save()
    }

    /// „Später über WLAN laden“ (Antwort auf die Mobilfunk-Rückfrage)
    func downloadOnWiFi(_ e: Episode) {
        guard records[e.id] == nil, tasks[e.id] == nil else { return }
        let task = wifiSession.downloadTask(with: e.audioURL)
        task.taskDescription = e.id
        tasks[e.id] = task
        active[e.id] = e
        progress[e.id] = 0
        task.resume()
    }

    func pause(_ e: Episode) {
        guard let t = tasks[e.id] else { return }
        Self.cancelKeepingData(t) { data in self.resumeData[e.id] = data }
        tasks[e.id] = nil
        paused.insert(e.id)
    }

    func resume(_ e: Episode) {
        paused.remove(e.id)
        if let data = resumeData.removeValue(forKey: e.id) {
            let t = session.downloadTask(withResumeData: data)
            t.taskDescription = e.id
            tasks[e.id] = t
            t.resume()
        } else {
            progress[e.id] = nil
            download(e, force: true)
        }
    }

    func cancel(_ e: Episode) {
        tasks.removeValue(forKey: e.id)?.cancel()
        progress[e.id] = nil
        active[e.id] = nil
        paused.remove(e.id)
        resumeData[e.id] = nil
    }

    func cancelAll() { for e in active.values { cancel(e) } }

    func remove(_ e: Episode) {
        cancel(e)
        if let r = records.removeValue(forKey: e.id) {
            try? FileManager.default.removeItem(at: Self.dir.appending(path: r.fileName))
        }
        save()
    }

    func removeAll(showServerID: Int?, showTitle: String) {
        for r in records.values where r.episode.showServerID == showServerID && (showServerID != nil || r.episode.showTitle == showTitle) {
            remove(r.episode)
        }
    }

    /// Folge fertig gehört → merken, nach 24 h löschen
    func markPlayed(_ e: Episode) {
        guard records[e.id] != nil else { return }
        records[e.id]?.playedAt = .now
        save()
    }

    /// „Gespielte Downloads entfernen“ (nach 24 h)
    func cleanupPlayed() {
        guard AppSettings.shared.removePlayedDownloads else { return }
        let cutoff = Date.now.addingTimeInterval(-24 * 3600)
        for r in records.values where (r.playedAt ?? .distantFuture) < cutoff { remove(r.episode) }
    }

    func updateSnapshot(_ e: Episode) {
        guard records[e.id] != nil else { return }
        records[e.id]?.episode = e
    }

    private func save() {
        if let d = try? JSONEncoder().encode(records) { try? d.write(to: Self.indexURL, options: .atomic) }
        pendingEpisodes = active
        if let d = try? JSONEncoder().encode(active) { try? d.write(to: Self.activeURL, options: .atomic) }
    }

    // MARK: Delegate-Ergebnisse (vom Hintergrund-Thread)

    fileprivate func finished(key: String, tmp: URL, response: URLResponse?) {
        let ext = Self.fileExtension(response)
        let name = "\(UInt(bitPattern: key.stableHash))." + ext
        let dest = Self.dir.appending(path: name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: tmp, to: dest)
        } catch { return }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
        guard let ep = active[key] ?? records[key]?.episode ?? pendingEpisodes[key] else { return }
        records[key] = Record(episode: ep, fileName: name, bytes: bytes, date: .now)
        progress[key] = nil
        active[key] = nil
        tasks[key] = nil
        save()
    }

    nonisolated private static func fileExtension(_ r: URLResponse?) -> String {
        let mime = (r as? HTTPURLResponse)?.mimeType ?? ""
        if mime.contains("mp4") || mime.contains("m4a") || mime.contains("aac") { return "m4a" }
        if mime.contains("video") { return "mp4" }
        let ext = r?.url?.pathExtension.lowercased() ?? ""
        return ["mp3", "m4a", "mp4", "aac", "ogg", "opus", "m4v", "mov"].contains(ext) ? ext : "mp3"
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription else { return }
        // Datei sofort sichern – sie verschwindet nach Rückkehr dieser Methode
        let keep = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try? FileManager.default.moveItem(at: location, to: keep)
        let resp = downloadTask.response
        Task { @MainActor in self.finished(key: key, tmp: keep, response: resp) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in if self.progress[key] != nil { self.progress[key] = p } }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let key = task.taskDescription else { return }
        let cancelled = (error as? URLError)?.code == .cancelled
        Task { @MainActor in
            self.tasks[key] = nil
            if !cancelled { self.progress[key] = nil; self.active[key] = nil }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in self.backgroundCompletion?(); self.backgroundCompletion = nil }
    }
}
