import Foundation
import Network
import Observation

/// Advisory path status. It chooses copy and can trigger a download pass;
/// it never gates an action.
@MainActor
@Observable
final class Connectivity {
    private(set) var isOnline = true
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(
        label: "io.github.nathanstefanik.margins.connectivity",
        qos: .utility
    )

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MARGINS_OFFLINE_FIXTURE"] == "1" {
            isOnline = false
            return
        }
        #endif
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                self?.isOnline = online
            }
        }
        monitor.start(queue: queue)
    }

    nonisolated deinit {
        monitor.cancel()
    }
}
