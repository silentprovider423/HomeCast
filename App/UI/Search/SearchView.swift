import SwiftUI

/// Suche über die iTunes-Search-API bzw. in der eigenen Mediathek
struct SearchView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case catalog, library
        var id: String { rawValue }
        var title: LocalizedStringResource { self == .catalog ? "Alle Podcasts" : "Mediathek" }
    }

    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings
    @State private var query = ""
    @State private var scope: Scope = .catalog
    @State private var shows: [CatalogShow] = []
    @State private var episodes: [CatalogEpisode] = []
    @State private var searching = false
    @State private var error: String?

    var body: some View {
        List {
            if query.isEmpty {
                if !settings.recentSearches.isEmpty {
                    Section {
                        ForEach(settings.recentSearches, id: \.self) { s in
                            Button { query = s; Task { await run() } } label: {
                                Label(s, systemImage: "magnifyingglass").foregroundStyle(.primary)
                            }
                        }
                    } header: {
                        HStack {
                            Text("Zuletzt gesucht")
                            Spacer()
                            Button("Löschen") { settings.recentSearches = [] }.font(.subheadline).textCase(nil)
                        }
                    }
                }
                Section("Kategorien durchsuchen") {
                    ForEach(CatalogClient.genres, id: \.id) { g in
                        NavigationLink(value: Route.genre(g.id, String(localized: g.name))) {
                            Label { Text(g.name) } icon: { Image(systemName: g.symbol) }
                        }
                    }
                }
            } else if scope == .library {
                libraryResults
            } else {
                if searching && shows.isEmpty { HStack { Spacer(); ProgressView(); Spacer() } }
                if let error { Text(error).foregroundStyle(.secondary) }
                if let top = shows.first {
                    Section("Topergebnis") {
                        NavigationLink(value: Route.catalogShow(top)) {
                            HStack(spacing: 14) {
                                Artwork(url: top.artworkURL, size: 90, corner: 10, title: top.title)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(top.title).font(.headline).lineLimit(2)
                                    Text(top.author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                    if library.show(feed: top.feedURL) != nil {
                                        Label("Gefolgt", systemImage: "checkmark").font(.caption).foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                        }
                        .accessibilityIdentifier("top-result")
                    }
                }
                if shows.count > 1 {
                    Section("Sendungen") {
                        ForEach(shows.dropFirst().prefix(15)) { s in
                            NavigationLink(value: Route.catalogShow(s)) {
                                HStack(spacing: 12) {
                                    Artwork(url: s.artworkURL, size: 52, corner: 8, title: s.title)
                                    VStack(alignment: .leading) {
                                        Text(s.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                        Text(s.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
                if !episodes.isEmpty {
                    Section("Folgen") {
                        ForEach(episodes.prefix(15)) { e in CatalogEpisodeRow(episode: e) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Suchen")
        .searchable(text: $query, prompt: Text("Sendungen, Folgen und mehr"))
        .searchScopes($scope) { ForEach(Scope.allCases) { Text($0.title).tag($0) } }
        .onSubmit(of: .search) { settings.addRecentSearch(query); Task { await run() } }
        .task(id: query) {
            guard scope == .catalog, query.count >= 2 else { if query.isEmpty { shows = []; episodes = [] }; return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await run()
        }
    }

    private func run() async {
        guard scope == .catalog, !query.isEmpty else { return }
        searching = true
        defer { searching = false }
        let c = CatalogClient()
        let q = query
        do {
            async let s = c.searchShows(q)
            async let e = c.searchEpisodes(q, limit: 15)
            let (rs, re) = try await (s, (try? e) ?? [])
            guard q == query else { return }
            shows = rs; episodes = re; error = nil
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    @ViewBuilder private var libraryResults: some View {
        let ss = library.shows.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.author.localizedCaseInsensitiveContains(query) }
        let all = (library.episodesByShow.values.flatMap { $0 } + library.recent + library.saved)
        var seen = Set<String>()
        let es = all.filter { $0.title.localizedCaseInsensitiveContains(query) && seen.insert($0.id).inserted }
        if ss.isEmpty && es.isEmpty { Text("Keine Ergebnisse").foregroundStyle(.secondary) }
        if !ss.isEmpty {
            Section("Sendungen") {
                ForEach(ss) { s in
                    NavigationLink(value: Route.show(s)) {
                        HStack(spacing: 12) {
                            Artwork(url: s.artworkURL, size: 52, corner: 8, title: s.title)
                            Text(s.title).font(.subheadline.weight(.semibold))
                        }
                    }
                }
            }
        }
        if !es.isEmpty {
            Section("Folgen") { ForEach(es.prefix(30)) { e in EpisodeRow(episode: e, showShowTitle: true) } }
        }
    }
}

/// Folge aus der iTunes-Suche: direkt abspielen (ohne Sync) oder zur Sendung
struct CatalogEpisodeRow: View {
    let episode: CatalogEpisode
    @Environment(PlayerController.self) private var player

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: episode.artworkURL, size: 52, corner: 8, title: episode.showTitle)
            VStack(alignment: .leading, spacing: 2) {
                Text(Fmt.date(episode.pubDate)).font(.caption2).foregroundStyle(.secondary).textCase(.uppercase)
                Text(episode.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(episode.showTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let url = episode.audioURL {
                Button {
                    player.play(Episode(serverID: nil, showServerID: nil, showTitle: episode.showTitle, title: episode.title, pubDate: episode.pubDate,
                                        summaryHTML: episode.summary, artworkURL: episode.artworkURL, audioURL: url, duration: episode.duration,
                                        position: 0, completed: false, saved: false, queued: false, showFeedURL: episode.feedURL))
                } label: { Image(systemName: "play.circle.fill").font(.title) }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .accessibilityLabel(Text("Wiedergabe"))
            }
        }
        .overlay {
            if let sid = episode.showItunesID {
                NavigationLink(value: Route.catalogShow(CatalogShow(itunesID: sid, title: episode.showTitle, author: "", artworkURL: episode.artworkURL, feedURL: episode.feedURL))) { EmptyView() }
                    .opacity(0)
                    .allowsHitTesting(false)
            }
        }
    }
}
