// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import CoreGraphics

/// A paired PlayStation console.
struct Console: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// Address on your home network, e.g. 192.168.0.23
    var homeHost: String
    /// Address used away from home: a Tailscale IP (100.x.y.z), MagicDNS name,
    /// or your public IP / DDNS name if you set up port forwarding.
    var remoteHost: String?
    var ps5: Bool
    var registKey: Data   // 16 bytes
    var morning: Data     // 16 bytes ("rp_key")
    var mac: Data?

    var hosts: [String] {
        [homeHost, remoteHost].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

enum VideoResolution: String, Codable, CaseIterable, Identifiable {
    case p720 = "720p", p1080 = "1080p"
    var id: String { rawValue }
    var size: (width: UInt32, height: UInt32) {
        switch self {
        case .p720: return (1280, 720)
        case .p1080: return (1920, 1080)
        }
    }
}

enum VideoCodec: String, Codable, CaseIterable, Identifiable {
    case h264 = "H.264", hevc = "HEVC"
    var id: String { rawValue }
}

/// How the 16:9 picture is fitted to a ~19.5:9 iPhone screen.
enum ScreenMode: String, Codable, CaseIterable, Identifiable {
    /// Whole picture, black bars at the sides (what Sony's app does).
    case fit = "Fit"
    /// Edge to edge. `fillBalance` decides how the extra width is found:
    /// 0 = all stretch (nothing cropped), 1 = all crop (no distortion).
    case fill = "Fill"
    var id: String { rawValue }
}

struct StreamSettings: Codable, Equatable {
    var resolution: VideoResolution = .p1080
    var fps: UInt32 = 60
    var bitrateKbps: UInt32 = 15_000
    var codec: VideoCodec = .hevc
    var screenMode: ScreenMode = .fill
    /// 0 = stretch only, 1 = crop only. 0.5 splits the difference.
    var fillBalance: Double = 0.5
    var showStats: Bool = true
    var rumble: Bool = true
    var lightbar: Bool = true

    struct BitratePreset: Identifiable {
        let label: String
        let kbps: UInt32
        var id: UInt32 { kbps }
    }

    static let bitratePresets: [BitratePreset] = [
        .init(label: "Mobile data · 5 Mb/s", kbps: 5_000),
        .init(label: "Balanced · 10 Mb/s", kbps: 10_000),
        .init(label: "Home Wi-Fi · 15 Mb/s", kbps: 15_000),
        .init(label: "Max · 30 Mb/s", kbps: 30_000),
    ]
}

enum ScreenGeometry {
    /// Frame for the video layer inside `bounds` for a picture of aspect `videoAspect`.
    /// Anything outside `bounds` is clipped (that is the "crop").
    static func videoFrame(in bounds: CGRect, videoAspect: CGFloat, mode: ScreenMode, balance: Double) -> CGRect {
        guard bounds.width > 0, bounds.height > 0, videoAspect > 0 else { return bounds }
        let W = bounds.width, H = bounds.height
        let screenAspect = W / H

        switch mode {
        case .fit:
            if screenAspect > videoAspect {
                let w = H * videoAspect
                return CGRect(x: bounds.minX + (W - w) / 2, y: bounds.minY, width: w, height: H)
            } else {
                let h = W / videoAspect
                return CGRect(x: bounds.minX, y: bounds.minY + (H - h) / 2, width: W, height: h)
            }
        case .fill:
            // Total enlargement needed along the short-fitting axis is `ratio`.
            // Split it into a uniform zoom (crops) and a one-axis stretch (distorts):
            // zoom = ratio^t, stretch = ratio^(1-t).
            let t = CGFloat(min(max(balance, 0), 1))
            if screenAspect >= videoAspect {
                let ratio = screenAspect / videoAspect           // > 1 on modern iPhones
                let zoom = pow(ratio, t)
                let h = H * zoom                                  // taller than screen -> top/bottom cropped
                return CGRect(x: bounds.minX, y: bounds.minY + (H - h) / 2, width: W, height: h)
            } else {
                let ratio = videoAspect / screenAspect           // iPad-ish screens
                let zoom = pow(ratio, t)
                let w = W * zoom
                return CGRect(x: bounds.minX + (W - w) / 2, y: bounds.minY, width: w, height: H)
            }
        }
    }
}

extension Data {
    /// 8-byte PSN account id from its base64 form (as shown by chiaki-ng tools).
    static func psnAccountID(base64: String) -> Data? {
        guard let d = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)), d.count == 8 else { return nil }
        return d
    }
}
