import SwiftUI

/// Folgenansicht: Cover, Titel, Wiedergabe-Knopf mit Restzeit, Aktionen, Shownotes mit Zeitmarken
struct EpisodeView: View {
    let episode: Episode
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @State private var tint: Color = .gray

    var body: some View {
        let e = library.current(episode)
        let isCurrent = player.episode?.id == e.id
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Artwork(url: e.artworkURL, size: 120, corner: 12, title: e.showTitle)
                        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Fmt.date(e.pubDate)).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                        if let s = library.show(serverID: e.showServerID) ?? library.show(feed: e.showFeedURL) {
                            NavigationLink(value: Route.show(s)) {
                                HStack(spacing: 2) { Text(e.showTitle).lineLimit(2); Image(systemName: "chevron.right").font(.caption) }
                            }
                            .font(.subheadline.weight(.medium)).tint(.accentColor)
                        } else {
                            Text(e.showTitle).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                        }
                        if let s = e.season, let n = e.number {
                            Text("Staffel \(s), Folge \(n)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text(e.title).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        if isCurrent { player.togglePlay() } else { player.play(e) }
                    } label: {
                        Label {
                            Text(isCurrent && player.isPlaying ? "Anhalten" : (e.isInProgress ? "Fortsetzen" : "Wiedergabe"))
                        } icon: {
                            Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                        }
                        .font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent).controlSize(.large)
                    .accessibilityIdentifier("episode-play")
                    if e.serverID != nil {
                        Button { library.setSaved(e, !e.saved) } label: {
                            Image(systemName: e.saved ? "bookmark.fill" : "bookmark").frame(width: 28)
                        }
                        .buttonStyle(.glass).controlSize(.large)
                        .accessibilityLabel(Text(e.saved ? "Nicht mehr sichern" : "Sichern"))
                        .accessibilityIdentifier("episode-save")
                    }
                    downloadButton(e)
                    Menu { EpisodeMenuItems(episode: e, showGoToShow: false) } label: {
                        Image(systemName: "ellipsis").frame(width: 28, height: 22)
                    }
                    .buttonStyle(.glass).controlSize(.large)
                    .accessibilityIdentifier("episode-more")
                }
                if e.isInProgress || isCurrent {
                    let pos = isCurrent ? player.currentTime : e.position
                    let dur = isCurrent ? player.duration : e.duration
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: dur > 0 ? min(1, pos / dur) : 0)
                        Text(Fmt.remaining(max(0, dur - pos))).font(.caption).foregroundStyle(.secondary)
                    }
                } else if e.duration > 0 {
                    Text(e.completed ? String(localized: "Gespielt") : Fmt.duration(e.duration)).font(.caption).foregroundStyle(.secondary)
                }

                Divider()
                Text(ShowNotes.attributed(e.summaryHTML))
                    .font(.body)
                    .textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        if url.scheme == "homecast", let t = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value.flatMap(Double.init) {
                            // Zeitmarke in den Shownotes: Folge ab dort abspielen
                            if player.episode?.id != e.id { player.play(e, at: t) } else { player.seek(to: t); player.resume() }
                            return .handled
                        }
                        return .systemAction
                    })
            }
            .padding()
        }
        .background(alignment: .top) {
            LinearGradient(colors: [tint.opacity(0.35), .clear], startPoint: .top, endPoint: .center).ignoresSafeArea()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: e.websiteURL ?? e.audioURL, subject: Text(e.title)) { Image(systemName: "square.and.arrow.up") }
            }
        }
        .task(id: e.artworkURL) {
            guard let u = e.artworkURL, let img = await ImageLoader.shared.image(u), let c = ImageLoader.averageColor(img) else { return }
            tint = Color(c)
        }
    }

    @ViewBuilder private func downloadButton(_ e: Episode) -> some View {
        switch downloads.state(e) {
        case .none:
            Button { downloads.download(e) } label: { Image(systemName: "arrow.down").frame(width: 28) }
                .buttonStyle(.glass).controlSize(.large)
                .accessibilityLabel(Text("Laden"))
                .accessibilityIdentifier("episode-download")
        case .running(let p):
            Button { downloads.pause(e) } label: { ProgressView(value: p).progressViewStyle(.circular).frame(width: 28) }
                .buttonStyle(.glass).controlSize(.large)
                .accessibilityLabel(Text("Download anhalten"))
        case .queued:
            Button { downloads.cancel(e) } label: { ProgressView().frame(width: 28) }
                .buttonStyle(.glass).controlSize(.large)
                .accessibilityLabel(Text("Download abbrechen"))
        case .paused:
            Button { downloads.resume(e) } label: { Image(systemName: "arrow.clockwise").frame(width: 28) }
                .buttonStyle(.glass).controlSize(.large)
                .accessibilityLabel(Text("Download fortsetzen"))
        case .done:
            Button { downloads.remove(e) } label: { Image(systemName: "arrow.down.circle.fill").frame(width: 28) }
                .buttonStyle(.glass).controlSize(.large)
                .accessibilityLabel(Text("Download entfernen"))
                .accessibilityIdentifier("episode-downloaded")
        }
    }
}
