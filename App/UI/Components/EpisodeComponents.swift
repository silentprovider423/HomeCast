import SwiftUI

/// Kontextmenü einer Folge mit Apples deutschen Texten (Analyse §2 „Kontextmenüs“)
struct EpisodeMenuItems: View {
    let episode: Episode
    var showGoToShow = true
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        let e = library.current(episode)
        let synced = e.serverID != nil
        Button { player.play(e) } label: { Label("Wiedergabe", systemImage: "play") }
        if synced {
            Button { library.addToQueue(e, next: true) } label: { Label("Als Nächstes wiedergeben", systemImage: "text.line.first.and.arrowtriangle.forward") }
            Button { library.addToQueue(e, next: false) } label: { Label("Zuletzt wiedergeben", systemImage: "text.line.last.and.arrowtriangle.forward") }
            if e.queued {
                Button { library.removeFromQueue(e) } label: { Label("Aus Warteliste entfernen", systemImage: "minus.circle") }
            }
        }
        Divider()
        if synced {
            if e.saved {
                Button { library.setSaved(e, false) } label: { Label("Nicht mehr sichern", systemImage: "bookmark.slash") }
            } else {
                Button { save(e) } label: { Label("Sichern", systemImage: "bookmark") }
            }
        }
        switch downloads.state(e) {
        case .done: Button(role: .destructive) { downloads.remove(e) } label: { Label("Download entfernen", systemImage: "trash") }
        case .none: Button { downloads.download(e) } label: { Label("Laden", systemImage: "arrow.down.circle") }
        default: Button { downloads.cancel(e) } label: { Label("Download abbrechen", systemImage: "xmark.circle") }
        }
        if synced {
            if e.completed {
                Button { library.setCompleted(e, false) } label: { Label("Als ungespielt markieren", systemImage: "circle") }
            } else {
                Button { library.setCompleted(e, true) } label: { Label("Als gespielt markieren", systemImage: "checkmark.circle") }
            }
        }
        Divider()
        if showGoToShow, let s = library.show(serverID: e.showServerID) ?? library.show(feed: e.showFeedURL) {
            NavigationLink(value: Route.show(s)) { Label("Zur Sendung", systemImage: "square.stack") }
        }
        ShareLink(item: e.websiteURL ?? e.audioURL, subject: Text(e.title)) { Label("Folge teilen …", systemImage: "square.and.arrow.up") }
        Button { UIPasteboard.general.url = e.websiteURL ?? e.audioURL } label: { Label("Link kopieren", systemImage: "link") }
    }

    private func save(_ e: Episode) {
        library.setSaved(e, true)
        if AppSettings.shared.downloadWhenSaving { downloads.download(e) }
    }
}

/// Folgenzeile wie in Apples Sendungs- und Mediatheklisten
struct EpisodeRow: View {
    let episode: Episode
    var showArtwork = true
    var showShowTitle = false
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        let e = library.current(episode)
        NavigationLink(value: Route.episode(e)) {
            HStack(alignment: .top, spacing: 12) {
                if showArtwork { Artwork(url: e.artworkURL, size: 64, corner: 8, title: e.showTitle) }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(Fmt.date(e.pubDate))
                        if showShowTitle, !e.showTitle.isEmpty { Text("·"); Text(e.showTitle).lineLimit(1) }
                    }
                    .font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                    Text(e.title).font(.headline).foregroundStyle(e.completed ? .secondary : .primary).lineLimit(3)
                    let summary = ShowNotes.plain(e.summaryHTML)
                    if !summary.isEmpty {
                        Text(summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                    HStack(spacing: 10) {
                        PlayPill(episode: e)
                        StatusIcons(episode: e)
                        Spacer()
                        Menu { EpisodeMenuItems(episode: e) } label: {
                            Image(systemName: "ellipsis").font(.body.weight(.semibold)).frame(width: 32, height: 28)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(Text("Weitere Aktionen"))
                        .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.vertical, 6)
        }
        .navigationLinkIndicatorVisibility(.hidden)
        .buttonStyle(.plain)
        .contextMenu { EpisodeMenuItems(episode: e) }
        .swipeActions(edge: .leading) {
            if e.serverID != nil {
                Button { library.addToQueue(e, next: true) } label: { Label("Als Nächstes", systemImage: "text.line.first.and.arrowtriangle.forward") }
                    .tint(.indigo)
            }
        }
        .swipeActions(edge: .trailing) {
            if e.serverID != nil {
                Button { library.setCompleted(e, !e.completed) } label: {
                    Label(e.completed ? "Ungespielt" : "Gespielt", systemImage: e.completed ? "circle" : "checkmark.circle")
                }.tint(.gray)
                Button { library.setSaved(e, !e.saved) } label: { Label(e.saved ? "Nicht sichern" : "Sichern", systemImage: "bookmark") }
                    .tint(.orange)
            }
            if downloads.state(e) == .none {
                Button { downloads.download(e) } label: { Label("Laden", systemImage: "arrow.down") }.tint(.blue)
            }
        }
    }
}

/// Kapsel-Knopf „▶ 45 Min.“ / „▶ Noch 12 Min.“ mit Fortschritt
struct PlayPill: View {
    let episode: Episode
    /// Auf farbigen Karten weiß statt Akzentfarbe
    var onCard = false
    @Environment(PlayerController.self) private var player

    var body: some View {
        let isCurrent = player.episode?.id == episode.id
        let playing = isCurrent && player.isPlaying
        Button {
            if isCurrent { player.togglePlay() } else { player.play(episode) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: playing ? "pause.fill" : "play.fill").font(.caption2)
                if episode.isInProgress || isCurrent {
                    ProgressView(value: isCurrent && player.duration > 0 ? player.currentTime / player.duration : episode.progress)
                        .progressViewStyle(.linear).frame(width: 28).tint(onCard ? .white : .accentColor)
                }
                Text(isCurrent ? Fmt.remaining(max(0, player.duration - player.currentTime)) : Fmt.episodeMeta(episode))
                    .font(.caption.weight(.semibold)).monospacedDigit()
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(onCard ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(.fill.tertiary), in: Capsule())
            .foregroundStyle(onCard ? Color.white : Color.accentColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(playing ? "Anhalten" : "Wiedergabe"))
        .accessibilityIdentifier("play-pill")
    }
}

struct StatusIcons: View {
    let episode: Episode
    @Environment(DownloadManager.self) private var downloads
    var body: some View {
        HStack(spacing: 6) {
            if episode.saved { Image(systemName: "bookmark.fill") }
            if episode.queued { Image(systemName: "text.line.first.and.arrowtriangle.forward") }
            switch downloads.state(episode) {
            case .done: Image(systemName: "arrow.down.circle.fill")
            case .running(let p): ProgressView(value: p).progressViewStyle(.circular).controlSize(.mini)
            case .queued: ProgressView().controlSize(.mini)
            case .paused: Image(systemName: "pause.circle")
            case .none: EmptyView()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Große Karte für „Weiterhören“ / „Als Nächstes“ auf der Startseite
struct EpisodeCard: View {
    let episode: Episode
    var label: LocalizedStringKey? = nil
    var width: CGFloat = 230
    @Environment(LibraryStore.self) private var library
    @State private var tint: Color = .gray

    var body: some View {
        let e = library.current(episode)
        NavigationLink(value: Route.episode(e)) {
            VStack(alignment: .leading, spacing: 0) {
                Artwork(url: e.artworkURL, size: width, corner: 0, title: e.showTitle)
                VStack(alignment: .leading, spacing: 4) {
                    if let label { Text(label).font(.caption2.weight(.semibold)).textCase(.uppercase).foregroundStyle(.white.opacity(0.75)) }
                    Text(e.title).font(.subheadline.weight(.semibold)).lineLimit(2).foregroundStyle(.white)
                    Text(e.showTitle).font(.caption).lineLimit(1).foregroundStyle(.white.opacity(0.75))
                    Spacer(minLength: 4)
                    PlayPill(episode: e, onCard: true)
                }
                .padding(12)
                .frame(width: width, alignment: .topLeading)
                .frame(minHeight: 118, alignment: .top)
                .background(tint.gradient)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .task(id: e.artworkURL) {
            guard let u = e.artworkURL, let img = await ImageLoader.shared.image(u), let c = ImageLoader.averageColor(img) else {
                tint = Artwork.placeholderColor(e.showTitle); return
            }
            tint = Color(c).mix(with: .black, by: 0.25)
        }
    }
}

/// Cover-Kachel einer Sendung (Raster)
struct ShowTile: View {
    let show: Show
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Artwork(url: show.artworkURL, corner: 10, title: show.title)
            Text(show.title).font(.subheadline.weight(.medium)).lineLimit(1).foregroundStyle(.primary)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}

/// Abschnittsüberschrift mit Pfeil (wie Apples Regale)
struct ShelfHeader<Dest: Hashable>: View {
    let title: LocalizedStringKey
    var destination: Dest? = nil
    var body: some View {
        if let destination {
            NavigationLink(value: destination) {
                HStack(spacing: 4) {
                    Text(title).font(.title2.bold())
                    Image(systemName: "chevron.right").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        } else {
            Text(title).font(.title2.bold())
        }
    }
}

extension ShelfHeader where Dest == Route {
    init(_ title: LocalizedStringKey, _ destination: Route? = nil) { self.title = title; self.destination = destination }
}
