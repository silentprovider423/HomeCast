import SwiftUI

/// Mediathek: Bereiche + „Zuletzt aktualisiert“
struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @State private var addURL = false
    @State private var urlText = ""
    @State private var addError: String?
    @State private var showSettings = false

    private var recentlyUpdated: [Show] {
        library.shows.sorted { ($0.newestEpisodeDate ?? .distantPast) > ($1.newestEpisodeDate ?? .distantPast) }
    }

    var body: some View {
        List {
            Section {
                ForEach(LibrarySection.allCases) { s in
                    NavigationLink(value: Route.library(s)) {
                        Label { Text(s.title).font(.title3) } icon: { Image(systemName: s.symbol).foregroundStyle(Color.accentColor) }
                            .badge(badge(s))
                    }
                    .accessibilityIdentifier("library-\(s.rawValue)")
                }
            }
            if !recentlyUpdated.isEmpty {
                Text("Zuletzt aktualisiert").font(.title2.bold())
                    .listRowSeparator(.hidden)
                    .padding(.top, 16)
                Section {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 18) {
                        ForEach(recentlyUpdated) { s in
                            NavigationLink(value: Route.show(s)) {
                                ShowTile(show: s, subtitle: s.newestEpisodeDate.map { Fmt.date($0) })
                            }
                            .navigationLinkIndicatorVisibility(.hidden)
                            .buttonStyle(.plain)
                            .contextMenu { ShowMenuItems(show: s) }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Mediathek")
        .refreshable { await library.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { addURL = true } label: { Label("Sendung per URL folgen …", systemImage: "link.badge.plus") }
                    Button { Task { await library.refresh() } } label: { Label("Aktualisieren", systemImage: "arrow.clockwise") }
                    Button { showSettings = true } label: { Label("Einstellungen", systemImage: "gear") }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityIdentifier("library-menu")
            }
        }
        .alert("Sendung per URL folgen", isPresented: $addURL) {
            TextField("https://…/feed.xml", text: $urlText)
                .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
            Button("Folgen") { Task { await followURL() } }
            Button("Abbrechen", role: .cancel) { urlText = "" }
        } message: { Text("Gib die RSS-Feed-Adresse der Sendung ein.") }
        .alert("Fehler", isPresented: Binding(get: { addError != nil }, set: { if !$0 { addError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(addError ?? "") }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .overlay(alignment: .top) { OfflineBanner() }
    }

    private func badge(_ s: LibrarySection) -> Int {
        switch s {
        case .shows: library.shows.count
        case .saved: library.saved.count
        case .downloaded: downloads.records.count
        default: 0
        }
    }

    private func followURL() async {
        let t = urlText.trimmingCharacters(in: .whitespaces)
        urlText = ""
        guard let url = URL(string: t.contains("://") ? t : "https://" + t) else { addError = String(localized: "Ungültige Adresse."); return }
        do {
            let r = try await FeedParser.fetch(url)
            guard !r.show.title.isEmpty else { addError = String(localized: "Unter dieser Adresse wurde kein Podcast-Feed gefunden."); return }
            try await library.follow(r.show)
        } catch { addError = error.localizedDescription }
    }
}

/// Kontextmenü einer Sendung
struct ShowMenuItems: View {
    let show: Show
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadManager.self) private var downloads
    var body: some View {
        NavigationLink(value: Route.show(show)) { Label("Sendung öffnen", systemImage: "square.stack") }
        if let link = show.websiteURL ?? show.feedURL {
            ShareLink(item: link) { Label("Sendung teilen …", systemImage: "square.and.arrow.up") }
            Button { UIPasteboard.general.url = show.feedURL ?? link } label: { Label("Link kopieren", systemImage: "link") }
        }
        Button(role: .destructive) { downloads.removeAll(showServerID: show.serverID, showTitle: show.title) } label: {
            Label("Alle Downloads entfernen", systemImage: "trash")
        }
        Button(role: .destructive) { Task { try? await library.unfollow(show) } } label: { Label("Nicht mehr folgen", systemImage: "minus.circle") }
    }
}

/// Einzelne Mediathek-Bereiche
struct LibrarySectionView: View {
    let section: LibrarySection
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @Environment(AppSettings.self) private var settings
    @State private var filter = ""

    var body: some View {
        Group {
            switch section {
            case .shows: ShowsView()
            case .saved: episodeList(library.saved, empty: "Gesicherte Folgen erscheinen hier.", symbol: "bookmark")
            case .downloaded: DownloadedView()
            case .latest: episodeList(library.recent.sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) },
                                      empty: "Neue Folgen deiner Sendungen erscheinen hier.", symbol: "list.bullet.rectangle")
            case .recentlyPlayed: episodeList(library.history, empty: "Gehörte Folgen erscheinen hier.", symbol: "clock")
            }
        }
        .navigationTitle(Text(section.title))
    }

    private func episodeList(_ list: [Episode], empty: LocalizedStringKey, symbol: String) -> some View {
        let shown = list.filter { e in
            (filter.isEmpty || e.title.localizedCaseInsensitiveContains(filter) || e.showTitle.localizedCaseInsensitiveContains(filter))
                && !(settings.hidePlayed && e.completed && section == .latest)
        }
        return List {
            ForEach(shown) { e in EpisodeRow(episode: e, showShowTitle: true) }
        }
        .listStyle(.plain)
        .overlay { if list.isEmpty { ContentUnavailableView { Label { Text(section.title) } icon: { Image(systemName: symbol) } } description: { Text(empty) } } }
        .searchable(text: $filter, prompt: Text("In der Mediathek suchen"))
        .refreshable { await library.refresh() }
    }
}

/// Sendungen als Raster oder Liste, sortierbar
struct ShowsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings
    @State private var filter = ""

    private var shows: [Show] {
        let base = library.shows.filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) || $0.author.localizedCaseInsensitiveContains(filter) }
        switch settings.librarySort {
        case "title": return base.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case "followed": return base.sorted { ($0.serverID ?? 0) > ($1.serverID ?? 0) }
        default: return base.sorted { ($0.newestEpisodeDate ?? .distantPast) > ($1.newestEpisodeDate ?? .distantPast) }
        }
    }

    var body: some View {
        @Bindable var settings = settings
        Group {
            if settings.libraryGrid {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 18) {
                        ForEach(shows) { s in
                            NavigationLink(value: Route.show(s)) { ShowTile(show: s, subtitle: s.author) }
                                .buttonStyle(.plain)
                                .contextMenu { ShowMenuItems(show: s) }
                        }
                    }
                    .padding()
                }
            } else {
                List(shows) { s in
                    NavigationLink(value: Route.show(s)) {
                        HStack(spacing: 12) {
                            Artwork(url: s.artworkURL, size: 56, corner: 8, title: s.title)
                            VStack(alignment: .leading) {
                                Text(s.title).font(.headline).lineLimit(2)
                                Text(s.author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .contextMenu { ShowMenuItems(show: s) }
                }
                .listStyle(.plain)
            }
        }
        .overlay { if library.shows.isEmpty { ContentUnavailableView("Keine Sendungen", systemImage: "square.stack") } }
        .searchable(text: $filter, prompt: Text("In der Mediathek suchen"))
        .refreshable { await library.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Darstellung", selection: $settings.libraryGrid) {
                        Label("Raster", systemImage: "square.grid.2x2").tag(true)
                        Label("Liste", systemImage: "list.bullet").tag(false)
                    }
                    Picker("Sortieren nach", selection: $settings.librarySort) {
                        Text("Aktualisierungsdatum").tag("updated")
                        Text("Titel").tag("title")
                        Text("Gefolgt am").tag("followed")
                    }
                } label: { Image(systemName: "line.3.horizontal.decrease") }
                .accessibilityIdentifier("shows-sort")
            }
        }
    }
}

/// Geladene Folgen + laufende Downloads
struct DownloadedView: View {
    @Environment(DownloadManager.self) private var downloads
    @State private var confirm = false

    var body: some View {
        List {
            if !downloads.active.isEmpty {
                Section("Wird geladen") {
                    ForEach(Array(downloads.active.values).sorted { $0.title < $1.title }) { e in
                        HStack(spacing: 12) {
                            Artwork(url: e.artworkURL, size: 44, corner: 6, title: e.showTitle)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(e.title).font(.subheadline).lineLimit(1)
                                ProgressView(value: downloads.progress[e.id] ?? 0)
                            }
                            if downloads.state(e) == .paused {
                                Button { downloads.resume(e) } label: { Image(systemName: "play.circle") }.accessibilityLabel(Text("Download fortsetzen"))
                            } else {
                                Button { downloads.pause(e) } label: { Image(systemName: "pause.circle") }.accessibilityLabel(Text("Download anhalten"))
                            }
                            Button { downloads.cancel(e) } label: { Image(systemName: "xmark.circle") }.accessibilityLabel(Text("Download abbrechen"))
                        }
                        .buttonStyle(.borderless)
                    }
                    Button("Alle abbrechen", role: .destructive) { downloads.cancelAll() }
                }
            }
            Section {
                ForEach(downloads.downloaded) { e in EpisodeRow(episode: e, showShowTitle: true) }
                    .onDelete { idx in let list = downloads.downloaded; for i in idx { downloads.remove(list[i]) } }
            } footer: {
                if !downloads.records.isEmpty {
                    Text("\(downloads.records.count) Folgen · \(ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file))")
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if downloads.records.isEmpty && downloads.active.isEmpty {
                ContentUnavailableView {
                    Label("Keine geladenen Folgen", systemImage: "arrow.down.circle")
                } description: { Text("Geladene Folgen kannst du ohne Internetverbindung hören.") }
            }
        }
    }
}
