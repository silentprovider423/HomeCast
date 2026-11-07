import SwiftUI
import AVKit

/// Mini-Player als `tabViewBottomAccessory` (iOS 26)
struct MiniPlayer: View {
    let open: () -> Void
    @Environment(PlayerController.self) private var player
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        HStack(spacing: 10) {
            if let e = player.episode {
                Artwork(url: e.artworkURL, size: 32, corner: 6, title: e.showTitle)
                VStack(alignment: .leading, spacing: 0) {
                    Text(e.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    if placement != .inline {
                        Text(player.currentChapter?.title ?? Fmt.date(e.pubDate)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3).frame(width: 34, height: 34)
                }
                .accessibilityLabel(Text(player.isPlaying ? "Anhalten" : "Wiedergabe"))
                .accessibilityIdentifier("mini-playpause")
                if placement != .inline {
                    Button { player.skipForward() } label: {
                        Image(systemName: "goforward.\(AppSettings.shared.skipForward)").font(.title3).frame(width: 34, height: 34)
                    }
                    .accessibilityLabel(Text("\(AppSettings.shared.skipForward) Sek. vor"))
                }
            } else {
                Image(systemName: "waveform").foregroundStyle(.secondary)
                Text("Nichts wird abgespielt").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture { if player.episode != nil { open() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mini-player")
    }
}

/// AirPlay-Auswahl (AVRoutePickerView)
struct AirPlayButton: UIViewRepresentable {
    var tint: UIColor = .label
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = false
        v.tintColor = tint
        v.activeTintColor = .tintColor
        return v
    }
    func updateUIView(_ v: AVRoutePickerView, context: Context) { v.tintColor = tint }
}
