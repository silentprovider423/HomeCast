import SwiftUI

/// Einstellungen (Analyse §3.3): Gerät + Konto/Server
struct SettingsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    @State private var defaultSpeed: Double = 1
    @State private var confirmLogout = false

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section("Konto") {
                    if library.demo {
                        LabeledContent("Server", value: String(localized: "Demo"))
                    } else if let a = library.account {
                        LabeledContent("Server", value: a.server.host() ?? a.server.absoluteString)
                        if !a.username.isEmpty { LabeledContent("Benutzer", value: a.username) }
                    }
                    if let d = library.lastSync {
                        LabeledContent("Zuletzt synchronisiert", value: d.formatted(date: .abbreviated, time: .shortened))
                    }
                    if !library.pending.isEmpty {
                        LabeledContent("Ausstehende Änderungen", value: "\(library.pending.count)")
                    }
                    Toggle("Mediathek synchronisieren", isOn: $settings.syncEnabled)
                    Button("Jetzt synchronisieren") { Task { await library.refresh() } }
                        .disabled(library.isRefreshing)
                    Button("Abmelden", role: .destructive) { confirmLogout = true }
                }

                Section {
                    Picker("Vorspringen", selection: $settings.skipForward) {
                        ForEach(AppSettings.skipChoices, id: \.self) { Text("\($0) Sekunden").tag($0) }
                    }
                    Picker("Zurückspringen", selection: $settings.skipBackward) {
                        ForEach(AppSettings.skipChoices, id: \.self) { Text("\($0) Sekunden").tag($0) }
                    }
                    Picker("Externe Steuerelemente", selection: $settings.externalControls) {
                        ForEach(AppSettings.ExternalControls.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Kontinuierliche Wiedergabe", isOn: $settings.continuousPlayback)
                    Picker("Standardtempo", selection: $defaultSpeed) {
                        ForEach(PlayerController.speeds, id: \.self) { Text(NowPlayingView.speedText($0)).tag($0) }
                    }
                    .onChange(of: defaultSpeed) { _, v in Task { try? await library.client?.setDefaultSpeed(v) } }
                } header: {
                    Text("Wiedergabe")
                } footer: {
                    Text("Tasten zum Überspringen gelten auch für Sperrbildschirm und Kopfhörer. Bei „Nächste/Vorherige“ springen Kopfhörer- und Autotasten zuerst zwischen Kapiteln.")
                }

                Section("Folgen") {
                    Toggle("Gespielte Folgen ausblenden", isOn: $settings.hidePlayed)
                }

                Section {
                    Picker("Mobilfunkdownloads", selection: $settings.cellular) {
                        ForEach(AppSettings.CellularPolicy.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Beim Sichern laden", isOn: $settings.downloadWhenSaving)
                    Toggle("Gespielte Downloads entfernen", isOn: $settings.removePlayedDownloads)
                    LabeledContent("Belegt", value: ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file))
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("Gespielte Folgen werden 24 Stunden nach dem Anhören vom iPhone gelöscht.")
                }

                Section("Über") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    Link("Quellcode und Hilfe", destination: URL(string: "https://github.com/silentprovider423")!)
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .task { if let s = try? await library.client?.playbackSpeed(podcastID: nil) { defaultSpeed = s } }
            .confirmationDialog("Abmelden?", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("Abmelden", role: .destructive) {
                    player.stop()
                    library.logout()
                    dismiss()
                }
            } message: { Text("Geladene Folgen bleiben auf dem iPhone.") }
        }
    }
}
