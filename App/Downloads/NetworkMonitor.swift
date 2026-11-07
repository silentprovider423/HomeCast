import Foundation
import Network

/// Netzwerkzustand (WLAN/Mobilfunk/offline) für die Mobilfunk-Regel der Downloads
final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()
    private let monitor = NWPathMonitor()
    private(set) var isCellular = false
    private(set) var isOnline = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.isCellular = path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi)
            self?.isOnline = path.status == .satisfied
        }
        monitor.start(queue: DispatchQueue(label: "homecast.network"))
    }
}
