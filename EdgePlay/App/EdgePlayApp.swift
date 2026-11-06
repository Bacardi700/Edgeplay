// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

@main
struct EdgePlayApp: App {
    @StateObject private var store = ConsoleStore()

    init() {
        if rp_global_init() != 0 {
            print("chiaki failed to initialise")
        }
        NetworkMonitor.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ConsoleListView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}
