import SwiftUI

/// Startseite („Jetzt hören“): Weiterhören, Als Nächstes, Warteliste, neue Folgen, deine Sendungen
struct HomeView: View {
    @Environment(LibraryStore.self) private var library
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if library.shows.isEmpty && !library.isRefreshing {
                    ContentUnavailableView {
                        Label("Keine Sendungen", systemImage: "square.stack")
                    } description: {
                        Text("Folge Sendungen im Tab „Neu“ oder über die Suche. Neue Folgen erscheinen dann hier.")
                    }
                    .padding(.top, 60)
                }
                if !library.continueListening.isEmpty {
                    shelf("Weiterhören", episodes: library.continueListening, label: nil, id: "continue")
                }
                if !library.upNext.isEmpty {
                    shelf("Als Nächstes", episodes: Array(library.upNext.prefix(12)), label: "Neu", id: "upnext")
                }
                if !library.queue.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ShelfHeader("Warteliste", .queue).padding(.horizontal)
                        VStack(spacing: 0) {
                            ForEach(library.queue.prefix(3)) { e in
                                EpisodeRow(episode: e, showShowTitle: true).padding(.horizontal)
                                Divider().padding(.leading, 92)
                            }
                        }
                    }
                }
                if !library.shows.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ShelfHeader("Deine Sendungen", .library(.shows)).padding(.horizontal)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 12) {
                                ForEach(library.shows.sorted { ($0.newestEpisodeDate ?? .distantPast) > ($1.newestEpisodeDate ?? .distantPast) }) { s in
                                    NavigationLink(value: Route.show(s)) { ShowTile(show: s).frame(width: 130) }.buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                if !library.recent.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ShelfHeader("Neue Folgen", .library(.latest)).padding(.horizontal)
                        VStack(spacing: 0) {
                            ForEach(library.recent.prefix(6)) { e in
                                EpisodeRow(episode: e, showShowTitle: true).padding(.horizontal)
                                Divider().padding(.leading, 92)
                            }
                        }
                    }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Startseite")
        .refreshable { await library.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "person.crop.circle") }
                    .accessibilityLabel(Text("Einstellungen"))
                    .accessibilityIdentifier("settings-button")
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .overlay(alignment: .top) { OfflineBanner() }
    }

    private func shelf(_ title: LocalizedStringKey, episodes: [Episode], label: LocalizedStringKey?, id: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title2.bold()).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(episodes) { e in
                        EpisodeCard(episode: e, label: label ?? (e.isInProgress ? "Fortsetzen" : nil))
                            .frame(width: 230)
                            .contextMenu {
                                EpisodeMenuItems(episode: e)
                                Button { library.hideFromUpNext(e) } label: { Label("Aus „Als Nächstes“ entfernen", systemImage: "eye.slash") }
                            }
                    }
                }
                .padding(.horizontal)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .accessibilityIdentifier("shelf-\(id)")
        }
    }
}

/// Hinweis, wenn der Server nicht erreichbar ist (Aktionen werden später gesendet)
struct OfflineBanner: View {
    @Environment(LibraryStore.self) private var library
    var body: some View {
        if library.isOffline {
            Label(library.pending.isEmpty ? "Offline" : "Offline – \(library.pending.count) Änderungen warten", systemImage: "wifi.slash")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassEffect(.regular, in: Capsule())
                .padding(.top, 4)
        } else if let err = library.lastError {
            Label(err, systemImage: "exclamationmark.triangle")
                .font(.footnote).lineLimit(2)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassEffect(.regular.tint(.orange.opacity(0.3)), in: Capsule())
                .padding(.top, 4)
                .onTapGesture { library.lastError = nil }
        }
    }
}
