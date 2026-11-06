import SwiftUI
import UIKit

/// Gets the PSN account ID needed for linking, the same way chiaki-ng's helper does:
/// sign in on Sony's own page in Safari, copy the address Safari ends on, and EdgePlay
/// exchanges the code in it for your account ID. Your password only ever goes to Sony,
/// and the temporary token is thrown away.
struct PSNLoginView: View {
    var onAccountID: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pasted = ""
    @State private var status: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        UIApplication.shared.open(PSNAccount.loginURL)
                    } label: {
                        Label("Open Sony sign-in in Safari", systemImage: "safari")
                    }
                } header: {
                    Text("Step 1")
                } footer: {
                    Text("Sign in with the PSN account you use on your PS5. When you're done, Safari lands on a page whose address starts with remoteplay.dl.playstation.net (it may look blank or show an error; that's fine).")
                }

                Section {
                    Button {
                        if let s = UIPasteboard.general.string { pasted = s; submit() }
                        else { status = "Nothing copied yet. In Safari, long-press the address bar and tap Copy." }
                    } label: {
                        Label("Paste address and continue", systemImage: "doc.on.clipboard")
                    }
                    .disabled(working)
                    TextField("or paste it here", text: $pasted, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                        .onSubmit(submit)
                } header: {
                    Text("Step 2")
                } footer: {
                    Text("In Safari, tap the address bar, copy the whole address, then come back here.")
                }

                if working {
                    Section { HStack { ProgressView(); Text("Getting your account ID…") } }
                }
                if let status {
                    Section { Text(status).foregroundStyle(.red) }
                }
            }
            .navigationTitle("PSN account ID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue", action: submit).disabled(working || pasted.isEmpty)
                }
            }
        }
    }

    private func submit() {
        status = nil
        guard let code = PSNAccount.code(from: pasted) else {
            status = "That address has no sign-in code in it. Copy the address of the page Safari shows after you sign in."
            return
        }
        working = true
        Task {
            do {
                let id = try await PSNAccount.accountID(fromCode: code)
                await MainActor.run {
                    working = false
                    onAccountID(id)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    working = false
                    status = error.localizedDescription + " Sign in again to get a fresh code."
                }
            }
        }
    }
}

enum PSNAccount {
    // Public client used by the PS Remote Play PC app (same values chiaki-ng uses).
    static let clientID = "ba495a24-818c-472b-b12d-ff231c1b5745"
    static let clientSecret = "mvaiZkRsAsI1IBkY"
    static let redirect = "https://remoteplay.dl.playstation.net/remoteplay/redirect"
    static let tokenURL = URL(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token")!

    static var loginURL: URL {
        var c = URLComponents(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize")!
        c.queryItems = [
            .init(name: "service_entity", value: "urn:service-entity:psn"),
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "scope", value: "psn:clientapp"),
            .init(name: "request_locale", value: "en_US"),
            .init(name: "ui", value: "pr"),
            .init(name: "service_logo", value: "ps"),
            .init(name: "layout_type", value: "popup"),
            .init(name: "smcid", value: "remoteplay"),
            .init(name: "prompt", value: "always"),
            .init(name: "PlatformPrivacyWs1", value: "minimal"),
        ]
        return c.url!
    }

    private static var basicAuth: String {
        "Basic " + Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
    }

    /// Pulls the `code` parameter out of the redirect address (or accepts a bare code).
    static func code(from text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let comps = URLComponents(string: t), let c = comps.queryItems?.first(where: { $0.name == "code" })?.value, !c.isEmpty {
            return c
        }
        if let r = t.range(of: "code=") {
            let rest = t[r.upperBound...]
            let c = rest.prefix { $0 != "&" && $0 != "#" && !$0.isWhitespace }
            return c.isEmpty ? nil : String(c)
        }
        // A bare code (no URL) pasted on its own.
        if !t.contains("/") && !t.contains(" ") && t.count >= 6 { return t }
        return nil
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func accountID(fromCode code: String) async throws -> Data {
        // 1. code -> access token
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue(basicAuth, forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let encodedCode = code.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? code
        req.httpBody = Data("grant_type=authorization_code&code=\(encodedCode)&redirect_uri=\(redirect)&".utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else {
            throw Failure(message: "Sony didn't return a token. Try signing in again.")
        }

        // 2. token -> user_id
        let escaped = token.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? token
        var info = URLRequest(url: URL(string: tokenURL.absoluteString + "/" + escaped)!)
        info.setValue(basicAuth, forHTTPHeaderField: "Authorization")
        let (infoData, infoResp) = try await URLSession.shared.data(for: info)
        guard (infoResp as? HTTPURLResponse)?.statusCode == 200,
              let infoJSON = try JSONSerialization.jsonObject(with: infoData) as? [String: Any] else {
            throw Failure(message: "Couldn't read your account details.")
        }
        let userID: UInt64?
        if let s = infoJSON["user_id"] as? String { userID = UInt64(s) }
        else if let n = infoJSON["user_id"] as? NSNumber { userID = n.uint64Value }
        else { userID = nil }
        guard let userID else { throw Failure(message: "Your account ID was missing from Sony's reply.") }

        // 3. 8 bytes, little endian (what the console expects)
        var le = userID.littleEndian
        return Data(bytes: &le, count: 8)
    }
}
