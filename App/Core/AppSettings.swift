import Foundation
import Observation

/// Geräte-Einstellungen (Analyse §3.3). Werte liegen in UserDefaults.
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    enum CellularPolicy: String, CaseIterable, Identifiable {
        case always, askOver200, ask
        var id: String { rawValue }
        var title: LocalizedStringResource {
            switch self {
            case .always: "Immer erlauben"
            case .askOver200: "Bei mehr als 200 MB fragen"
            case .ask: "Immer fragen"
            }
        }
    }

    enum ExternalControls: String, CaseIterable, Identifiable {
        case skip, track
        var id: String { rawValue }
        var title: LocalizedStringResource { self == .skip ? "Vorwärts/Zurück" : "Nächste/Vorherige" }
    }

    static let skipChoices = [10, 15, 30, 45, 60]

    var skipForward: Int { didSet { d.set(skipForward, forKey: "skipForward") } }
    var skipBackward: Int { didSet { d.set(skipBackward, forKey: "skipBackward") } }
    var continuousPlayback: Bool { didSet { d.set(continuousPlayback, forKey: "continuousPlayback") } }
    var hidePlayed: Bool { didSet { d.set(hidePlayed, forKey: "hidePlayed") } }
    var cellular: CellularPolicy { didSet { d.set(cellular.rawValue, forKey: "cellular") } }
    var downloadWhenSaving: Bool { didSet { d.set(downloadWhenSaving, forKey: "downloadWhenSaving") } }
    var removePlayedDownloads: Bool { didSet { d.set(removePlayedDownloads, forKey: "removePlayedDownloads") } }
    var externalControls: ExternalControls { didSet { d.set(externalControls.rawValue, forKey: "externalControls") } }
    var syncEnabled: Bool { didSet { d.set(syncEnabled, forKey: "syncEnabled") } }
    var libraryGrid: Bool { didSet { d.set(libraryGrid, forKey: "libraryGrid") } }
    var librarySort: String { didSet { d.set(librarySort, forKey: "librarySort") } }
    var recentSearches: [String] { didSet { d.set(recentSearches, forKey: "recentSearches") } }

    private init() {
        d.register(defaults: ["skipForward": 30, "skipBackward": 15, "continuousPlayback": true, "hidePlayed": false,
                              "cellular": CellularPolicy.askOver200.rawValue, "downloadWhenSaving": false,
                              "removePlayedDownloads": true, "externalControls": ExternalControls.skip.rawValue,
                              "syncEnabled": true, "libraryGrid": true, "librarySort": "updated"])
        skipForward = d.integer(forKey: "skipForward")
        skipBackward = d.integer(forKey: "skipBackward")
        continuousPlayback = d.bool(forKey: "continuousPlayback")
        hidePlayed = d.bool(forKey: "hidePlayed")
        cellular = CellularPolicy(rawValue: d.string(forKey: "cellular") ?? "") ?? .askOver200
        downloadWhenSaving = d.bool(forKey: "downloadWhenSaving")
        removePlayedDownloads = d.bool(forKey: "removePlayedDownloads")
        externalControls = ExternalControls(rawValue: d.string(forKey: "externalControls") ?? "") ?? .skip
        syncEnabled = d.bool(forKey: "syncEnabled")
        libraryGrid = d.bool(forKey: "libraryGrid")
        librarySort = d.string(forKey: "librarySort") ?? "updated"
        recentSearches = d.stringArray(forKey: "recentSearches") ?? []
    }

    func addRecentSearch(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        recentSearches.removeAll { $0.caseInsensitiveCompare(t) == .orderedSame }
        recentSearches.insert(t, at: 0)
        if recentSearches.count > 10 { recentSearches = Array(recentSearches.prefix(10)) }
    }
}
