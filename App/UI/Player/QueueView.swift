import SwiftUI

/// Warteliste „Als Nächstes“: umsortieren, entfernen, leeren, kontinuierliche Wiedergabe
struct QueueView: View {
    var embedded = false
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player
    @Environment(AppSettings.self) private var settings
    @State private var confirmClear = false

    var body: some View {
        @Bindable var settings = settings
        List {
            if let e = player.episode {
                Section("Jetzt läuft") {
                    HStack(spacing: 12) {
                        Artwork(url: e.artworkURL, size: 48, corner: 6, title: e.showTitle)
                        VStack(alignment: .leading) {
                            Text(e.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text(e.showTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            Section {
                Toggle("Kontinuierliche Wiedergabe", isOn: $settings.continuousPlayback)
            } footer: {
                Text("Nach dem Ende einer Folge wird automatisch die nächste aus der Warteliste gespielt.")
            }
            Section {
                if library.queue.isEmpty {
                    Text("Die Warteliste ist leer. Wähle bei einer Folge „Als Nächstes wiedergeben“ oder „Zuletzt wiedergeben“.")
                        .foregroundStyle(.secondary)
                }
                ForEach(library.queue) { e in
                    Button { player.play(e) } label: {
                        HStack(spacing: 12) {
                            Artwork(url: e.artworkURL, size: 48, corner: 6, title: e.showTitle)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.title).font(.subheadline.weight(.medium)).lineLimit(2)
                                Text("\(e.showTitle) · \(Fmt.episodeMeta(e))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("queue-item")
                }
                .onMove { library.moveQueue(from: $0, to: $1) }
                .onDelete { idx in for i in idx { library.removeFromQueue(library.queue[i]) } }
            } header: {
                if !library.queue.isEmpty { Text("Warteliste: \(library.queue.count) Folgen") }
            }
        }
        .navigationTitle("Als Nächstes")
        .navigationBarTitleDisplayMode(embedded ? .inline : .large)
        .toolbar {
            if !library.queue.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Leeren", role: .destructive) { confirmClear = true }
                        .accessibilityIdentifier("queue-clear")
                }
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
        }
        .confirmationDialog("Warteliste leeren?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Warteliste leeren", role: .destructive) { library.clearQueue() }
        }
        .refreshable { await library.refresh() }
    }
}
