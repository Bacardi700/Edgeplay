// SPDX-License-Identifier: AGPL-3.0-only

import GameController

/// One DualSense trigger effect as the PS5 describes it, decoded from the raw
/// output-report bytes (effect type + 10 parameters) into something iOS's
/// GCDualSenseAdaptiveTrigger can play.
///
/// Byte layouts follow the community documentation of the DualSense trigger
/// effect "factories" (the same bytes chiaki-ng forwards to the controller over HID).
enum TriggerEffect: Equatable {
    case off
    /// Resistance per zone (10 zones from released to fully pressed), 0...1.
    case feedback(zones: [Float])
    /// Resistance that "breaks" between two positions, like a gun trigger. Positions 0...1.
    case weapon(start: Float, end: Float, strength: Float)
    /// Vibration per zone, 0...1, with a frequency 0...1.
    case vibration(zones: [Float], frequency: Float)

    static let zoneCount = 10

    init(type: UInt8, params p: [UInt8]) {
        let p = p.count >= 10 ? p : p + Array(repeating: 0, count: 10 - p.count)
        func u16(_ i: Int) -> UInt16 { UInt16(p[i]) | UInt16(p[i + 1]) << 8 }
        func u32(_ i: Int) -> UInt32 { UInt32(p[i]) | UInt32(p[i + 1]) << 8 | UInt32(p[i + 2]) << 16 | UInt32(p[i + 3]) << 24 }
        /// 10 zones, each 3 bits (value-1) gated by an active-zone mask.
        func zones(mask: UInt16, packed: UInt32) -> [Float] {
            (0..<Self.zoneCount).map { i in
                guard mask & (1 << UInt16(i)) != 0 else { return 0 }
                let v = (packed >> UInt32(i * 3)) & 0x7
                return Float(v + 1) / 8
            }
        }
        /// Lowest and highest set bit of a zone mask, as positions 0...1.
        func span(_ mask: UInt16) -> (Float, Float)? {
            guard mask != 0 else { return nil }
            let lo = mask.trailingZeroBitCount
            let hi = 15 - mask.leadingZeroBitCount
            return (Float(lo) / 9, Float(min(hi, 9)) / 9)
        }

        switch type {
        case 0x21: // Feedback (zoned resistance)
            let z = zones(mask: u16(0), packed: u32(2))
            self = z.allSatisfy { $0 == 0 } ? .off : .feedback(zones: z)

        case 0x25: // Weapon: start/stop zone bits + strength
            guard let (s, e) = span(u16(0)) else { self = .off; return }
            self = .weapon(start: s, end: e, strength: Float((p[2] & 0x7) + 1) / 8)

        case 0x22: // Bow: like weapon, then snaps back
            guard let (s, e) = span(u16(0)) else { self = .off; return }
            self = .weapon(start: s, end: e, strength: Float((p[2] & 0x7) + 1) / 8)

        case 0x26: // Vibration (zoned amplitude + frequency in Hz)
            let z = zones(mask: u16(0), packed: u32(2))
            let freq = Float(p[8])
            self = (z.allSatisfy { $0 == 0 } || freq == 0) ? .off : .vibration(zones: z, frequency: min(freq / 255, 1))

        case 0x23: // Galloping: rhythmic taps between two zones
            guard let (s, e) = span(u16(0)) else { self = .off; return }
            let z = (0..<Self.zoneCount).map { i -> Float in
                let pos = Float(i) / 9
                return (pos >= s && pos <= e) ? 0.6 : 0
            }
            self = .vibration(zones: z, frequency: min(Float(p[3]) / 255, 1))

        case 0x27: // Machine: vibration between two zones, two amplitudes
            guard let (s, e) = span(u16(0)) else { self = .off; return }
            let ampA = Float(p[2] & 0x7) / 7, ampB = Float((p[2] >> 3) & 0x7) / 7
            let amp = max(ampA, ampB)
            let z = (0..<Self.zoneCount).map { i -> Float in
                let pos = Float(i) / 9
                return (pos >= s && pos <= e) ? amp : 0
            }
            self = amp == 0 ? .off : .vibration(zones: z, frequency: min(Float(p[3]) / 255, 1))

        case 0x01: // Simple feedback: start position, force (0-255 each)
            let start = Float(p[0]) / 255, force = Float(p[1]) / 255
            self = force == 0 ? .off : .feedback(zones: (0..<Self.zoneCount).map { Float($0) / 9 >= start ? force : 0 })

        case 0x02: // Simple weapon: start, end, force
            let force = Float(p[2]) / 255
            self = force == 0 ? .off : .weapon(start: Float(p[0]) / 255, end: max(Float(p[1]) / 255, Float(p[0]) / 255), strength: force)

        case 0x06: // Simple vibration: frequency, amplitude, start position
            let freq = Float(p[0]) / 255, amp = Float(p[1]) / 255, start = Float(p[2]) / 255
            self = (amp == 0 || freq == 0) ? .off
                : .vibration(zones: (0..<Self.zoneCount).map { Float($0) / 9 >= start ? amp : 0 }, frequency: freq)

        default: // 0x05 = off, 0x00 = reset, anything unknown
            self = .off
        }
    }

    /// Plays this effect on one DualSense trigger. `scale` lets the user soften effects.
    func apply(to trigger: GCDualSenseAdaptiveTrigger, scale: Float = 1) {
        let k = max(0, min(scale, 1))
        switch self {
        case .off:
            trigger.setModeOff()
        case .feedback(let z):
            var strengths = GCDualSenseAdaptiveTrigger.PositionalResistiveStrengths()
            withUnsafeMutableBytes(of: &strengths.values) { raw in
                let f = raw.bindMemory(to: Float.self)
                for i in 0..<min(f.count, z.count) { f[i] = z[i] * k }
            }
            trigger.setModeFeedback(resistiveStrengths: strengths)
        case .weapon(let s, let e, let strength):
            trigger.setModeWeaponWithStartPosition(s, endPosition: max(e, s + 0.05), resistiveStrength: strength * k)
        case .vibration(let z, let freq):
            var amps = GCDualSenseAdaptiveTrigger.PositionalAmplitudes()
            withUnsafeMutableBytes(of: &amps.values) { raw in
                let f = raw.bindMemory(to: Float.self)
                for i in 0..<min(f.count, z.count) { f[i] = z[i] * k }
            }
            trigger.setModeVibration(amplitudes: amps, frequency: freq)
        }
    }
}
