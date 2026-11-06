// SPDX-License-Identifier: AGPL-3.0-only

import CoreVideo
import Metal
import MetalFX
import QuartzCore
import UIKit

/// Draws decoded frames with Metal:
///   YCbCr -> RGB  ->  MetalFX spatial upscale to the screen's real pixel size
///   ->  contrast-adaptive sharpening  ->  screen
/// Frames are presented from a display link (up to 120 Hz on ProMotion), always
/// showing the newest decoded frame, which keeps latency low and pacing even.
final class MetalVideoRenderer {
    let layer = CAMetalLayer()
    let hdr: Bool

    var sharpness: Float = 0.35
    var useMetalFX = true

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let convertPipeline: MTLRenderPipelineState
    private let presentPipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private let intermediateFormat: MTLPixelFormat = .rgba16Float

    private var rgbTexture: MTLTexture?
    private var upscaledTexture: MTLTexture?
    private var scaler: MTLFXSpatialScaler?
    private var scalerKey: (Int, Int, Int, Int) = (0, 0, 0, 0)

    private let lock = NSLock()
    private var pending: CVPixelBuffer?
    private var displayLink: CADisplayLink?
    private(set) var presentedFrames = 0

    /// Returns nil if Metal isn't usable; the caller then falls back to AVSampleBufferDisplayLayer.
    init?(hdr: Bool) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vtx = library.makeFunction(name: "fullscreen_vertex"),
              let convert = library.makeFunction(name: "ycbcr_to_rgb"),
              let present = library.makeFunction(name: "present_sharpen") else { return nil }
        self.device = device
        self.queue = queue
        self.hdr = hdr

        layer.device = device
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.backgroundColor = UIColor.black.cgColor
        if hdr {
            // Shader output stays PQ-encoded BT.2020; tell the compositor so.
            layer.pixelFormat = .bgr10a2Unorm
            layer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
            layer.wantsExtendedDynamicRangeContent = true
        } else {
            layer.pixelFormat = .bgra8Unorm
            layer.colorspace = CGColorSpace(name: CGColorSpace.itur_709)
        }

        func pipeline(_ fragment: MTLFunction, _ format: MTLPixelFormat) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vtx
            d.fragmentFunction = fragment
            d.colorAttachments[0].pixelFormat = format
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let cp = pipeline(convert, intermediateFormat),
              let pp = pipeline(present, layer.pixelFormat) else { return nil }
        convertPipeline = cp
        presentPipeline = pp
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        guard textureCache != nil else { return nil }
    }

    static var metalFXSupported: Bool {
        guard let d = MTLCreateSystemDefaultDevice() else { return false }
        return MTLFXSpatialScalerDescriptor.supportsDevice(d)
    }

    // MARK: lifecycle

    func start(highRefresh: Bool) {
        stop()
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick))
        let maxFPS = Float(UIScreen.main.maximumFramesPerSecond)
        let top = highRefresh ? maxFPS : min(60, maxFPS)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, top), maximum: top, preferred: top)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func setDrawableSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        if layer.drawableSize != size { layer.drawableSize = size }
    }

    /// Called from the decoder thread with each new frame; the newest one wins.
    func submit(_ pixelBuffer: CVPixelBuffer) {
        lock.lock(); pending = pixelBuffer; lock.unlock()
    }

    func flush() {
        lock.lock(); pending = nil; lock.unlock()
        if let cache = textureCache { CVMetalTextureCacheFlush(cache, 0) }
    }

    // MARK: drawing

    fileprivate func renderIfNeeded() {
        lock.lock()
        let frame = pending
        pending = nil
        lock.unlock()
        guard let frame else { return }
        draw(frame)
    }

    private func draw(_ pb: CVPixelBuffer) {
        guard let cache = textureCache,
              CVPixelBufferGetPlaneCount(pb) >= 2 else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let tenBit = CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        guard let (lumaRef, luma) = planeTexture(cache, pb, plane: 0, format: tenBit ? .r16Unorm : .r8Unorm),
              let (chromaRef, chroma) = planeTexture(cache, pb, plane: 1, format: tenBit ? .rg16Unorm : .rg8Unorm),
              let drawable = layer.nextDrawable(),
              let cmd = queue.makeCommandBuffer() else { return }

        // 1. YCbCr -> RGB at the stream's resolution.
        let rgb = texture(&rgbTexture, width: w, height: h)
        var params = Self.convertParams(for: pb)
        let rp1 = MTLRenderPassDescriptor()
        rp1.colorAttachments[0].texture = rgb
        rp1.colorAttachments[0].loadAction = .dontCare
        rp1.colorAttachments[0].storeAction = .store
        if let enc = cmd.makeRenderCommandEncoder(descriptor: rp1) {
            enc.setRenderPipelineState(convertPipeline)
            enc.setFragmentTexture(luma, index: 0)
            enc.setFragmentTexture(chroma, index: 1)
            enc.setFragmentBytes(&params, length: MemoryLayout<ConvertParams>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        // 2. MetalFX upscale to the drawable's real pixel size, when it helps.
        let outW = drawable.texture.width, outH = drawable.texture.height
        var source: MTLTexture = rgb
        if useMetalFX, sharpness > 0, outW > w || outH > h, let up = upscale(rgb, w, h, outW, outH, cmd) {
            source = up
        }

        // 3. Sharpen + final scale to the screen.
        var pp = PresentParams(texel: SIMD2(1 / Float(source.width), 1 / Float(source.height)), sharpness: sharpness, pad: 0)
        let rp2 = MTLRenderPassDescriptor()
        rp2.colorAttachments[0].texture = drawable.texture
        rp2.colorAttachments[0].loadAction = .dontCare
        rp2.colorAttachments[0].storeAction = .store
        if let enc = cmd.makeRenderCommandEncoder(descriptor: rp2) {
            enc.setRenderPipelineState(presentPipeline)
            enc.setFragmentTexture(source, index: 0)
            enc.setFragmentBytes(&pp, length: MemoryLayout<PresentParams>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        cmd.present(drawable)
        // Keep the CoreVideo textures (and so the decoded frame) alive until the GPU is done.
        cmd.addCompletedHandler { _ in _ = lumaRef; _ = chromaRef; _ = pb }
        cmd.commit()
        presentedFrames += 1
    }

    private func upscale(_ input: MTLTexture, _ w: Int, _ h: Int, _ outW: Int, _ outH: Int, _ cmd: MTLCommandBuffer) -> MTLTexture? {
        if scaler == nil || scalerKey != (w, h, outW, outH) {
            let d = MTLFXSpatialScalerDescriptor()
            d.inputWidth = w
            d.inputHeight = h
            d.outputWidth = outW
            d.outputHeight = outH
            d.colorTextureFormat = intermediateFormat
            d.outputTextureFormat = intermediateFormat
            d.colorProcessingMode = .perceptual
            scaler = d.makeSpatialScaler(device: device)
            scalerKey = (w, h, outW, outH)
            upscaledTexture = nil
            if scaler == nil { useMetalFX = false; return nil }
        }
        guard let scaler else { return nil }
        if upscaledTexture == nil || upscaledTexture?.width != outW || upscaledTexture?.height != outH {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: intermediateFormat, width: outW, height: outH, mipmapped: false)
            td.usage = scaler.outputTextureUsage.union([.shaderRead, .renderTarget])
            td.storageMode = .private
            upscaledTexture = device.makeTexture(descriptor: td)
        }
        guard let out = upscaledTexture else { return nil }
        scaler.colorTexture = input
        scaler.outputTexture = out
        scaler.inputContentWidth = w
        scaler.inputContentHeight = h
        scaler.encode(commandBuffer: cmd)
        return out
    }

    private func texture(_ slot: inout MTLTexture?, width: Int, height: Int) -> MTLTexture {
        if let t = slot, t.width == width, t.height == height { return t }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: intermediateFormat, width: width, height: height, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        let t = device.makeTexture(descriptor: td)!
        slot = t
        return t
    }

    private func planeTexture(_ cache: CVMetalTextureCache, _ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> (CVMetalTexture, MTLTexture)? {
        let w = CVPixelBufferGetWidthOfPlane(pb, plane), h = CVPixelBufferGetHeightOfPlane(pb, plane)
        var ref: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, format, w, h, plane, &ref) == kCVReturnSuccess,
              let ref, let tex = CVMetalTextureGetTexture(ref) else { return nil }
        return (ref, tex)
    }

    // MARK: colour

    struct ConvertParams {
        var row0: SIMD4<Float>, row1: SIMD4<Float>, row2: SIMD4<Float>
        var range: SIMD4<Float>
    }

    struct PresentParams {
        var texel: SIMD2<Float>
        var sharpness: Float
        var pad: Float
    }

    /// Video-range YCbCr -> R'G'B', BT.709 or BT.2020 depending on the stream.
    static func convertParams(for pb: CVPixelBuffer) -> ConvertParams {
        let matrix = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) as? String
        let bt2020 = matrix == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)
        let range = SIMD4<Float>(16.0 / 255.0, 255.0 / 219.0, 128.0 / 255.0, 255.0 / 224.0)
        if bt2020 {
            return ConvertParams(row0: [1, 0, 1.4746, 0], row1: [1, -0.16455, -0.57135, 0], row2: [1, 1.8814, 0, 0], range: range)
        }
        return ConvertParams(row0: [1, 0, 1.5748, 0], row1: [1, -0.1873, -0.4681, 0], row2: [1, 1.8556, 0, 0], range: range)
    }
}

/// CADisplayLink retains its target; the proxy keeps that from leaking the renderer.
private final class DisplayLinkProxy: NSObject {
    weak var renderer: MetalVideoRenderer?
    init(_ r: MetalVideoRenderer) { renderer = r }
    @objc func tick() { renderer?.renderIfNeeded() }
}
