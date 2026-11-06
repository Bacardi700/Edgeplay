// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

struct ConsoleListView: View {
    @EnvironmentObject private var store: ConsoleStore
    @State private var showAdd = false
    @State private var showSettings = false
    @State private var editing: Console?

    var body: some View {
        NavigationStack {
            Group {
                if store.consoles.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(store.consoles) { console in
                            ConsoleRow(console: console, onEdit: { editing = console })
                        }
                        .onDelete { idx in idx.map { store.consoles[$0] }.forEach(store.delete) }
                    }
                }
            }
            .navigationTitle("EdgePlay")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAdd) { AddConsoleView() }
            .sheet(item: $editing) { EditConsoleView(console: $0) }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "gamecontroller.fill").font(.system(size: 56)).foregroundStyle(.secondary)
            Text("No consoles yet").font(.title3.bold())
            Text("Link your PS5 or PS4 once on your home Wi-Fi. After that you can play from anywhere over Tailscale.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Button("Add console") { showAdd = true }.buttonStyle(.borderedProminent)
        }
    }
}

/// One console with live status for its home and away addresses.
struct ConsoleRow: View {
    let console: Console
    let onEdit: () -> Void
    @EnvironmentObject private var store: ConsoleStore
    @StateObject private var status = ConsoleStatus()

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "gamecontroller.fill")
                .font(.title2)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.quaternary))
            VStack(alignment: .leading, spacing: 4) {
                Text(console.name).font(.headline)
                HStack(spacing: 6) {
                    Circle().fill(status.color).frame(width: 8, height: 8)
                    Text(status.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if status.bestState == .resting {
                Button("Wake") { wake() }.buttonStyle(.bordered)
            }
            Button {
                play()
            } label: {
                Image(systemName: "play.fill").padding(6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(status.bestHost == nil)
        }
        .padding(.vertical, 6)
        .contextMenu {
            ForEach(console.hosts, id: \.self) { host in
                Button("Connect via \(host)") { StreamPresenter.present(console: console, host: host, store: store) }
            }
            ForEach(console.hosts, id: \.self) { host in
                Button("Wake via \(host)") { Wake.send(to: console, host: host) }
            }
            Button("Edit", action: onEdit)
            Button("Delete", role: .destructive) { store.delete(console) }
        }
        .onAppear { status.start(console) }
        .onDisappear { status.stop() }
        .onChange(of: console) { status.start($0) }
    }

    private func play() {
        guard let host = status.bestHost else { return }
        StreamPresenter.present(console: console, host: host, store: store)
    }

    private func wake() {
        console.hosts.forEach { Wake.send(to: console, host: $0) }
        status.markWaking()
    }
}

@MainActor
final class ConsoleStatus: ObservableObject {
    @Published private(set) var states: [String: ConsoleState] = [:]
    @Published private(set) var runningApp: String?
    @Published private(set) var waking = false
    private var probes: [ConsoleProbe] = []
    private var order: [String] = []

    func start(_ console: Console) {
        stop()
        order = console.hosts
        for host in order {
            states[host] = .checking
            probes.append(ConsoleProbe(host: host) { [weak self] s, app in
                self?.states[host] = s
                if s == .ready { self?.waking = false }
                if let app, !app.isEmpty { self?.runningApp = app }
            })
        }
    }

    func stop() {
        probes.forEach { $0.stop() }
        probes.removeAll()
    }

    func markWaking() { waking = true }

    /// Prefer the home address, then the away address.
    var bestHost: String? { order.first { states[$0] == .ready } }

    var bestState: ConsoleState {
        let all = order.compactMap { states[$0] }
        if all.contains(.ready) { return .ready }
        if all.contains(.resting) { return .resting }
        if all.contains(.checking) { return .checking }
        return .unreachable
    }

    var color: Color {
        switch bestState {
        case .ready: return .green
        case .resting: return .orange
        case .checking, .unknown: return .gray
        case .unreachable: return .red
        }
    }

    var summary: String {
        if waking && bestState != .ready { return "Waking up…" }
        let via: String = {
            guard let h = bestHost else { return "" }
            return h == order.first ? " · home" : " · away"
        }()
        switch bestState {
        case .ready: return (runningApp.map { "Playing \($0)" } ?? "Ready") + via
        case .resting: return "Rest mode"
        case .checking, .unknown: return "Checking…"
        case .unreachable: return "Not reachable"
        }
    }
}
