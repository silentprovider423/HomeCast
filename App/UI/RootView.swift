import SwiftUI

/// Navigationsziele aller Tabs
enum Route: Hashable {
    case show(Show)
    case catalogShow(CatalogShow)
    case episode(Episode)
    case library(LibrarySection)
    case genre(Int, String)
    case queue
}

enum LibrarySection: String, Hashable, CaseIterable, Identifiable {
    case shows, saved, downloaded, latest, recentlyPlayed
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .shows: "Sendungen"
        case .saved: "Gesichert"
        case .downloaded: "Geladen"
        case .latest: "Neueste Folgen"
        case .recentlyPlayed: "Zuletzt gespielt"
        }
    }
    var symbol: String {
        switch self {
        case .shows: "square.stack"
        case .saved: "bookmark"
        case .downloaded: "arrow.down.circle"
        case .latest: "list.bullet.rectangle"
        case .recentlyPlayed: "clock"
        }
    }
}

enum AppTab: Hashable { case home, discover, library, search }

struct RootView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @State private var tab: AppTab = .home
    @State private var showPlayer = false
    @Namespace private var playerNS

    var body: some View {
        if !library.isLoggedIn {
            LoginView()
        } else {
            tabs
                .sheet(isPresented: $showPlayer) {
                    NowPlayingView()
                        .presentationDragIndicator(.visible)
                        .presentationBackground(.clear)
                }
                .alert("Über Mobilfunk laden?", isPresented: Binding(get: { downloads.cellularPrompt != nil }, set: { if !$0 { downloads.cellularPrompt = nil } })) {
                    Button("Laden") { if let e = downloads.cellularPrompt { downloads.download(e, force: true) } }
                    Button("Später über WLAN") { if let e = downloads.cellularPrompt { downloads.downloadOnWiFi(e) } }
                    Button("Abbrechen", role: .cancel) {}
                } message: {
                    Text("Du bist nicht mit einem WLAN verbunden.")
                }
                .onOpenURL { url in
                    // homecast://seek?t=123 aus Shownotes
                    if url.host() == "seek", let t = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value.flatMap(Double.init) {
                        player.seek(to: t)
                    }
                }
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            Tab("Startseite", systemImage: "house.fill", value: AppTab.home) {
                NavigationStack { HomeView().withRoutes() }
            }
            Tab("Neu", systemImage: "square.grid.2x2.fill", value: AppTab.discover) {
                NavigationStack { DiscoverView().withRoutes() }
            }
            Tab("Mediathek", systemImage: "square.stack.fill", value: AppTab.library) {
                NavigationStack { LibraryView().withRoutes() }
            }
            Tab(value: AppTab.search, role: .search) {
                NavigationStack { SearchView().withRoutes() }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            MiniPlayer { showPlayer = true }
        }
    }
}

extension View {
    /// Gemeinsame Navigationsziele für jeden Stack
    func withRoutes() -> some View {
        navigationDestination(for: Route.self) { r in
            switch r {
            case .show(let s): ShowView(show: s)
            case .catalogShow(let c): ShowView(show: c.asShow())
            case .episode(let e): EpisodeView(episode: e)
            case .library(let s): LibrarySectionView(section: s)
            case .genre(let id, let name): GenreView(genreID: id, name: name)
            case .queue: QueueView()
            }
        }
    }
}
