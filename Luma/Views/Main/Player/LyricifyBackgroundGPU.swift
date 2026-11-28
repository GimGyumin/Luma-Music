// Lyricify Backgrounds — Apple Music Inspired · iOS, modern iOS background.
// Ported from https://github.com/WXRIW/Lyricify-Backgrounds
// Reference commit: cbef8a667c02a01707c78c7e76dc67d65cf161ed
// Source: AppleMusicIosRendererView.cs / AppleMusicIosRenderer.cs / AppleMusicIosBackground.hlsl
// Copyright the Lyricify Backgrounds contributors. Licensed under Apache License 2.0.
// Swift/Metal port © 2026 Luma contributors. Changes: Metal renderer, ColorSync-managed sRGB output,
// Luma lifecycle and PCM integration, no Windows audio loopback.
// See Luma/Resources/Licenses/Lyricify-Apache-2.0.txt and THIRD_PARTY_NOTICES.md.
//
// WWDC26 "Compose advanced graphics effects with SwiftUI" was evaluated: its
// layerEffect + noise-texture domain warp is a single-layer SwiftUI effect and cannot
// express Lyricify's three rotated instances, Catmull-Clark pinch mesh, or separable
// sigma-42.5 blur. Those passes stay in this native Metal renderer; the WWDC26 sample's
// GPU-driven time/noise approach informs the lifecycle and avoids per-frame SwiftUI work.

import Foundation
import Metal
import MetalKit
import QuartzCore

nonisolated struct LyricifyFrameConstants: Sendable {
    var time: Float
    var transitionMix: Float
    var viewScale: SIMD2<Float>
    var blackScrimAlpha: Float
    var outputDitherStrength: Float
    var blurScale: SIMD2<Float>
    var imageScales: SIMD4<Float>
    var pinchTextureTransform: SIMD4<Float>
    var rotationScale: Float
    var padding: SIMD2<Float> = .zero
}

nonisolated struct LyricifyQuadVertex: Sendable {
    var position: SIMD4<Float>
    var uv: SIMD2<Float>
}

/// One renderer owns every GPU object. SwiftUI never drives the frame loop.
nonisolated final class LyricifyBackgroundGPU: @unchecked Sendable {
    struct Frame {
        let texture: any MTLTexture
        let commandBuffer: any MTLCommandBuffer
    }

    enum SetupError: Error { case unavailable }
    enum DebugStage: Equatable {
        case artwork, base, layer0, layer1, layer2
        case rotation, rotationRaw
        case blurHorizontalRaw, blurVerticalRaw
        case treatedFirst, treatedSecond, blur, treatedScrim, final
    }
    private enum RotationContent { case full, baseOnly, layer(Int) }

    static let artworkTransitionSeconds: Double = 0.5
    static let blurSigma: Float = 42.5
    // Upstream allocates for the widest (ordinary-mode) sigma, then applies the
    // lyrics-mode sigma to those same targets. Both Luma panels use lyrics mode.
    static let blurDownsample = 4.0 * 80.0 / Double(blurSigma)
    static let imagePulseIntensity: Float = 0.33
    static let darkScrimAlpha: Float = 0.4
    static let lightScrimAlpha: Float = 1.0 / 3.0
    static let portraitTextureScale: Float = 1
    static let landscapeTextureScale: Float = 0.8

    let device: any MTLDevice
    let presetSlot: Int

    private let queue: any MTLCommandQueue
    private let basePipeline: any MTLRenderPipelineState
    private let rotationPipeline: any MTLRenderPipelineState
    private let blurHorizontalPipeline: any MTLRenderPipelineState
    private let blurVerticalPipeline: any MTLRenderPipelineState
    private let treatedPipeline: any MTLRenderPipelineState
    private let treatedFirstPipeline: any MTLRenderPipelineState
    private let treatedSecondPipeline: any MTLRenderPipelineState
    private let rawPipeline: any MTLRenderPipelineState
    private let pinchPipeline: any MTLRenderPipelineState
    private let quadBuffer: any MTLBuffer
    private let quadIndexBuffer: any MTLBuffer
    private let portraitMesh: (vertices: any MTLBuffer, indices: any MTLBuffer, count: Int)
    private let landscapeMesh: (vertices: any MTLBuffer, indices: any MTLBuffer, count: Int)

    private var currentArtwork: (any MTLTexture)?
    private var previousArtwork: (any MTLTexture)?
    private var pendingTransition = false
    private var transitionStart: Double?
    var hasArtwork: Bool { currentArtwork != nil }
    var isTransitioning: Bool { previousArtwork != nil }
    private var rotationSurface: (any MTLTexture)?
    private var horizontalBlurSurface: (any MTLTexture)?
    private var verticalBlurSurface: (any MTLTexture)?
    private var outputSurface: (any MTLTexture)?
    private var surfaceSize: (width: Int, height: Int) = (0, 0)

    init(device: any MTLDevice, bundle: Bundle = .main, presetSlot: Int? = nil) throws {
        self.device = device
        self.presetSlot = presetSlot ?? Int.random(in: 0..<LyricifyBackgroundMesh.presetSlotCount)
        guard let queue = device.makeCommandQueue() else { throw SetupError.unavailable }
        self.queue = queue

        let library = try device.makeDefaultLibrary(bundle: bundle)
        func pipeline(vertex: String, fragment: String, format: MTLPixelFormat) throws -> any MTLRenderPipelineState {
            guard let vertexFunction = library.makeFunction(name: vertex),
                  let fragmentFunction = library.makeFunction(name: fragment) else {
                throw SetupError.unavailable
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        basePipeline = try pipeline(vertex: "lyricifyArtworkFillVertex",
            fragment: "lyricifyRotationFragment", format: .rgba16Float)
        rotationPipeline = try pipeline(vertex: "lyricifyRotationVertex",
            fragment: "lyricifyRotationFragment", format: .rgba16Float)
        blurHorizontalPipeline = try pipeline(vertex: "lyricifyFullscreenVertex",
            fragment: "lyricifyBlurHorizontal", format: .rgba16Float)
        blurVerticalPipeline = try pipeline(vertex: "lyricifyFullscreenVertex",
            fragment: "lyricifyBlurVertical", format: .rgba16Float)
        treatedPipeline = try pipeline(vertex: "lyricifyFullscreenVertex",
            fragment: "lyricifyTreatedFragment", format: .bgra8Unorm)
        treatedFirstPipeline = try pipeline(vertex: "lyricifyFullscreenVertex",
            fragment: "lyricifyTreatedFirstFragment", format: .bgra8Unorm)
        treatedSecondPipeline = try pipeline(vertex: "lyricifyFullscreenVertex",
            fragment: "lyricifyTreatedSecondFragment", format: .bgra8Unorm)
        rawPipeline = try pipeline(vertex: "lyricifyFullscreenVertex",
            fragment: "lyricifyRawFragment", format: .bgra8Unorm)
        pinchPipeline = try pipeline(vertex: "lyricifyPinchVertex",
            fragment: "lyricifyPinchFragment", format: .bgra8Unorm)

        let quadVertices = [
            LyricifyQuadVertex(position: SIMD4<Float>(-1, -1, 0, 1), uv: SIMD2<Float>(0, 1)),
            LyricifyQuadVertex(position: SIMD4<Float>(-1, 1, 0, 1), uv: SIMD2<Float>(0, 0)),
            LyricifyQuadVertex(position: SIMD4<Float>(1, 1, 0, 1), uv: SIMD2<Float>(1, 0)),
            LyricifyQuadVertex(position: SIMD4<Float>(1, -1, 0, 1), uv: SIMD2<Float>(1, 1))
        ]
        let quadIndices: [UInt16] = [0, 1, 2, 2, 3, 0]
        guard let quadBuffer = device.makeBuffer(bytes: quadVertices,
            length: MemoryLayout<LyricifyQuadVertex>.stride * quadVertices.count,
            options: .storageModeShared),
              let quadIndexBuffer = device.makeBuffer(bytes: quadIndices,
            length: MemoryLayout<UInt16>.stride * quadIndices.count,
            options: .storageModeShared) else {
            throw SetupError.unavailable
        }
        self.quadBuffer = quadBuffer
        self.quadIndexBuffer = quadIndexBuffer

        func mesh(_ isPortrait: Bool) -> (any MTLBuffer, any MTLBuffer, Int)? {
            let mesh = LyricifyBackgroundMesh.make(presetSlot: presetSlot, isVerticalLayout: isPortrait)
            let vertices = mesh.vertices
            let indices = mesh.indices
            guard let vertexBuffer = device.makeBuffer(bytes: vertices,
                length: MemoryLayout<LyricifyPinchVertex>.stride * vertices.count,
                options: .storageModeShared),
                  let indexBuffer = device.makeBuffer(bytes: indices,
                length: MemoryLayout<UInt16>.stride * indices.count,
                options: .storageModeShared) else { return nil }
            return (vertexBuffer, indexBuffer, indices.count)
        }
        guard let portrait = mesh(true), let landscape = mesh(false) else { throw SetupError.unavailable }
        portraitMesh = portrait
        landscapeMesh = landscape
    }

    /// Replaces the artwork. The previous texture is retained only while the 0.5 s
    /// Lyricify crossfade is pending.
    @discardableResult
    func replaceArtwork(_ texture: any MTLTexture, crossfade: Bool) -> Bool {
        guard currentArtwork !== texture else { return false }
        previousArtwork = crossfade ? currentArtwork : nil
        currentArtwork = texture
        pendingTransition = crossfade && previousArtwork != nil
        transitionStart = nil
        return pendingTransition
    }

    func releaseArtwork() {
        currentArtwork = nil
        previousArtwork = nil
        pendingTransition = false
        transitionStart = nil
    }

    /// Renders one frame. `pulsePower` is the Lyricify 0...1 processed bass response.
    func render(
        size: CGSize,
        elapsed: Double,
        motionTime: Double? = nil,
        pulsePower: Float,
        isLandscape: Bool,
        lightAppearance: Bool,
        rotationScale: Float = 1,
        drawable: (any CAMetalDrawable)? = nil,
        debugStage: DebugStage? = nil
    ) -> Frame? {
        guard let artwork = currentArtwork else { return nil }
        let width = drawable?.texture.width ?? Int(size.width.rounded())
        let height = drawable?.texture.height ?? Int(size.height.rounded())
        guard width > 0, height > 0 else { return nil }
        ensureSurfaces(width: width, height: height, outputTexture: drawable?.texture)
        guard let rotationSurface, let horizontalBlurSurface, let verticalBlurSurface,
              let command = queue.makeCommandBuffer() else { return nil }
        let outputTexture = drawable?.texture ?? outputSurface
        guard let outputTexture else { return nil }

        if pendingTransition {
            transitionStart = elapsed
            pendingTransition = false
        }
        let transitionMix: Float
        if let transitionStart, previousArtwork != nil {
            transitionMix = Float(min(1, max(0, (elapsed - transitionStart) / Self.artworkTransitionSeconds)))
        } else {
            transitionMix = 1
        }
        if transitionMix >= 1 {
            previousArtwork = nil
        }

        let viewAspect = Float(width) / Float(height)
        let viewScale = viewAspect >= 1
            ? SIMD2<Float>(1, viewAspect)
            : SIMD2<Float>(1 / viewAspect, 1)
        let textureScale = isLandscape ? Self.landscapeTextureScale : Self.portraitTextureScale
        let textureOffset = (1 - textureScale) * 0.5
        let pulse = min(1, max(0, pulsePower))
        let imageScale = 1 + Self.imagePulseIntensity * pulse * pulse
        let kernelScale: Float = 4
        let blurScale = SIMD2<Float>(
            kernelScale * Float(rotationSurface.width) / Float(width),
            kernelScale * Float(rotationSurface.height) / Float(height))
        let ambient = max(0, motionTime ?? elapsed)
        let constants = LyricifyFrameConstants(
            time: Float(ambient),
            transitionMix: transitionMix,
            viewScale: viewScale,
            blackScrimAlpha: lightAppearance ? Self.lightScrimAlpha : Self.darkScrimAlpha,
            outputDitherStrength: 1,
            blurScale: blurScale,
            imageScales: SIMD4<Float>(imageScale, imageScale, imageScale, 1),
            pinchTextureTransform: SIMD4<Float>(textureScale, textureScale, textureOffset, textureOffset),
            rotationScale: min(4, max(0, rotationScale)))

        if debugStage == .artwork {
            guard encodeRaw(command: command, source: artwork, target: outputTexture) else { return nil }
            if let drawable { command.present(drawable) }
            return Frame(texture: outputTexture, commandBuffer: command)
        }
        let rotationContent: RotationContent
        switch debugStage {
        case .base: rotationContent = .baseOnly
        case .layer0: rotationContent = .layer(0)
        case .layer1: rotationContent = .layer(1)
        case .layer2: rotationContent = .layer(2)
        default: rotationContent = .full
        }
        guard encodeRotation(command: command, target: rotationSurface, artwork: artwork,
                             constants: constants, content: rotationContent) else { return nil }
        if debugStage == .base || debugStage == .layer0 || debugStage == .layer1 || debugStage == .layer2 {
            guard encodeRaw(command: command, source: rotationSurface, target: outputTexture) else { return nil }
            if let drawable { command.present(drawable) }
            return Frame(texture: outputTexture, commandBuffer: command)
        }
        if debugStage == .rotationRaw || debugStage == .rotation {
            if debugStage == .rotationRaw {
                guard encodeRaw(command: command, source: rotationSurface, target: outputTexture) else { return nil }
            } else {
                guard encodeTreated(command: command, source: rotationSurface,
                                    target: outputTexture, constants: constants) else { return nil }
            }
            if let drawable { command.present(drawable) }
            return Frame(texture: outputTexture, commandBuffer: command)
        }
        guard encodeBlur(command: command, source: rotationSurface, target: horizontalBlurSurface,
                         pipeline: blurHorizontalPipeline, constants: constants) else { return nil }
        if debugStage == .blurHorizontalRaw {
            guard encodeRaw(command: command, source: horizontalBlurSurface, target: outputTexture) else { return nil }
            if let drawable { command.present(drawable) }
            return Frame(texture: outputTexture, commandBuffer: command)
        }
        guard encodeBlur(command: command, source: horizontalBlurSurface, target: verticalBlurSurface,
                         pipeline: blurVerticalPipeline, constants: constants) else { return nil }
        if debugStage == .blurVerticalRaw {
            guard encodeRaw(command: command, source: verticalBlurSurface, target: outputTexture) else { return nil }
            if let drawable { command.present(drawable) }
            return Frame(texture: outputTexture, commandBuffer: command)
        }
        if debugStage == .treatedFirst {
            guard encodeTreated(command: command, source: verticalBlurSurface,
                                target: outputTexture, constants: constants,
                                pipeline: treatedFirstPipeline) else { return nil }
            if let drawable { command.present(drawable) }
            return Frame(texture: outputTexture, commandBuffer: command)
        }
        if debugStage == .treatedSecond {
            guard encodeTreated(command: command, source: verticalBlurSurface,
                                target: outputTexture, constants: constants,
                                pipeline: treatedSecondPipeline) else { return nil }
            if let drawable { command.present(drawable) }
            return Frame(texture: outputTexture, commandBuffer: command)
        }
        if debugStage == .blur || debugStage == .treatedScrim {
            guard encodeTreated(command: command, source: verticalBlurSurface,
                                target: outputTexture, constants: constants) else { return nil }
            if let drawable { command.present(drawable) }
            return Frame(texture: outputTexture, commandBuffer: command)
        }
        guard encodeComposite(command: command, source: verticalBlurSurface,
                          target: outputTexture, constants: constants, isLandscape: isLandscape) else { return nil }
        if let drawable { command.present(drawable) }
        return Frame(texture: outputTexture, commandBuffer: command)
    }

    private func ensureSurfaces(width: Int, height: Int, outputTexture: (any MTLTexture)?) {
        let blurWidth = max(1, Int(Double(width) / Self.blurDownsample))
        let blurHeight = max(1, Int(Double(height) / Self.blurDownsample))
        if surfaceSize.width == width, surfaceSize.height == height,
           rotationSurface != nil, horizontalBlurSurface != nil, verticalBlurSurface != nil,
           outputTexture != nil || outputSurface != nil {
            return
        }
        surfaceSize = (width, height)
        rotationSurface = makeTexture(width: blurWidth, height: blurHeight, format: .rgba16Float)
        horizontalBlurSurface = makeTexture(width: blurWidth, height: blurHeight, format: .rgba16Float)
        verticalBlurSurface = makeTexture(width: blurWidth, height: blurHeight, format: .rgba16Float)
        outputSurface = outputTexture == nil
            ? makeTexture(width: width, height: height, format: .bgra8Unorm, storageMode: .shared)
            : nil
    }

    private func makeTexture(
        width: Int, height: Int, format: MTLPixelFormat,
        storageMode: MTLStorageMode = .private
    ) -> (any MTLTexture)? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.storageMode = storageMode
        descriptor.usage = [.renderTarget, .shaderRead]
        return device.makeTexture(descriptor: descriptor)
    }

    private func encodeRotation(
        command: any MTLCommandBuffer,
        target: any MTLTexture,
        artwork: any MTLTexture,
        constants: LyricifyFrameConstants,
        content: RotationContent = .full
    ) -> Bool {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setVertexBuffer(quadBuffer, offset: 0, index: 1)
        encoder.setFragmentTexture(artwork, index: 0)
        encoder.setFragmentTexture(previousArtwork ?? artwork, index: 1)
        var constants = constants
        encoder.setVertexBytes(&constants, length: MemoryLayout<LyricifyFrameConstants>.stride, index: 0)
        encoder.setFragmentBytes(&constants, length: MemoryLayout<LyricifyFrameConstants>.stride, index: 0)
        encoder.setRenderPipelineState(basePipeline)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: 6, indexType: .uint16,
            indexBuffer: quadIndexBuffer, indexBufferOffset: 0,
            instanceCount: 1, baseVertex: 0, baseInstance: 0)

        switch content {
        case .baseOnly:
            break
        case .layer(let index):
            encoder.setRenderPipelineState(rotationPipeline)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: 6, indexType: .uint16,
                indexBuffer: quadIndexBuffer, indexBufferOffset: 0,
                instanceCount: 1, baseVertex: 0, baseInstance: index)
        case .full:
            encoder.setRenderPipelineState(rotationPipeline)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: 6, indexType: .uint16,
                indexBuffer: quadIndexBuffer, indexBufferOffset: 0, instanceCount: 3)
        }
        encoder.endEncoding()
        return true
    }

    private func encodeBlur(
        command: any MTLCommandBuffer,
        source: any MTLTexture,
        target: any MTLTexture,
        pipeline: any MTLRenderPipelineState,
        constants: LyricifyFrameConstants
    ) -> Bool {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var constants = constants
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&constants, length: MemoryLayout<LyricifyFrameConstants>.stride, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    private func encodeRaw(
        command: any MTLCommandBuffer,
        source: any MTLTexture,
        target: any MTLTexture
    ) -> Bool {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(rawPipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    private func encodeTreated(
        command: any MTLCommandBuffer,
        source: any MTLTexture,
        target: any MTLTexture,
        constants: LyricifyFrameConstants,
        pipeline: (any MTLRenderPipelineState)? = nil
    ) -> Bool {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var constants = constants
        encoder.setRenderPipelineState(pipeline ?? treatedPipeline)
        encoder.setFragmentBytes(&constants, length: MemoryLayout<LyricifyFrameConstants>.stride, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    private func encodeComposite(
        command: any MTLCommandBuffer,
        source: any MTLTexture,
        target: any MTLTexture,
        constants: LyricifyFrameConstants,
        isLandscape: Bool
    ) -> Bool {
        let mesh = isLandscape ? landscapeMesh : portraitMesh
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var constants = constants
        encoder.setFragmentBytes(&constants, length: MemoryLayout<LyricifyFrameConstants>.stride, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        // Preserve the full-screen backing under the mesh in the same render pass.
        encoder.setRenderPipelineState(treatedPipeline)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.setRenderPipelineState(pinchPipeline)
        encoder.setVertexBytes(&constants, length: MemoryLayout<LyricifyFrameConstants>.stride, index: 0)
        encoder.setVertexBuffer(mesh.vertices, offset: 0, index: 1)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.count, indexType: .uint16,
            indexBuffer: mesh.indices, indexBufferOffset: 0)
        encoder.endEncoding()
        return true
    }
}

/// Cached, gamma-encoded artwork texture for the HLSL-compatible treatment.
nonisolated final class PreparedLyricifyArtwork: @unchecked Sendable {
    private(set) weak var image: PlatformImage?
    let texture: any MTLTexture

    init(image: PlatformImage, texture: any MTLTexture) {
        self.image = image
        self.texture = texture
    }

    static func prepare(image: PlatformImage, device: any MTLDevice) -> PreparedLyricifyArtwork? {
        guard !Task.isCancelled else { return nil }
        #if os(iOS)
        guard let original = image.cgImage else { return nil }
        #else
        guard let original = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #endif
        let shouldResize = original.width * original.height > 100_000
        let scale = shouldResize ? 300 / Double(max(original.width, original.height)) : 1
        let width = max(1, Int(Double(original.width) * scale))
        let height = max(1, Int(Double(original.height) * scale))
        let rowBytes = width * 4
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: rowBytes, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard !Task.isCancelled, let data = context.data else { return nil }

        // Match the upstream straight-alpha bitmap, reusing the raster storage.
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        for index in stride(from: 0, to: height * rowBytes, by: 4) {
            let alpha = Int(bytes[index + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for channel in 0..<3 {
                bytes[index + channel] = UInt8(min(255, Int(bytes[index + channel]) * 255 / alpha))
            }
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
            withBytes: data, bytesPerRow: rowBytes)
        return PreparedLyricifyArtwork(image: image, texture: texture)
    }
}

/// Reuses the existing artwork image objects; no second network or disk cache.
actor LyricifyArtworkTextureCache {
    static let shared = LyricifyArtworkTextureCache()
    private struct Key: Hashable { let image: ObjectIdentifier; let device: UInt64 }
    private var ready: [Key: PreparedLyricifyArtwork] = [:]
    private var recent: [Key] = []

    func artwork(image: PlatformImage, device: any MTLDevice) async -> PreparedLyricifyArtwork? {
        guard !Task.isCancelled else { return nil }
        let key = Key(image: ObjectIdentifier(image), device: device.registryID)
        if let cached = ready[key], cached.image === image {
            touch(key)
            return cached
        }
        ready[key] = nil
        let prepared = await Task.detached(priority: .utility) {
            PreparedLyricifyArtwork.prepare(image: image, device: device)
        }.value
        guard !Task.isCancelled, let prepared else { return nil }
        ready[key] = prepared
        touch(key)
        while recent.count > 6 { ready[recent.removeFirst()] = nil }
        return prepared
    }

    func removeAll() {
        ready.removeAll()
        recent.removeAll()
    }

    private func touch(_ key: Key) {
        recent.removeAll { $0 == key }
        recent.append(key)
    }
}
