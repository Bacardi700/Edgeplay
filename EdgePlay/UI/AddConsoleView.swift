// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

/// Links this iPhone with a console (one-time, on the same network as the console).
struct AddConsoleView: View {
    @EnvironmentObject private var store: ConsoleStore
    @Environment(\.dismiss) private var dismiss

    @State private var ps5 = true
    @State private var homeHost = ""
    @State private var remoteHost = ""
    @State private var pin = ""
    @State private var accountID = ""
    @State private var pairing: Pairing?
    @State private var error: String?
    @State private var showPSNLogin = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Console", selection: $ps5) {
                        Text("PS5").tag(true)
                        Text("PS4").tag(false)
                    }
                    .pickerStyle(.segmented)
                    TextField("Console IP on your Wi-Fi, e.g. 192.168.0.23", text: $homeHost)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Find it on the console: Settings › Network › View Connection Status › IPv4 address. Reserve it in your router so it doesn't change.")
                }

                Section {
                    HStack {
                        TextField("PSN account ID (base64)", text: $accountID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                        Button("Sign in") { showPSNLogin = true }
                    }
                } header: {
                    Text("PlayStation account")
                } footer: {
                    Text("Sign in with the PSN account you use on the console, or paste the ID if you already have it. Only the numeric account ID is kept.")
                }

                Section {
                    TextField("8-digit code", text: $pin)
                        .keyboardType(.numberPad)
                        .font(.body.monospaced())
                } header: {
                    Text("Link code")
                } footer: {
                    Text(ps5 ? "On the PS5: Settings › System › Remote Play › Link Device."
                             : "On the PS4: Settings › Remote Play Connection Settings › Add Device.")
                }

                Section {
                    TextField("Tailscale IP or name (optional)", text: $remoteHost)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Away from home")
                } footer: {
                    Text("If a device on your home network is a Tailscale subnet router, this is usually the same IP as above. Otherwise use your public IP/DDNS name with port forwarding.")
                }

                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add console")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { pairing?.cancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if pairing != nil {
                        ProgressView()
                    } else {
                        Button("Link") { link() }.disabled(!canLink)
                    }
                }
            }
            .sheet(isPresented: $showPSNLogin) {
                PSNLoginView { id in
                    accountID = id.base64EncodedString()
                }
            }
            .onAppear { if accountID.isEmpty { accountID = store.psnAccountIDBase64 } }
        }
    }

    private var canLink: Bool {
        !homeHost.trimmingCharacters(in: .whitespaces).isEmpty
            && pin.filter(\.isNumber).count == 8
            && Data.psnAccountID(base64: accountID) != nil
    }

    private func link() {
        error = nil
        guard let id = Data.psnAccountID(base64: accountID),
              let pinValue = UInt32(pin.filter(\.isNumber)) else { return }
        let host = homeHost.trimmingCharacters(in: .whitespaces)
        let remote = remoteHost.trimmingCharacters(in: .whitespaces)
        let wantPS5 = ps5

        pairing = Pairing(host: host, ps5: wantPS5, accountID: id, pin: pinValue) { result, reason in
            pairing = nil
            guard let result else {
                error = Self.explain(reason)
                return
            }
            store.psnAccountIDBase64 = accountID
            store.upsert(Console(name: result.nickname.isEmpty ? (wantPS5 ? "PS5" : "PS4") : result.nickname,
                                 homeHost: host,
                                 remoteHost: remote.isEmpty ? nil : remote,
                                 ps5: result.ps5,
                                 registKey: result.registKey,
                                 morning: result.morning,
                                 mac: result.mac))
            dismiss()
        }
        if pairing == nil { error = "Couldn't start linking." }
    }

    /// Turns chiaki's registration errors into something actionable.
    static func explain(_ reason: String?) -> String {
        let r = (reason ?? "").lowercased()
        if r.contains("refused the registration search") || r.contains("search") && r.contains("refused") {
            return "The PS5 didn't answer. Keep the Link Device screen with the code open on the TV while you tap Link, and check the IP."
        }
        if r.contains("search") || r.contains("timed out") || r.contains("timeout") {
            return "Couldn't reach the console at that IP. Check the address, that the iPhone is on the same Wi-Fi (not guest Wi-Fi, no VPN/Tailscale on), and Local Network access is on for EdgePlay."
        }
        if r.contains("pin") || r.contains("80108b09") || r.contains("regist failed") {
            return "The console rejected the link. The 8-digit code may have expired (it changes every few minutes) or the PSN account ID doesn't match the user signed in on the PS5."
        }
        if r.contains("cancel") { return "Linking was cancelled." }
        let detail = reason.map { " (\($0))" } ?? ""
        return "Linking failed\(detail). Check the IP, that the code is still on the TV, and that the account ID matches the PS5's signed-in user."
    }
}

struct EditConsoleView: View {
    @EnvironmentObject private var store: ConsoleStore
    @Environment(\.dismiss) private var dismiss
    @State var console: Console

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("Name", text: $console.name) }
                Section("Home address") {
                    TextField("192.168.0.23", text: $console.homeHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    TextField("Tailscale IP or name", text: Binding(
                        get: { console.remoteHost ?? "" },
                        set: { console.remoteHost = $0.isEmpty ? nil : $0 }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Away address") }
            }
            .navigationTitle(console.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { store.upsert(console); dismiss() }
                }
            }
        }
    }
}
