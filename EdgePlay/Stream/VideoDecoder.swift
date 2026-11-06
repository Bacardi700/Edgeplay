// SPDX-License-Identifier: AGPL-3.0-only

import AVFoundation
import CoreMedia
import UIKit
import VideoToolbox

/// Turns chiaki's Annex-B access units into CMSampleBuffers and hands them to an
/// AVSampleBufferDisplayLayer, which decodes in hardware and shows each frame immediately.
final class VideoDecoder {
    /// Fallback output when Metal isn't available.
    let layer = AVSampleBufferDisplayLayer()
    /// Preferred output: hardware decode to pixel buffers, then Metal (upscale + sharpen).
    let renderer: MetalVideoRenderer?
    var outputLayer: CALayer { renderer?.layer ?? layer }
    private let hevc: Bool
    private let tenBit: Bool
    private var vtSession: VTDecompressionSession?
    private let vtLock = NSLock()   // decode runs on chiaki's thread, reset on main

    private var formatDescription: CMVideoFormatDescription?
    private var vps: Data?, sps: Data?, pps: Data?

    /// Called (on the stream thread) when the picture size becomes known or changes.
    var onDimensions: ((CMVideoDimensions) -> Void)?

    // Counters read by the stats HUD.
    private let lock = NSLock()
    private var frames = 0
    private var bytes = 0

    init(hevc: Bool, hdr: Bool = false, useMetal: Bool = true) {
        self.hevc = hevc
        self.tenBit = hdr
        self.renderer = useMetal ? MetalVideoRenderer(hdr: hdr) : nil
        layer.videoGravity = .resize          // geometry is handled by the view's frame
        layer.preventsDisplaySleepDuringVideoPlayback = true
        layer.backgroundColor = UIColor.black.cgColor
    }

    /// Returns frames and bytes received since the last call.
    func takeCounters() -> (frames: Int, bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        let r = (frames, bytes)
        frames = 0; bytes = 0
        return r
    }

    /// Returns false when the frame can't be shown; chiaki then requests a keyframe.
    func enqueue(_ base: UnsafePointer<UInt8>, count: Int) -> Bool {
        lock.lock(); frames += 1; bytes += count; lock.unlock()

        let nals = Self.splitAnnexB(base, count: count)
        var payload: [Range<Int>] = []
        var paramsChanged = false

        for r in nals where !r.isEmpty {
            let header = base[r.lowerBound]
            if hevc {
                let type = (header >> 1) & 0x3F
                switch type {
                case 32: paramsChanged = update(&vps, base, r) || paramsChanged
                case 33: paramsChanged = update(&sps, base, r) || paramsChanged
                case 34: paramsChanged = update(&pps, base, r) || paramsChanged
                case 35: break // access unit delimiter
                default: payload.append(r)
                }
            } else {
                let type = header & 0x1F
                switch type {
                case 7: paramsChanged = update(&sps, base, r) || paramsChanged
                case 8: paramsChanged = update(&pps, base, r) || paramsChanged
                case 9: break // access unit delimiter
                default: payload.append(r)
                }
            }
        }

        if paramsChanged || formatDescription == nil {
            if !rebuildFormat() && formatDescription == nil {
                return payload.isEmpty // nothing usable yet; ask for a keyframe if we dropped a picture
            }
        }
        guard let format = formatDescription else { return false }
        if payload.isEmpty { return true }

        // Annex-B start codes -> 4-byte big-endian lengths (AVCC/HVCC layout).
        let total = payload.reduce(0) { $0 + 4 + $1.count }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: total, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: total,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return false }

        var offset = 0
        for r in payload {
            var len = UInt32(r.count).bigEndian
            guard CMBlockBufferReplaceDataBytes(with: &len, blockBuffer: block, offsetIntoDestination: offset, dataLength: 4) == noErr,
                  CMBlockBufferReplaceDataBytes(with: base + r.lowerBound, blockBuffer: block, offsetIntoDestination: offset + 4, dataLength: r.count) == noErr
            else { return false }
            offset += 4 + r.count
        }

        var sample: CMSampleBuffer?
        var size = total
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return false }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        if let renderer {
            return decode(sample, format: format, to: renderer)
        }
        if layer.status == .failed {
            // Usually after the app was backgrounded. Reset and wait for a keyframe.
            layer.flush()
            return false
        }
        layer.enqueue(sample)
        return true
    }

    func reset() {
        layer.flushAndRemoveImage()
        vtLock.lock(); invalidateSession(); vtLock.unlock()
        renderer?.flush()
    }

    // MARK: - VideoToolbox path

    private var sessionFormat: CMVideoFormatDescription?

    private func decode(_ sample: CMSampleBuffer, format: CMVideoFormatDescription, to renderer: MetalVideoRenderer) -> Bool {
        vtLock.lock(); defer { vtLock.unlock() }
        if vtSession == nil || sessionFormat.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: format) }) ?? true {
            invalidateSession()
            guard makeSession(format) else { return false }
        }
        guard let session = vtSession else { return false }
        var ok = true
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            if status == noErr, let image { renderer.submit(image) } else { ok = false }
        }
        if status == kVTInvalidSessionErr {
            // Happens after the app was in the background; rebuild on the next keyframe.
            invalidateSession()
            return false
        }
        return status == noErr && ok
    }

    private func makeSession(_ format: CMVideoFormatDescription) -> Bool {
        let pixelFormat = tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
        ]
        var s: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
                                                  decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary,
                                                  outputCallback: nil, decompressionSessionOut: &s)
        guard status == noErr, let s else { return false }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        vtSession = s
        sessionFormat = format
        return true
    }

    private func invalidateSession() {
        if let s = vtSession { VTDecompressionSessionInvalidate(s) }
        vtSession = nil
        sessionFormat = nil
    }

    // MARK: - helpers

    private func update(_ slot: inout Data?, _ base: UnsafePointer<UInt8>, _ r: Range<Int>) -> Bool {
        let d = Data(bytes: base + r.lowerBound, count: r.count)
        if slot == d { return false }
        slot = d
        return true
    }

    @discardableResult
    private func rebuildFormat() -> Bool {
        var fmt: CMFormatDescription?
        var status: OSStatus = -1
        if hevc {
            guard let vps, let sps, let pps else { return false }
            status = withPointers([vps, sps, pps]) { ptrs, sizes in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 3,
                                                                    parameterSetPointers: ptrs, parameterSetSizes: sizes,
                                                                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fmt)
            }
        } else {
            guard let sps, let pps else { return false }
            status = withPointers([sps, pps]) { ptrs, sizes in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2,
                                                                    parameterSetPointers: ptrs, parameterSetSizes: sizes,
                                                                    nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
            }
        }
        guard status == noErr, let fmt else { return false }
        let old = formatDescription.map { CMVideoFormatDescriptionGetDimensions($0) }
        formatDescription = fmt
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        if old?.width != dims.width || old?.height != dims.height {
            onDimensions?(dims)
        }
        return true
    }

    private func withPointers(_ sets: [Data], _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> OSStatus) -> OSStatus {
        // Copy into stable buffers for the duration of the call.
        let buffers = sets.map { d -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count)
            d.copyBytes(to: p, count: d.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        let ptrs = buffers.map { UnsafePointer($0) }
        let sizes = sets.map { $0.count }
        return ptrs.withUnsafeBufferPointer { p in
            sizes.withUnsafeBufferPointer { s in body(p.baseAddress!, s.baseAddress!) }
        }
    }

    /// Ranges of NAL unit payloads (without start codes).
    static func splitAnnexB(_ p: UnsafePointer<UInt8>, count n: Int) -> [Range<Int>] {
        var starts: [(code: Int, data: Int)] = []
        var i = 0
        while i + 2 < n {
            if p[i] == 0 && p[i + 1] == 0 {
                if p[i + 2] == 1 {
                    starts.append((i, i + 3)); i += 3; continue
                } else if i + 3 < n && p[i + 2] == 0 && p[i + 3] == 1 {
                    starts.append((i, i + 4)); i += 4; continue
                }
            }
            i += 1
        }
        var out: [Range<Int>] = []
        for (k, s) in starts.enumerated() {
            let end = k + 1 < starts.count ? starts[k + 1].code : n
            if end > s.data { out.append(s.data..<end) }
        }
        return out
    }
}
