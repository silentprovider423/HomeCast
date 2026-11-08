import SwiftUI

/// Sendungsseite: Kopf in Cover-Farben, Folgen/Entfolgen, Filter, Folgenliste, Info
struct ShowView: View {
    let show: Show
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss

    enum Filter: String, CaseIterable, Identifiable {
        case all, unplayed, played, saved, downloaded
        var id: String { rawValue }
        var title: LocalizedStringResource {
            switch self {
            case .all: "Alle Folgen"
            case .unplayed: "Ungespielt"
            case .played: "Gespielt"
            case .saved: "Gesichert"
            case .downloaded: "Geladen"
            }
        }
    }

    @State private var resolved: Show?
    @State private var previewEpisodes: [Episode] = []
    @State private var chapterURLs: [URL: URL] = [:]
    @State private var serial = false
    @State private var total = 0
    @State private var loading = false
    @State private var filter: Filter = .all
    @State private var oldestFirst = false
    @State private var hidePlayed = AppSettings.shared.hidePlayed
    @State private var tint: Color = .gray
    @State private var expanded = false
    @State private var busy = false
    @State private var error: String?
    @State private var confirmUnfollow = false

    private var current: Show { library.show(serverID: resolved?.serverID ?? show.serverID) ?? library.show(feed: resolved?.feedURL ?? show.feedURL) ?? resolved ?? show }
    private var isFollowed: Bool { current.serverID != nil }

    private var allEpisodes: [Episode] {
        if let id = current.serverID { return library.episodesByShow[id] ?? [] }
        return oldestFirst ? previewEpisodes.reversed() : previewEpisodes
    }

    private var episodes: [Episode] {
        allEpisodes.filter { e in
            if hidePlayed && e.completed && filter != .played { return false }
            switch filter {
            case .all: return true
            case .unplayed: return !e.completed
            case .played: return e.completed
            case .saved: return e.saved
            case .downloaded: return downloads.state(e) == .done
            }
        }
    }

    var body: some View {
        List {
            header
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            Section {
                ForEach(episodes) { e in
                    EpisodeRow(episode: e, showArtwork: false)
                        .listRowBackground(Color.clear)
                }
                if loading { HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear) }
                if current.serverID != nil, allEpisodes.count < total, !loading, filter == .all {
                    Button("Weitere Folgen laden") { Task { await loadMore() } }
                        .frame(maxWidth: .infinity).listRowBackground(Color.clear)
                }
                if episodes.isEmpty && !loading {
                    Text(filter == .all ? "Keine Folgen" : "Keine passenden Folgen").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding().listRowBackground(Color.clear)
                }
            } header: {
                HStack {
                    Menu {
                        Picker("Filter", selection: $filter) { ForEach(Filter.allCases) { Text($0.title).tag($0) } }
                    } label: {
                        HStack(spacing: 4) {
                            Text(filter.title).font(.title3.bold()).foregroundStyle(.primary)
                            Image(systemName: "chevron.down").font(.subheadline.weight(.semibold))
                        }
                    }
                    .accessibilityIdentifier("episode-filter")
                    Spacer()
                    Button {
                        oldestFirst.toggle()
                        if let id = current.serverID { Task { await reload(id) } }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel(Text(oldestFirst ? "Neueste zuerst" : "Älteste zuerst"))
                }
                .textCase(nil)
                .padding(.vertical, 4)
            }
            info
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(alignment: .top) {
            LinearGradient(colors: [tint.opacity(0.65), tint.opacity(0.15), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 560).ignoresSafeArea()
        }
        .navigationTitle(current.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .refreshable { await load(refreshFeed: true) }
        .task { await load(refreshFeed: false) }
        .task(id: current.artworkURL) {
            guard let u = current.artworkURL, let img = await ImageLoader.shared.image(u), let c = ImageLoader.averageColor(img) else {
                tint = Artwork.placeholderColor(current.title); return
            }
            tint = Color(c)
        }
        .alert("Fehler", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .confirmationDialog("Nicht mehr folgen?", isPresented: $confirmUnfollow, titleVisibility: .visible) {
            Button("Nicht mehr folgen", role: .destructive) { Task { await unfollow(removeDownloads: false) } }
            Button("Nicht mehr folgen und entfernen", role: .destructive) { Task { await unfollow(removeDownloads: true) } }
        } message: { Text("Die Sendung wird aus deiner Mediathek entfernt.") }
    }

    // MARK: Kopf

    private var header: some View {
        VStack(spacing: 14) {
            Artwork(url: current.artworkURL, size: 220, corner: 14, title: current.title)
                .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
                .padding(.top, 12)
            VStack(spacing: 4) {
                Text(current.title).font(.title2.bold()).multilineTextAlignment(.center)
                if !current.author.isEmpty { Text(current.author).font(.subheadline).foregroundStyle(.secondary) }
            }
            .padding(.horizontal)
            HStack(spacing: 12) {
                Button { playLatest() } label: {
                    Label(serial ? "Erste Folge" : "Neueste Folge", systemImage: "play.fill")
                        .font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(allEpisodes.isEmpty)
                .accessibilityIdentifier("play-latest")
                followButton
            }
            .padding(.horizontal, 24)
            let summary = ShowNotes.plain(current.summary)
            if !summary.isEmpty {
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 3)
                    .padding(.horizontal, 20)
                    .onTapGesture { withAnimation { expanded.toggle() } }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder private var followButton: some View {
        if isFollowed {
            Button { confirmUnfollow = true } label: {
                Image(systemName: "checkmark").font(.headline).frame(width: 30)
            }
            .buttonStyle(.glass).controlSize(.large)
            .accessibilityLabel(Text("Gefolgt"))
            .accessibilityIdentifier("unfollow")
        } else {
            Button { Task { await follow() } } label: {
                if busy { ProgressView().frame(width: 60) } else { Label("Folgen", systemImage: "plus").font(.headline) }
            }
            .buttonStyle(.glass).controlSize(.large)
            .disabled(busy || current.feedURL == nil)
            .accessibilityIdentifier("follow")
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Info").font(.title3.bold())
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                if !current.author.isEmpty { infoRow("Anbieter", current.author) }
                if !current.categories.isEmpty { infoRow("Kategorie", current.categories.joined(separator: ", ")) }
                if current.episodeCount > 0 { infoRow("Anzahl Folgen", "\(current.episodeCount)") }
                if let d = current.newestEpisodeDate { infoRow("Zuletzt aktualisiert", d.formatted(date: .abbreviated, time: .omitted)) }
                if current.explicit { infoRow("Altersfreigabe", String(localized: "Explizit")) }
            }
            .font(.subheadline)
            if let w = current.websiteURL { Link(destination: w) { Label("Website der Sendung", systemImage: "safari") }.font(.subheadline) }
        }
        .padding(.vertical, 12)
    }

    private func infoRow(_ k: LocalizedStringKey, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if isFollowed {
                    Button(role: .destructive) { confirmUnfollow = true } label: { Label("Nicht mehr folgen", systemImage: "minus.circle") }
                } else {
                    Button { Task { await follow() } } label: { Label("Folgen", systemImage: "plus") }
                }
                if let next = allEpisodes.first(where: { !$0.completed }), next.serverID != nil {
                    Button { library.addToQueue(next, next: true) } label: { Label("Als Nächstes wiedergeben", systemImage: "text.line.first.and.arrowtriangle.forward") }
                    Button { library.addToQueue(next, next: false) } label: { Label("Zuletzt wiedergeben", systemImage: "text.line.last.and.arrowtriangle.forward") }
                }
                Divider()
                if isFollowed {
                    Button { library.markAll(episodes.filter { !$0.completed }, completed: true) } label: { Label("Alle als gespielt markieren", systemImage: "checkmark.circle") }
                    Button { library.markAll(episodes.filter(\.completed), completed: false) } label: { Label("Alle als ungespielt markieren", systemImage: "circle") }
                }
                Toggle(isOn: $hidePlayed) { Label("Gespielte Folgen ausblenden", systemImage: "eye.slash") }
                Button(role: .destructive) { downloads.removeAll(showServerID: current.serverID, showTitle: current.title) } label: {
                    Label("Alle Downloads entfernen", systemImage: "trash")
                }
                Divider()
                if isFollowed {
                    Button { Task { await load(refreshFeed: true) } } label: { Label("Aktualisieren", systemImage: "arrow.clockwise") }
                }
                if let link = current.websiteURL ?? current.feedURL {
                    ShareLink(item: link) { Label("Sendung teilen …", systemImage: "square.and.arrow.up") }
                    Button { UIPasteboard.general.url = current.feedURL ?? link } label: { Label("Link kopieren", systemImage: "link") }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityIdentifier("show-menu")
        }
    }

    // MARK: Laden

    private func load(refreshFeed: Bool) async {
        if let id = current.serverID {
            if refreshFeed { try? await library.client?.refresh(id) }
            if library.episodesByShow[id] == nil || refreshFeed { await reload(id) } else { Task { await reload(id) } }
            return
        }
        // Nicht abonniert: Feed direkt lesen (Vorschau), Feed-URL ggf. per iTunes nachschlagen
        loading = true
        defer { loading = false }
        var s = resolved ?? show
        if s.feedURL == nil, let iid = s.itunesID, let c = try? await CatalogClient().lookup(iid) {
            s.feedURL = c.feedURL
            s.artworkURL = s.artworkURL ?? c.artworkURL
            if s.categories.isEmpty, let g = c.genre { s.categories = [g] }
        }
        if let sub = library.show(feed: s.feedURL) { resolved = sub; if let id = sub.serverID { await reload(id) }; return }
        guard let feed = s.feedURL else { resolved = s; return }
        do {
            let r = try await FeedParser.fetch(feed)
            var merged = r.show
            merged.itunesID = s.itunesID
            if merged.artworkURL == nil { merged.artworkURL = s.artworkURL }
            if merged.title.isEmpty { merged.title = s.title }
            if merged.author.isEmpty { merged.author = s.author }
            resolved = merged
            previewEpisodes = r.episodes.sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
            chapterURLs = r.chapterURLs
            serial = r.serial
        } catch {
            resolved = s
            self.error = error.localizedDescription
        }
    }

    private func reload(_ id: Int) async {
        loading = library.episodesByShow[id] == nil
        total = await library.loadEpisodes(showID: id, oldestFirst: oldestFirst)
        loading = false
    }

    private func loadMore() async {
        guard let id = current.serverID else { return }
        loading = true
        total = await library.loadEpisodes(showID: id, more: true, oldestFirst: oldestFirst)
        loading = false
    }

    private func playLatest() {
        let list = allEpisodes.filter { $0.episodeType != "trailer" }
        let pick = serial ? list.min { ($0.pubDate ?? .distantFuture) < ($1.pubDate ?? .distantFuture) } : (list.first { !$0.completed } ?? list.first)
        if let e = pick { player.play(e, chapterURL: chapterURLs[e.audioURL]) }
    }

    private func follow() async {
        busy = true
        defer { busy = false }
        do {
            let s = try await library.follow(resolved ?? show)
            resolved = s
            if let id = s.serverID { await reload(id) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func unfollow(removeDownloads: Bool) async {
        let s = current
        if removeDownloads { downloads.removeAll(showServerID: s.serverID, showTitle: s.title) }
        do {
            try await library.unfollow(s)
            var r = s; r.serverID = nil; resolved = r
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
