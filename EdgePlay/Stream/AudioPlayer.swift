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

    func stop() {
        engine.stop()
        if let source { engine.detach(source) }
        source = nil
    }
}
