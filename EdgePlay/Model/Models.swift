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
    /// Your own width, height and position: stretch or crop on either axis, and pick
    /// which side gets cropped (left/right, top/bottom).
    case custom = "Custom"
    var id: String { rawValue }
}

/// Settings for Custom screen mode, relative to the fitted (undistorted) picture.
struct CustomFrame: Codable, Equatable {
    /// 1 = fitted width; above ~1.22 on a modern iPhone it overflows and crops left/right.
    var width: Double = 1.22
    /// 1 = full height; above 1 crops top/bottom.
    var height: Double = 1.0
    /// Keep width and height in step (zoom without stretching).
    var lockAspect: Bool = false
    /// -1 = keep the left edge (crop the right) … 0 = centre … 1 = keep the right edge.
    var offsetX: Double = 0
    /// -1 = keep the top (crop the bottom) … 0 = centre … 1 = keep the bottom.
    var offsetY: Double = 0

    static let range: ClosedRange<Double> = 1.0...1.6
}

enum EnhanceLevel: String, Codable, CaseIterable, Identifiable {
    case off = "Off", balanced = "Balanced", sharp = "Sharp"
    var id: String { rawValue }
    /// Contrast-adaptive sharpening amount for the final pass.
    var sharpness: Float {
        switch self {
        case .off: return 0
        case .balanced: return 0.35
        case .sharp: return 0.7
        }
    }
}

struct StreamSettings: Codable, Equatable {
    /// Pick resolution/bitrate per connection (home Wi-Fi, away, mobile data).
    var autoQuality: Bool = true
    var resolution: VideoResolution = .p1080
    var fps: UInt32 = 60
    var bitrateKbps: UInt32 = 15_000
    var codec: VideoCodec = .hevc
    /// PS5 only; needs HEVC and an HDR-capable iPhone screen.
    var hdr: Bool = false
    var enhance: EnhanceLevel = .balanced
    /// Present frames on a 120 Hz display link on ProMotion iPhones (less judder).
    var highRefresh: Bool = true
    var screenMode: ScreenMode = .fill
    /// 0 = stretch only, 1 = crop only. 0.5 splits the difference.
    var fillBalance: Double = 0.5
    var custom = CustomFrame()
    var showStats: Bool = true
    var rumble: Bool = true
    /// 0.2...1 multiplier for vibration.
    var rumbleStrength: Double = 0.7
    var lightbar: Bool = true
    var adaptiveTriggers: Bool = true
    /// 0...1 multiplier for trigger resistance/vibration.
    var triggerStrength: Double = 1.0
    /// Send the DualSense's gyro/accelerometer (gyro aiming, motion controls).
    var motion: Bool = true
    var invertGyroHorizontal: Bool = false
    var invertGyroVertical: Bool = false
    /// Turn the iPhone mic on when a stream starts (party/game chat).
    var microphone: Bool = false
    /// Vibrate the iPhone when the controller has no rumble motors (e.g. Backbone).
    var phoneVibration: Bool = true

    init() {}

    /// Tolerant decoding: settings saved by older versions keep working and
    /// new options get their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StreamSettings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        autoQuality = v(.autoQuality, d.autoQuality)
        resolution = v(.resolution, d.resolution)
        fps = v(.fps, d.fps)
        bitrateKbps = v(.bitrateKbps, d.bitrateKbps)
        codec = v(.codec, d.codec)
        hdr = v(.hdr, d.hdr)
        enhance = v(.enhance, d.enhance)
        highRefresh = v(.highRefresh, d.highRefresh)
        screenMode = v(.screenMode, d.screenMode)
        fillBalance = v(.fillBalance, d.fillBalance)
        custom = v(.custom, d.custom)
        showStats = v(.showStats, d.showStats)
        rumble = v(.rumble, d.rumble)
        rumbleStrength = v(.rumbleStrength, d.rumbleStrength)
        lightbar = v(.lightbar, d.lightbar)
        adaptiveTriggers = v(.adaptiveTriggers, d.adaptiveTriggers)
        triggerStrength = v(.triggerStrength, d.triggerStrength)
        motion = v(.motion, d.motion)
        invertGyroHorizontal = v(.invertGyroHorizontal, d.invertGyroHorizontal)
        invertGyroVertical = v(.invertGyroVertical, d.invertGyroVertical)
        microphone = v(.microphone, d.microphone)
        phoneVibration = v(.phoneVibration, d.phoneVibration)
    }

    struct BitratePreset: Identifiable {
        let label: String
        let kbps: UInt32
        var id: UInt32 { kbps }
    }

    static let bitratePresets: [BitratePreset] = [
        .init(label: "Mobile data · 5 Mb/s", kbps: 5_000),
        .init(label: "Balanced · 10 Mb/s", kbps: 10_000),
        .init(label: "Home Wi-Fi · 15 Mb/s", kbps: 15_000),
        .init(label: "High · 20 Mb/s", kbps: 20_000),
        .init(label: "Max · 30 Mb/s", kbps: 30_000),
    ]
}

/// What a session actually asks the console for, after Auto quality is applied.
struct EffectiveQuality: Equatable {
    var resolution: VideoResolution
    var fps: UInt32
    var bitrateKbps: UInt32
    var hevc: Bool
    var hdr: Bool
    var label: String

    enum Link { case homeWiFi, awayWiFi, cellular }

    static func resolve(_ s: StreamSettings, ps5: Bool, link: Link, hdrDisplay: Bool) -> EffectiveQuality {
        let hevc = ps5 && s.codec == .hevc
        let hdr = hevc && s.hdr && hdrDisplay
        guard s.autoQuality else {
            return .init(resolution: s.resolution, fps: s.fps, bitrateKbps: s.bitrateKbps, hevc: hevc, hdr: hdr, label: "manual")
        }
        switch link {
        case .homeWiFi:
            return .init(resolution: .p1080, fps: 60, bitrateKbps: 15_000, hevc: hevc, hdr: hdr, label: "auto · home")
        case .awayWiFi:
            return .init(resolution: .p1080, fps: 60, bitrateKbps: 10_000, hevc: hevc, hdr: hdr, label: "auto · away")
        case .cellular:
            return .init(resolution: .p720, fps: 60, bitrateKbps: 6_000, hevc: hevc, hdr: false, label: "auto · mobile")
        }
    }
}

enum ScreenGeometry {
    /// Frame for the video layer inside `bounds` for a picture of aspect `videoAspect`.
    /// Anything outside `bounds` is clipped (that is the "crop").
    /// Custom mode: scale the fitted picture independently in X and Y, then position it.
    static func customFrame(in bounds: CGRect, videoAspect: CGFloat, custom c: CustomFrame) -> CGRect {
        let fit = videoFrame(in: bounds, videoAspect: videoAspect, mode: .fit, balance: 0)
        let w = fit.width * CGFloat(c.width)
        let h = fit.height * CGFloat(c.height)
        let x = bounds.minX + (bounds.width - w) * CGFloat(0.5 + 0.5 * c.offsetX)
        let y = bounds.minY + (bounds.height - h) * CGFloat(0.5 + 0.5 * c.offsetY)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    static func videoFrame(in bounds: CGRect, videoAspect: CGFloat, mode: ScreenMode, balance: Double) -> CGRect {
        guard bounds.width > 0, bounds.height > 0, videoAspect > 0 else { return bounds }
        let W = bounds.width, H = bounds.height
        let screenAspect = W / H

        switch mode {
        case .fit, .custom:
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
