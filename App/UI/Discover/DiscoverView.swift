import SwiftUI

/// „Neu“ / Entdecken: Charts über Apples öffentliche Feeds, Kategorien
struct DiscoverView: View {
    @State private var shows: [CatalogShow] = []
    @State private var episodes: [CatalogEpisode] = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if let error, shows.isEmpty {
                    ContentUnavailableView {
                        Label("Charts nicht verfügbar", systemImage: "chart.bar")
                    } description: { Text(error) } actions: {
                        Button("Erneut versuchen") { Task { await load() } }
                    }
                }
                if !shows.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Top-Sendungen").font(.title2.bold()).padding(.horizontal)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHGrid(rows: Array(repeating: GridItem(.fixed(72), spacing: 10), count: 3), spacing: 18) {
                                ForEach(Array(shows.prefix(30).enumerated()), id: \.element.id) { i, s in
                                    NavigationLink(value: Route.catalogShow(s)) { ChartRow(rank: i + 1, show: s) }
                                        .buttonStyle(.plain)
                                        .frame(width: 300)
                                }
                            }
                            .padding(.horizontal)
                            .scrollTargetLayout()
                        }
                        .scrollTargetBehavior(.viewAligned)
                        .accessibilityIdentifier("top-shows")
                    }
                }
                if !episodes.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Angesagte Folgen").font(.title2.bold()).padding(.horizontal)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(episodes.prefix(20)) { e in
                                    if let sid = e.showItunesID {
                                        NavigationLink(value: Route.catalogShow(CatalogShow(itunesID: sid, title: e.showTitle, author: e.showTitle, artworkURL: e.artworkURL))) {
                                            VStack(alignment: .leading, spacing: 6) {
                                                Artwork(url: e.artworkURL, corner: 12, title: e.showTitle).frame(width: 160)
                                                Text(e.title).font(.subheadline.weight(.medium)).lineLimit(2)
                                                Text(e.showTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                            .frame(width: 160)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Kategorien").font(.title2.bold()).padding(.horizontal)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(CatalogClient.genres, id: \.id) { g in
                            NavigationLink(value: Route.genre(g.id, String(localized: g.name))) {
                                GenreTile(name: String(localized: g.name), symbol: g.symbol, id: g.id)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Neu")
        .task { if !loaded { await load() } }
        .refreshable { await load() }
    }

    private func load() async {
        let c = CatalogClient()
        do {
            async let s = c.topShows(limit: 50)
            async let e = c.topEpisodes(limit: 25)
            shows = try await s
            episodes = (try? await e) ?? []
            error = nil
            loaded = true
        } catch { self.error = error.localizedDescription }
    }
}

struct ChartRow: View {
    let rank: Int
    let show: CatalogShow
    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: show.artworkURL, size: 64, corner: 8, title: show.title)
            Text("\(rank)").font(.headline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(show.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(show.genre ?? show.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

struct GenreTile: View {
    let name: String
    let symbol: String
    let id: Int
    var body: some View {
        let hue = Double(id % 37) / 37
        HStack {
            Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(2)
            Spacer()
            Image(systemName: symbol).font(.title3).foregroundStyle(.white.opacity(0.85))
        }
        .padding(14)
        .frame(height: 70)
        .background(LinearGradient(colors: [Color(hue: hue, saturation: 0.6, brightness: 0.75), Color(hue: hue, saturation: 0.8, brightness: 0.5)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Top-Sendungen einer Kategorie
struct GenreView: View {
    let genreID: Int
    let name: String
    @State private var shows: [CatalogShow] = []
    @State private var error: String?

    var body: some View {
        List {
            ForEach(Array(shows.enumerated()), id: \.element.id) { i, s in
                NavigationLink(value: Route.catalogShow(s)) { ChartRow(rank: i + 1, show: s) }
            }
        }
        .listStyle(.plain)
        .overlay {
            if shows.isEmpty {
                if let error { ContentUnavailableView("Charts nicht verfügbar", systemImage: "chart.bar", description: Text(error)) }
                else { ProgressView() }
            }
        }
        .navigationTitle(name)
        .task {
            do { shows = try await CatalogClient().topShows(genre: genreID) } catch { self.error = error.localizedDescription }
        }
    }
}
