import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        MainActor.assumeIsolated { DownloadManager.shared.backgroundCompletion = completionHandler }
    }
}

@main
struct HomeCastApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var library: LibraryStore
    @State private var player: PlayerController
    @Environment(\.scenePhase) private var phase

    init() {
        let env = ProcessInfo.processInfo.environment
        #if DEBUG
        if env["HOMECAST_RESET"] == "1" {
            Keychain.delete()
            for n in ["library.json", "pending.json"] { try? FileManager.default.removeItem(at: LibraryStore.supportDir.appending(path: n)) }
        }
        #endif
        let lib = LibraryStore()
        // Als Host der Unit-Tests nichts abgleichen (die Tests bringen ihr eigenes Konto mit)
        if env["XCTestConfigurationFilePath"] != nil { lib.account = nil }
        let p = PlayerController()
        p.library = lib
        #if DEBUG
        // Debug-Start ohne Passwort-Tippen (Simulator-Tests): HOMECAST_SERVER + HOMECAST_API_KEY, bzw. HOMECAST_DEMO=1
        if env["HOMECAST_DEMO"] == "1" {
            DemoData.install(into: lib)
            if env["HOMECAST_DEMO_PLAYER"] == "1", let e = lib.inProgress.first { p.showDemo(e, chapters: DemoData.chapters) }
        } else if let s = env["HOMECAST_SERVER"].flatMap(URL.init(string:)), let key = env["HOMECAST_API_KEY"], !key.isEmpty {
            Task { @MainActor in
                if let acc = try? await PinePodsClient.account(server: s, apiKey: key) {
                    lib.login(acc)
                    // HOMECAST_AUTOPLAY=1: nach dem Abgleich eine Folge mit Cover abspielen (Absturz-/Hintergrundtest)
                    if env["HOMECAST_AUTOPLAY"] == "1" {
                        for _ in 0..<60 where lib.recent.isEmpty { try? await Task.sleep(for: .seconds(1)) }
                        if let e = lib.continueListening.first ?? lib.recent.first { p.play(e) }
                    }
                }
            }
        }
        #endif
        _library = State(initialValue: lib)
        _player = State(initialValue: p)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(player)
                .environment(DownloadManager.shared)
                .environment(AppSettings.shared)
                .tint(.accentColor)
        }
        .onChange(of: phase) { _, new in
            switch new {
            case .active:
                Task { await library.refresh() }
                DownloadManager.shared.cleanupPlayed()
            case .background:
                player.saveProgress(force: true)
            default: break
            }
        }
    }
}
