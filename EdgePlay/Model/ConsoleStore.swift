// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Saves paired consoles and settings to Application Support (file protected,
/// excluded from iCloud backup since the keys are device pairing secrets).
@MainActor
final class ConsoleStore: ObservableObject {
    @Published var consoles: [Console] = [] { didSet { save() } }
    @Published var settings = StreamSettings() { didSet { save() } }
    /// Remembered for the next pairing, base64 form.
    @Published var psnAccountIDBase64: String = "" { didSet { save() } }

    private struct Snapshot: Codable {
        var consoles: [Console]
        var settings: StreamSettings
        var psnAccountIDBase64: String?
    }

    private let url: URL
    private var loading = false

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("edgeplay.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        loading = true
        consoles = snap.consoles
        settings = snap.settings
        psnAccountIDBase64 = snap.psnAccountIDBase64 ?? ""
        loading = false
    }

    private func save() {
        guard !loading else { return }
        let snap = Snapshot(consoles: consoles, settings: settings, psnAccountIDBase64: psnAccountIDBase64)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }

    func upsert(_ console: Console) {
        if let i = consoles.firstIndex(where: { $0.id == console.id }) {
            consoles[i] = console
        } else {
            consoles.append(console)
        }
    }

    func delete(_ console: Console) {
        consoles.removeAll { $0.id == console.id }
    }
}
