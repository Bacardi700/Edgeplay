// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Network

/// Knows whether we're on mobile data, so Auto quality can pick a lighter stream.
final class NetworkMonitor {
    static let shared = NetworkMonitor()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var cellular = false

    var isCellular: Bool {
        lock.lock(); defer { lock.unlock() }
        return cellular
    }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            // Cellular only counts when it's the path in use (no Wi-Fi/wired available).
            let onCell = path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.wiredEthernet)
            self?.lock.lock(); self?.cellular = onCell; self?.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "edgeplay.network"))
    }

    /// Call early so the first answer is ready by the time the user taps Play.
    func start() {}
}
