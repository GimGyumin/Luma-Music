import CoreGraphics
import Foundation
import Metal
import Testing
#if os(macOS)
import AppKit
#endif
@testable import Luma

@Suite("Lyricify background", .serialized)
struct LyricifyBackgroundTests {
    @Test("Portrait presets use the exact Lyricify 6x6 Catmull-Clark mesh")
    func portraitMeshPresets() {
        for slot in 0..<LyricifyBackgroundMesh.presetSlotCount {
            let mesh = LyricifyBackgroundMesh.make(
                presetSlot: slot, isVerticalLayout: true)
            #expect(mesh.vertices.count == 441)
            #expect(mesh.indices.count == 2_400)
            #expect(mesh.vertices.allSatisfy {
                $0.from.x.isFinite && $0.from.y.isFinite
                    && $0.to.x.isFinite && $0.to.y.isFinite
                    && $0.uv.x.isFinite && $0.uv.y.isFinite
            })
        }
    }

    @Test("Landscape presets use the exact Lyricify 9x9 Catmull-Clark mesh")
    func landscapeMeshPresets() {
        for slot in 0..<LyricifyBackgroundMesh.presetSlotCount {
            let mesh = LyricifyBackgroundMesh.make(
                presetSlot: slot, isVerticalLayout: false)
            #expect(mesh.vertices.count == 1_089)
            #expect(mesh.indices.count == 6_144)
            #expect(mesh.vertices.allSatisfy {
                $0.from.x.isFinite && $0.from.y.isFinite
                    && $0.to.x.isFinite && $0.to.y.isFinite
                    && $0.uv.x.isFinite && $0.uv.y.isFinite
            })
        }
    }

    @Test("The first portrait preset preserves the source's identity corner")
    func firstPortraitVertex() throws {
        let mesh = LyricifyBackgroundMesh.make(
            presetSlot: 0, isVerticalLayout: true)
        let first = try #require(mesh.vertices.first)
        #expect(first.from == SIMD2<Float>(-1, -1))
        #expect(first.to == SIMD2<Float>(-1, -1))
        #expect(first.uv == SIMD2<Float>(0, 1))
    }

    @Test("GPU uniform and vertex layouts match the Metal structs")
    func structLayouts() {
        #expect(MemoryLayout<LyricifyFrameConstants>.stride == 80)
        #expect(MemoryLayout<LyricifyQuadVertex>.stride == 32)
        #expect(MemoryLayout<LyricifyPinchVertex>.stride == 24)
    }

    @Test("Real PCM bass produces the Lyricify image scale and silence decays")
    func bassPulseFromPCM() {
        let analyzer = LyricifyBassAnalyzer.shared
        analyzer.reset()
        let sampleRate = 44_100.0
        let count = 4096
        let tone = (0..<count).map { index in
            Float(0.5 * sin(2 * .pi * 93.75 * Double(index) / sampleRate))
        }
        for _ in 0..<4 {
            tone.withUnsafeBufferPointer { buffer in
                analyzer.processWindow(channelData: [buffer.baseAddress!],
                    frameCount: count, sampleRate: sampleRate)
            }
        }
        let pulse = analyzer.pulsePower
        #expect(pulse > 0.05)
        #expect(analyzer.imageScale > 1.0)
        #expect(abs(analyzer.imageScale - (1 + 0.33 * pulse * pulse)) < 0.00001)
        analyzer.reset()
        #expect(analyzer.pulsePower == 0)
        #expect(analyzer.imageScale == 1)
    }

    @MainActor
    @Test("The Metal pipeline renders a finite Lyricify frame")
    func metalFrame() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let gpu = try LyricifyBackgroundGPU(device: device, presetSlot: 0)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 64, height: 64, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let artwork = try #require(device.makeTexture(descriptor: descriptor))
        let colors: [SIMD4<UInt8>] = [
            SIMD4(220, 40, 70, 255), SIMD4(30, 90, 230, 255),
            SIMD4(240, 190, 30, 255), SIMD4(90, 40, 190, 255)
        ]
        var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
        for y in 0..<64 {
            for x in 0..<64 {
                let color = colors[(x / 32) + (y / 32) * 2]
                for channel in 0..<4 { bytes[(y * 64 + x) * 4 + channel] = color[channel] }
            }
        }
        bytes.withUnsafeBytes {
            artwork.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: 64 * 4)
        }
        #expect(gpu.replaceArtwork(artwork, crossfade: false) == false)
        let renderWidth = 1206
        let renderHeight = 2622
        let frame = try #require(gpu.render(
            size: CGSize(width: renderWidth, height: renderHeight), elapsed: 12.5,
            pulsePower: 0.8, isLandscape: false, lightAppearance: false))
        frame.commandBuffer.commit()
        frame.commandBuffer.waitUntilCompleted()
        #expect(frame.commandBuffer.status == .completed)
        #expect(frame.texture.width == renderWidth && frame.texture.height == renderHeight)
        var pixels = [UInt8](repeating: 0, count: renderWidth * renderHeight * 4)
        pixels.withUnsafeMutableBytes {
            frame.texture.getBytes($0.baseAddress!, bytesPerRow: renderWidth * 4,
                from: MTLRegionMake2D(0, 0, renderWidth, renderHeight), mipmapLevel: 0)
        }
        #expect(frame.texture.pixelFormat == .bgra8Unorm)
        #expect(pixels.contains { $0 > 0 })
        #expect(Set(pixels).count > 1)
        #expect(stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 255 })
        print("LYRICIFY-FINAL \(pixelStats(pixels))")
        #if os(macOS)
        writePreview(pixels: pixels, width: renderWidth, height: renderHeight,
                     name: "luma-lyricify-preview.png")
        #endif

        for (stage, name) in [(LyricifyBackgroundGPU.DebugStage.artwork, "luma-lyricify-artwork.png"),
                              (.rotationRaw, "luma-lyricify-rotation-raw.png"),
                              (.rotation, "luma-lyricify-rotation.png"),
                              (.blur, "luma-lyricify-blur.png")] {
            let debugFrame = try #require(gpu.render(
                size: CGSize(width: renderWidth, height: renderHeight), elapsed: 12.5,
                pulsePower: 0.8, isLandscape: false, lightAppearance: false,
                debugStage: stage))
            debugFrame.commandBuffer.commit()
            debugFrame.commandBuffer.waitUntilCompleted()
            var debugPixels = [UInt8](repeating: 0, count: renderWidth * renderHeight * 4)
            debugPixels.withUnsafeMutableBytes {
                debugFrame.texture.getBytes($0.baseAddress!, bytesPerRow: renderWidth * 4,
                    from: MTLRegionMake2D(0, 0, renderWidth, renderHeight), mipmapLevel: 0)
            }
            print("LYRICIFY-\(stage) \(pixelStats(debugPixels))")
            #if os(macOS)
            writePreview(pixels: debugPixels, width: renderWidth, height: renderHeight, name: name)
            #endif
        }
    }

    @MainActor
    @Test("The modern material uses one continuous half-second artwork transition")
    func artworkCrossfade() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let gpu = try LyricifyBackgroundGPU(device: device, presetSlot: 0)
        func artwork(gray: UInt8) throws -> any MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = .shaderRead
            let texture = try #require(device.makeTexture(descriptor: descriptor))
            [gray, gray, gray, 255].withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                    withBytes: $0.baseAddress!, bytesPerRow: 4)
            }
            return texture
        }
        func frame(at time: Double, landscape: Bool = false, light: Bool = false) throws -> UInt8 {
            let size = landscape ? CGSize(width: 128, height: 72) : CGSize(width: 72, height: 128)
            let frame = try #require(gpu.render(size: size, elapsed: time, motionTime: 0,
                pulsePower: 0, isLandscape: landscape, lightAppearance: light))
            frame.commandBuffer.commit()
            frame.commandBuffer.waitUntilCompleted()
            #expect(frame.commandBuffer.status == .completed)
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes {
                frame.texture.getBytes($0.baseAddress!, bytesPerRow: 4,
                    from: MTLRegionMake2D(Int(size.width / 2), Int(size.height / 2), 1, 1), mipmapLevel: 0)
            }
            #expect(pixel[3] == 255)
            return pixel[0]
        }
        #expect(!gpu.replaceArtwork(try artwork(gray: 0), crossfade: false))
        let dark = try frame(at: 1)
        #expect(abs(Int(dark) - 18) <= 1)
        #expect(gpu.replaceArtwork(try artwork(gray: 255), crossfade: true))
        #expect(try frame(at: 2) == dark)
        let middle = try frame(at: 2.25)
        #expect(gpu.isTransitioning)
        let final = try frame(at: 2.5)
        #expect(!gpu.isTransitioning)
        #expect(abs(Int(middle) - 77) <= 1)
        #expect(abs(Int(final) - 153) <= 1)
        let landscape = try frame(at: 3, landscape: true, light: true)
        #expect(abs(Int(landscape) - 170) <= 1)
    }

    private func pixelStats(_ pixels: [UInt8]) -> String {
        let values = stride(from: 0, to: pixels.count, by: 4).map { Int(pixels[$0]) }
        return "min=\(values.min() ?? 0) max=\(values.max() ?? 0) mean=\(Double(values.reduce(0,+)) / Double(max(1, values.count)))"
    }

    #if os(macOS)
    private func writePreview(pixels: [UInt8], width: Int, height: Int, name: String) {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4, bitsPerPixel: 32
        ) else { return }
        // The Metal target is BGRA; the bitmap rep expects RGBA.
        var rgba = pixels
        for index in stride(from: 0, to: rgba.count, by: 4) {
            rgba.swapAt(index, index + 2)
        }
        rgba.withUnsafeBufferPointer { source in
            if let destination = rep.bitmapData {
                destination.update(from: source.baseAddress!, count: rgba.count)
            }
        }
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(name))
    }
    #endif
}
