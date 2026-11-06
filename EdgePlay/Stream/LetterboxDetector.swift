// SPDX-License-Identifier: AGPL-3.0-only

import CoreVideo
import Foundation

/// Finds black letterbox bars baked into the picture (cinematic modes, cutscenes,
/// films in media apps) so they can be trimmed instead of cropping real picture,
/// the way video apps "zoom to fill" a 2.39:1 film on a wide phone.
///
/// Conservative by design: bars must be on both top and bottom, roughly equal,
/// and steady for most of a second before trimming. If anything shows up inside
/// a bar (subtitles, a HUD), the trim backs off within a few frames.
final class LetterboxDetector {
    struct Bars: Equatable { var top: Float; var bottom: Float }

    private let lock = NSLock()
    private var frameCounter = 0
    private var applied = Bars(top: 0, bottom: 0)
    private var candidate = Bars(top: 0, bottom: 0)
    private var candidateCount = 0

    /// Check every Nth frame (cheap: ~a few thousand pixel reads).
    var interval = 6
    /// Checks a larger trim must persist for before it's applied (~0.8 s at 60 fps).
    var growChecks = 8
    /// Checks a smaller trim must persist for (fast, so nothing stays hidden).
    var shrinkChecks = 2

    func reset() {
        lock.lock(); defer { lock.unlock() }
        frameCounter = 0
        applied = Bars(top: 0, bottom: 0)
        candidate = applied
        candidateCount = 0
    }

    /// Returns the new bars when the applied trim changes, otherwise nil.
    func feed(_ pb: CVPixelBuffer) -> Bars? {
        lock.lock(); defer { lock.unlock() }
        frameCounter += 1
        guard frameCounter % interval == 0 else { return nil }
        guard let measured = Self.measure(pb) else { return nil }   // e.g. a fully black fade

        if abs(measured.top - candidate.top) < 0.01 && abs(measured.bottom - candidate.bottom) < 0.01 {
            candidateCount += 1
        } else {
            candidate = measured
            candidateCount = 1
        }
        let growing = candidate.top + candidate.bottom > applied.top + applied.bottom
        let needed = growing ? growChecks : shrinkChecks
        guard candidateCount >= needed, candidate != applied else { return nil }
        applied = candidate
        return applied
    }

    /// Measures symmetric top/bottom black bars. Nil if the frame is (almost) entirely dark.
    static func measure(_ pb: CVPixelBuffer) -> Bars? {
        guard CVPixelBufferGetPlaneCount(pb) >= 1 else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0)
        let h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let sixteenBit = CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        guard w > 64, h > 64 else { return nil }

        // 8-bit luma; video-range black is 16, allow a little noise and grain.
        let threshold = 30
        let samples = 64
        let x0 = w / 20, x1 = w - w / 20

        func rowIsBlack(_ y: Int) -> Bool {
            let row = base.advanced(by: y * stride)
            for i in 0..<samples {
                let x = x0 + (x1 - x0) * i / (samples - 1)
                let v: Int = sixteenBit
                    ? Int(row.load(fromByteOffset: x * 2, as: UInt16.self) >> 8)
                    : Int(row.load(fromByteOffset: x, as: UInt8.self))
                if v > threshold { return false }
            }
            return true
        }

        if rowIsBlack(h / 2) && rowIsBlack(h / 3) && rowIsBlack(2 * h / 3) { return nil }

        let limit = h * 3 / 10                  // never trim more than 30% per side
        var top = 0
        while top < limit && rowIsBlack(top) { top += 1 }
        var bottom = 0
        while bottom < limit && rowIsBlack(h - 1 - bottom) { bottom += 1 }

        var t = Float(top) / Float(h), b = Float(bottom) / Float(h)
        // Only real letterboxing: both sides, similar size, more than a sliver.
        if t < 0.025 || b < 0.025 || abs(t - b) > 0.03 {
            return Bars(top: 0, bottom: 0)
        }
        // Keep a hair of margin and snap to 0.5% steps so tiny noise doesn't re-layout.
        let m = max(0, min(t, b) - 0.003)
        t = (m * 200).rounded(.down) / 200
        b = t
        return Bars(top: t, bottom: b)
    }
}
