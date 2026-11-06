// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import CoreMedia
import QuartzCore
import AVFoundation

/// Swift owner of one chiaki streaming session. All `on…` handlers are called on the main thread.
final class StreamSession {
    enum Event {
        case connected
        case pinRequested(previousWasWrong: Bool)
        case nickname(String)
        case rumble(left: UInt8, right: UInt8)
        case lightbar(red: UInt8, green: UInt8, blue: UInt8)
        case triggers(left: TriggerEffect, right: TriggerEffect)
        case ended(reason: String, isError: Bool)
    }

    struct Stats {
        var fps: Double = 0
        var receivedMbps: Double = 0
        var rttMs: Double = 0
        var packetLoss: Double = 0
        var framesLost: Int32 = 0
        var resolution: CMVideoDimensions?
    }

    let console: Console
    let host: String
    let settings: StreamSettings
    let quality: EffectiveQuality
    let video: VideoDecoder
    let audio = AudioPlayer()
    var onEvent: ((Event) -> Void)?
    var onDimensions: ((CMVideoDimensions) -> Void)?

    private var handle: OpaquePointer?
    private var lastStatsTime = CACurrentMediaTime()
    private(set) var dimensions: CMVideoDimensions?
    private var closed = false

    init(console: Console, host: String, settings: StreamSettings, quality: EffectiveQuality) throws {
        self.console = console
        self.host = host
        self.settings = settings
        self.quality = quality
        video = VideoDecoder(hevc: quality.hevc, hdr: quality.hdr)
        video.renderer?.sharpness = settings.enhance.sharpness
        video.renderer?.useMetalFX = settings.enhance != .off

        var cfg = RPConnectConfig()
        cfg.ps5 = console.ps5
        cfg.width = quality.resolution.size.width
        cfg.height = quality.resolution.size.height
        cfg.fps = quality.fps
        cfg.bitrate_kbps = quality.bitrateKbps
        cfg.codec = quality.hdr ? RP_CODEC_H265_HDR : (quality.hevc ? RP_CODEC_H265 : RP_CODEC_H264)
        cfg.enable_dualsense = true
        copyBytes(console.registKey, into: &cfg.regist_key)
        copyBytes(console.morning, into: &cfg.morning)

        var callbacks = RPCallbacks()
        callbacks.on_event = { ctx, type, code, flag, text in
            StreamSession.from(ctx).handleEvent(type, code, flag, text.map { String(cString: $0) })
        }
        callbacks.on_video = { ctx, buf, size, _, _ in
            guard let buf else { return false }
            return StreamSession.from(ctx).video.enqueue(buf, count: size)
        }
        callbacks.on_audio_format = { ctx, channels, rate in
            StreamSession.from(ctx).audio.configure(channels: Int(channels), rate: Double(rate))
        }
        callbacks.on_audio_pcm = { ctx, pcm, frames in
            guard let pcm else { return }
            StreamSession.from(ctx).audio.push(pcm, frames: frames)
        }
        callbacks.on_trigger_effects = { ctx, typeL, left, typeR, right in
            guard let left, let right else { return }
            let l = TriggerEffect(type: typeL, params: Array(UnsafeBufferPointer(start: left, count: 10)))
            let r = TriggerEffect(type: typeR, params: Array(UnsafeBufferPointer(start: right, count: 10)))
            let me = StreamSession.from(ctx)
            DispatchQueue.main.async { [weak me] in me?.onEvent?(.triggers(left: l, right: r)) }
        }
        callbacks.on_log = { _, level, msg in
            #if DEBUG
            if let msg { print("[chiaki \(level)] \(String(cString: msg))") }
            #endif
        }

        var err: UnsafePointer<CChar>?
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let h = host.withCString { hostPtr -> OpaquePointer? in
            cfg.host = hostPtr                 // copied inside rp_session_create
            return rp_session_create(&cfg, callbacks, ctx, &err)
        }
        guard let h else {
            throw NSError(domain: "EdgePlay", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Could not set up the stream: \(err.map { String(cString: $0) } ?? "unknown error")"])
        }
        handle = h

        video.onDimensions = { [weak self] dims in
            DispatchQueue.main.async {
                self?.dimensions = dims
                self?.onDimensions?(dims)
            }
        }
    }

    deinit {
        // close() normally runs first; this is only a safety net.
        if let h = handle { rp_session_free(h) }
    }

    private static func from(_ ctx: UnsafeMutableRawPointer?) -> StreamSession {
        Unmanaged<StreamSession>.fromOpaque(ctx!).takeUnretainedValue()
    }

    // MARK: control

    func start() throws {
        guard let h = handle else { return }
        let r = rp_session_start(h)
        if r != 0 {
            throw NSError(domain: "EdgePlay", code: Int(r), userInfo: [NSLocalizedDescriptionKey: "Could not start the stream (error \(r))."])
        }
    }

    /// Stops the stream and frees chiaki on a background thread (joining its threads can take a moment).
    func close() {
        guard !closed, let h = handle else { return }
        closed = true
        handle = nil
        audio.stop()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            rp_session_stop(h)
            rp_session_free(h)
            _ = self   // keep callbacks' context alive until chiaki's threads are gone
        }
    }

    func submitPin(_ pin: String) {
        guard let h = handle else { return }
        _ = pin.withCString { rp_session_set_login_pin(h, $0) }
    }

    func sendPad(_ pad: inout RPPadState) {
        guard let h = handle else { return }
        _ = rp_session_set_pad(h, &pad)
    }

    /// Turns the mic on/off for party/game chat. Call after `.connected`.
    func setMicrophone(_ on: Bool, completion: @escaping (Bool) -> Void) {
        guard let h = handle else { completion(false); return }
        let apply = { [weak self] in
            guard let self, let h = self.handle else { completion(false); return }
            if on {
                let ok = self.audio.setMic(true) { pcm in rp_session_push_mic(h, pcm) }
                completion(ok && rp_session_set_mic(h, true) == 0)
            } else {
                _ = rp_session_set_mic(h, false)
                self.audio.setMic(false) { _ in }
                completion(true)
            }
        }
        _ = h
        if on {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async { granted ? apply() : completion(false) }
            }
        } else {
            apply()
        }
    }

    func requestKeyframe() {
        if let h = handle { _ = rp_session_request_idr(h) }
    }

    func putConsoleToRest() {
        if let h = handle { _ = rp_session_sleep(h) }
    }

    func sampleStats() -> Stats {
        var s = Stats()
        let now = CACurrentMediaTime()
        let dt = max(now - lastStatsTime, 0.001)
        lastStatsTime = now
        let c = video.takeCounters()
        s.fps = Double(c.frames) / dt
        s.receivedMbps = Double(c.bytes) * 8 / dt / 1_000_000
        if let h = handle {
            var r = RPStats()
            rp_session_get_stats(h, &r)
            s.rttMs = r.rtt_ms
            s.packetLoss = r.packet_loss
            s.framesLost = r.frames_lost_total
        }
        s.resolution = dimensions
        return s
    }

    // MARK: events (chiaki thread -> main)

    private func handleEvent(_ type: RPEventType, _ code: Int32, _ flag: Bool, _ text: String?) {
        let event: Event?
        switch type {
        case RP_EVENT_CONNECTED:
            event = .connected
        case RP_EVENT_LOGIN_PIN_REQUEST:
            event = .pinRequested(previousWasWrong: flag)
        case RP_EVENT_NICKNAME:
            event = .nickname(text ?? "")
        case RP_EVENT_RUMBLE:
            event = .rumble(left: UInt8((code >> 8) & 0xFF), right: UInt8(code & 0xFF))
        case RP_EVENT_LED_COLOR:
            event = .lightbar(red: UInt8((code >> 16) & 0xFF), green: UInt8((code >> 8) & 0xFF), blue: UInt8(code & 0xFF))
        case RP_EVENT_QUIT:
            event = .ended(reason: StreamSession.friendly(reason: text, code: code), isError: flag)
        default:
            event = nil
        }
        guard let event else { return }
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }

    private static func friendly(reason: String?, code: Int32) -> String {
        // chiaki quit reasons (ChiakiQuitReason)
        switch code {
        case 1: return "Stream stopped."
        case 3: return "The console refused the connection. Is Remote Play turned on, and is this device still linked?"
        case 13: return "PSN registration failed."
        case 4: return "Remote Play is already in use on another device."
        case 5: return "Remote Play crashed on the console. Try again."
        case 6: return "The console's Remote Play version doesn't match. Update the console."
        case 2, 7, 8, 9, 10: return "Couldn't reach the console. Check the address, that it's awake, and your Tailscale/port forwarding if you're away from home."
        case 11: return "The console closed the stream."
        case 12: return "The console was turned off or went to rest mode."
        default: return reason ?? "The stream ended."
        }
    }
}

/// Copies bytes into a fixed-size C array (imported into Swift as a tuple).
func copyBytes<T>(_ data: Data, into tuple: inout T) {
    withUnsafeMutableBytes(of: &tuple) { dst in
        dst.initializeMemory(as: UInt8.self, repeating: 0)
        dst.copyBytes(from: data.prefix(dst.count))
    }
}

func dataFromTuple<T>(_ tuple: T) -> Data {
    withUnsafeBytes(of: tuple) { Data($0) }
}

func stringFromTuple<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        let bytes = raw.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}
