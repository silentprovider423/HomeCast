import SwiftUI

/// Vollbild-Player („Jetzt läuft“) mit Liquid-Glass-Steuerung
struct NowPlayingView: View {
    @Environment(PlayerController.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var tint: Color = .gray
    @State private var scrubbing: Double?
    @State private var panel: Panel?

    enum Panel: String, Identifiable { case chapters, queue; var id: String { rawValue } }

    var body: some View {
        ZStack {
            background
            if let e = player.episode {
                VStack(spacing: 0) {
                    Spacer(minLength: 24)
                    Artwork(url: player.currentChapter?.imageURL ?? e.artworkURL, corner: 14, title: e.showTitle)
                        .frame(maxWidth: player.isPlaying ? 330 : 270)
                        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                        .animation(.spring(duration: 0.45, bounce: 0.25), value: player.isPlaying)
                        .frame(height: 330)
                    Spacer(minLength: 20)
                    titles(e)
                    scrubber.padding(.top, 18)
                    controls.padding(.top, 14)
                    bottomBar.padding(.top, 22)
                    Spacer(minLength: 16)
                }
                .padding(.horizontal, 28)
                .foregroundStyle(.white)
            } else {
                ContentUnavailableView("Nichts wird abgespielt", systemImage: "waveform").foregroundStyle(.white)
            }
        }
        .environment(\.colorScheme, .dark)
        .task(id: player.episode?.id) {
            guard let u = player.episode?.artworkURL, let img = await ImageLoader.shared.image(u), let c = ImageLoader.averageColor(img) else {
                withAnimation { tint = Artwork.placeholderColor(player.episode?.showTitle ?? "") }; return
            }
            withAnimation { tint = Color(c) }
        }
        .sheet(item: $panel) { p in
            NavigationStack {
                Group {
                    switch p {
                    case .chapters: ChaptersList()
                    case .queue: QueueView(embedded: true)
                    }
                }
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fertig") { panel = nil } } }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var background: some View {
        LinearGradient(colors: [tint.mix(with: .black, by: 0.15), tint.mix(with: .black, by: 0.65)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }

    private func titles(_ e: Episode) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                if let c = player.currentChapter {
                    Text(c.title).font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                Text(e.title).font(.title3.bold()).lineLimit(2)
                Text(e.showTitle).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            Spacer()
            Menu { EpisodeMenuItems(episode: e) } label: {
                Image(systemName: "ellipsis").font(.headline).frame(width: 36, height: 36)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .accessibilityIdentifier("player-more")
        }
    }

    // MARK: Fortschritt

    private var scrubber: some View {
        let dur = max(player.duration, 1)
        let t = scrubbing ?? player.currentTime
        return VStack(spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    // Kapitelgrenzen
                    ForEach(player.chapters.dropFirst()) { c in
                        Rectangle().fill(.black.opacity(0.35)).frame(width: 2).offset(x: g.size.width * c.start / dur - 1)
                    }
                    Capsule().fill(.white.opacity(scrubbing == nil ? 0.85 : 1)).frame(width: max(0, g.size.width * min(1, t / dur)))
                }
                .frame(height: scrubbing == nil ? 7 : 12)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    // vertikal ziehen = feiner spulen (wie Apples Scrubbing-Tempo)
                    let fine = v.translation.height > 120 ? 0.25 : (v.translation.height > 60 ? 0.5 : 1)
                    let base = scrubbing ?? player.currentTime
                    let target = (v.location.x / g.size.width) * dur
                    scrubbing = fine == 1 ? target : base + (target - base) * fine
                    scrubbing = min(max(0, scrubbing!), dur)
                }.onEnded { _ in
                    if let s = scrubbing { player.seek(to: s) }
                    scrubbing = nil
                })
                .animation(.easeOut(duration: 0.15), value: scrubbing == nil)
            }
            .frame(height: 22)
            .accessibilityElement()
            .accessibilityLabel(Text("Wiedergabeposition"))
            .accessibilityValue(Text(Fmt.clock(t)))
            .accessibilityAdjustableAction { dir in
                if dir == .increment { player.skipForward() } else { player.skipBackward() }
            }
            HStack {
                Text(Fmt.clock(t))
                Spacer()
                if player.isBuffering { ProgressView().controlSize(.mini).tint(.white) }
                Spacer()
                Text("-" + Fmt.clock(max(0, player.duration - t)))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
        }
    }

    // MARK: Steuerung

    private var controls: some View {
        HStack {
            Spacer()
            Button { player.skipBackward() } label: {
                Image(systemName: "gobackward.\(AppSettings.shared.skipBackward)").font(.system(size: 34, weight: .medium))
            }
            .accessibilityLabel(Text("\(AppSettings.shared.skipBackward) Sek. zurück"))
            .accessibilityIdentifier("skip-back")
            Spacer()
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 50))
                    .frame(width: 84, height: 84)
                    .contentTransition(.symbolEffect(.replace))
            }
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityLabel(Text(player.isPlaying ? "Anhalten" : "Wiedergabe"))
            .accessibilityIdentifier("player-playpause")
            Spacer()
            Button { player.skipForward() } label: {
                Image(systemName: "goforward.\(AppSettings.shared.skipForward)").font(.system(size: 34, weight: .medium))
            }
            .accessibilityLabel(Text("\(AppSettings.shared.skipForward) Sek. vor"))
            .accessibilityIdentifier("skip-forward")
            Spacer()
        }
        .buttonStyle(.plain)
    }

    private var bottomBar: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                speedMenu
                sleepMenu
                AirPlayButton(tint: .white)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .accessibilityLabel(Text("AirPlay"))
                if !player.chapters.isEmpty {
                    roundButton("list.bullet", label: "Kapitel", id: "chapters-button") { panel = .chapters }
                }
                roundButton("text.line.first.and.arrowtriangle.forward", label: "Als Nächstes", id: "queue-button") { panel = .queue }
            }
        }
    }

    private func roundButton(_ symbol: String, label: LocalizedStringKey, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.headline).frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(id)
    }

    private var speedMenu: some View {
        Menu {
            Picker("Tempo", selection: Binding(get: { player.rate }, set: { player.setRate($0) })) {
                ForEach(PlayerController.speeds, id: \.self) { s in Text(Self.speedText(s)).tag(s) }
            }
            if player.episode?.showServerID != nil {
                Divider()
                Toggle("Eigens für diese Sendung", isOn: Binding(get: { player.rateIsCustomForShow }, set: { player.setRateCustomForShow($0) }))
            }
        } label: {
            Text(Self.speedText(player.rate)).font(.subheadline.weight(.bold).monospacedDigit())
                .frame(minWidth: 44, minHeight: 44).padding(.horizontal, 4)
                .glassEffect(.regular.interactive(), in: Capsule())
        }
        .accessibilityLabel(Text("Wiedergabetempo"))
        .accessibilityIdentifier("speed-menu")
    }

    static func speedText(_ s: Double) -> String {
        (s.formatted(.number.precision(.fractionLength(0...2)))) + "×"
    }

    private var sleepMenu: some View {
        Menu {
            if player.sleepTimer != .off {
                Button(role: .destructive) { player.cancelSleepTimer() } label: { Label("Timer ausschalten", systemImage: "xmark") }
                Divider()
            }
            Button("Wenn Folge endet") { player.setSleepTimer(.endOfEpisode) }
            if !player.chapters.isEmpty { Button("Wenn Kapitel endet") { player.setSleepTimer(.endOfChapter) } }
            Divider()
            ForEach([5, 10, 15, 30, 45, 60], id: \.self) { m in
                Button(m < 60 ? String(localized: "\(m) Minuten") : String(localized: "1 Stunde")) { player.setSleepMinutes(m) }
            }
        } label: {
            SleepLabel()
                .frame(minWidth: 44, minHeight: 44).padding(.horizontal, player.sleepTimer == .off ? 0 : 6)
                .glassEffect(.regular.interactive(), in: Capsule())
        }
        .accessibilityLabel(Text("Schlaf-Timer"))
        .accessibilityIdentifier("sleep-menu")
    }
}

/// Mond-Symbol, bei laufendem Timer mit Restzeit
private struct SleepLabel: View {
    @Environment(PlayerController.self) private var player
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 4) {
                Image(systemName: player.sleepTimer == .off ? "moon.zzz" : "moon.zzz.fill").font(.headline)
                if let r = player.sleepRemaining { Text(Fmt.clock(r)).font(.caption.monospacedDigit().weight(.semibold)) }
                else if player.sleepTimer == .endOfEpisode { Text("Folge").font(.caption.weight(.semibold)) }
                else if player.sleepTimer == .endOfChapter { Text("Kapitel").font(.caption.weight(.semibold)) }
            }
        }
    }
}

/// Kapitelliste im Player
struct ChaptersList: View {
    @Environment(PlayerController.self) private var player
    var body: some View {
        List {
            ForEach(Array(player.chapters.enumerated()), id: \.element.id) { i, c in
                Button { player.seek(to: c.start); player.resume() } label: {
                    HStack(spacing: 12) {
                        if let img = c.imageURL { Artwork(url: img, size: 44, corner: 6) }
                        VStack(alignment: .leading) {
                            Text(c.title.isEmpty ? String(localized: "Kapitel \(i + 1)") : c.title).lineLimit(2)
                                .fontWeight(player.currentChapter == c ? .semibold : .regular)
                            Text(Fmt.clock(c.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if player.currentChapter == c { Image(systemName: "waveform").foregroundStyle(Color.accentColor).symbolEffect(.variableColor, isActive: player.isPlaying) }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Kapitel")
        .navigationBarTitleDisplayMode(.inline)
    }
}
