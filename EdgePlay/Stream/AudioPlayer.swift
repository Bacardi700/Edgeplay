// SPDX-License-Identifier: AGPL-3.0-only

import AVFoundation
import os

/// Plays the decoded PCM from the console with a small jitter buffer.
/// chiaki pushes 16-bit interleaved samples from its network thread; an
/// AVAudioSourceNode pulls them on the audio thread.
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var channels = 2
    private var rate: Double = 48_000

    // Ring buffer of interleaved Float32 samples.
    private var ring = [Float](repeating: 0, count: 48_000 * 2)  // 1 s stereo
    private var readIndex = 0
    private var writeIndex = 0
    private var filled = 0
    private var primed = false
    private let lock = OSAllocatedUnfairLock()

    /// Start playing once this much is buffered, and trim back to it if latency grows.
    private var targetFrames: Int { Int(rate * 0.04) }      // 40 ms
    private var maxFrames: Int { Int(rate * 0.12) }         // 120 ms

    func configure(channels: Int, rate: Double) {
        stop()
        self.channels = max(1, min(channels, 2))
        self.rate = rate
        lock.lock()
        ring = [Float](repeating: 0, count: Int(rate) * self.channels)
        readIndex = 0; writeIndex = 0; filled = 0; primed = false
        lock.unlock()

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setPreferredIOBufferDuration(0.005)
        try? session.setActive(true)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(self.channels)) else { return }
        let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, abl in
            self.render(frames: Int(frameCount), into: UnsafeMutableAudioBufferListPointer(abl))
            return noErr
        }
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try? engine.start()
    }

    func push(_ pcm: UnsafePointer<Int16>, frames: Int) {
        let n = frames * channels
        lock.lock()
        defer { lock.unlock() }
        let cap = ring.count
        for i in 0..<n {
            ring[writeIndex] = Float(pcm[i]) / 32768.0
            writeIndex = (writeIndex + 1) % cap
        }
        filled = min(filled + n, cap)
        if filled == cap { readIndex = writeIndex }
        // Keep latency bounded: drop the oldest audio if we fell behind.
        let maxSamples = maxFrames * channels
        if filled > maxSamples {
            let drop = filled - targetFrames * channels
            readIndex = (readIndex + drop) % cap
            filled -= drop
        }
    }

    private func render(frames: Int, into abl: UnsafeMutableAudioBufferListPointer) {
        lock.lock()
        defer { lock.unlock() }
        if !primed && filled >= targetFrames * channels { primed = true }
        let cap = ring.count
        for f in 0..<frames {
            let have = primed && filled >= channels
            for c in 0..<abl.count {
                guard let out = abl[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
                if have {
                    out[f] = ring[(readIndex + min(c, channels - 1)) % cap]
                } else {
                    out[f] = 0
                }
            }
            if have {
                readIndex = (readIndex + channels) % cap
                filled -= channels
            } else {
                primed = false   // underrun: re-buffer
            }
        }
    }

    // MARK: microphone

    private(set) var micOn = false
    private var micConverter: AVAudioConverter?
    private let micFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true)!
    private var micAccum: [Int16] = []
    private let micFrameSamples = 480 * 2   // 10 ms stereo, what chiaki's Opus encoder expects

    /// Starts/stops capturing the iPhone mic. `onFrame` gets 480 stereo int16 frames at 48 kHz.
    /// Uses voice processing so the game audio coming out of the speaker isn't sent back as echo.
    @discardableResult
    func setMic(_ on: Bool, onFrame: @escaping (UnsafePointer<Int16>) -> Void) -> Bool {
        guard on != micOn else { return true }
        let session = AVAudioSession.sharedInstance()
        let input = engine.inputNode
        engine.stop()
        if on {
            try? session.setCategory(.playAndRecord, mode: .default,
                                     options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
            try? session.setActive(true)
            try? input.setVoiceProcessingEnabled(true)
            let inFormat = input.outputFormat(forBus: 0)
            guard inFormat.sampleRate > 0, let conv = AVAudioConverter(from: inFormat, to: micFormat) else {
                try? engine.start()
                return false
            }
            micConverter = conv
            micAccum.removeAll(keepingCapacity: true)
            input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
                self?.handleMic(buffer, onFrame)
            }
        } else {
            input.removeTap(onBus: 0)
            try? input.setVoiceProcessingEnabled(false)
            try? session.setCategory(.playback, mode: .moviePlayback, options: [])
            micConverter = nil
        }
        micOn = on
        try? engine.start()
        return true
    }

    private func handleMic(_ buffer: AVAudioPCMBuffer, _ onFrame: (UnsafePointer<Int16>) -> Void) {
        guard let conv = micConverter else { return }
        let ratio = micFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.int16ChannelData else { return }
        let count = Int(out.frameLength) * 2
        micAccum.append(contentsOf: UnsafeBufferPointer(start: data[0], count: count))
        while micAccum.count >= micFrameSamples {
            micAccum.withUnsafeBufferPointer { onFrame($0.baseAddress!) }
            micAccum.removeFirst(micFrameSamples)
        }
    }

    func stop() {
        if micOn {
            engine.inputNode.removeTap(onBus: 0)
            micOn = false
        }
        engine.stop()
        if let source { engine.detach(source) }
        source = nil
    }
}
