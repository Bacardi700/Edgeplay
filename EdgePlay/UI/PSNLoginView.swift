// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import WebKit

/// Gets the PSN account ID needed for linking, the same way chiaki-ng's helper does:
/// sign in on Sony's own page, catch the redirect, exchange the code for a token,
/// read `user_id`, then forget the token. Your password only ever goes to Sony.
struct PSNLoginView: View {
    var onAccountID: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var status: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            ZStack {
                PSNWebView { code in
                    working = true
                    Task {
                        do {
                            let id = try await PSNAccount.accountID(fromCode: code)
                            onAccountID(id)
                            dismiss()
                        } catch {
                            status = error.localizedDescription
                            working = false
                        }
                    }
                }
                if working { ProgressView("Getting your account ID…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
            }
            .safeAreaInset(edge: .bottom) {
                if let status { Text(status).font(.footnote).foregroundStyle(.red).padding() }
            }
            .navigationTitle("Sign in to PSN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
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

private struct PSNWebView: UIViewRepresentable {
    var onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()   // don't keep the PSN session around
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: PSNAccount.loginURL))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onCode: (String) -> Void
        private var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = action.request.url,
               url.absoluteString.hasPrefix(PSNAccount.redirect),
               let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value {
                decisionHandler(.cancel)
                if !done { done = true; onCode(code) }
                return
            }
            decisionHandler(.allow)
        }
    }
}
