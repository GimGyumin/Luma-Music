import CoreGraphics
import Foundation
import Metal
import Testing
#if os(macOS)
import AppKit
#endif
@testable import Luma

/// Visual regression harness for the Lyricify render passes. The synthetic artwork
/// deliberately mirrors the dark-concert distribution from the comparison shot:
/// a near-black field, a blue-grey sky, a silver portrait, and a localized red
/// flame bed. The numbers are used to prove that the adjustment works on the
/// render pipeline rather than on one particular screenshot.
@Suite("Lyricify visual stages", .serialized)
struct LyricifyVisualStageTests {
    @MainActor
    @Test("Dump intermediate Lyricify stages for visual comparison")
    func stageDump() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let gpu = try LyricifyBackgroundGPU(device: device, presetSlot: 0)
        let artwork = try makeArtwork(device: device)
        gpu.replaceArtwork(artwork, crossfade: false)
        let size = CGSize(width: 1206, height: 2622)
        let stages: [(String, LyricifyBackgroundGPU.DebugStage?)] = [
            ("artwork", .artwork),
            ("base", .base),
            ("layer0", .layer0),
            ("layer1", .layer1),
            ("layer2", .layer2),
            ("rotationRaw", .rotationRaw),
            ("rotationTreated", .rotation),
            ("blurHorizontalRaw", .blurHorizontalRaw),
            ("blurVerticalRaw", .blurVerticalRaw),
            ("treatedFirst", .treatedFirst),
            ("treatedSecond", .treatedSecond),
            ("treatedScrim", .treatedScrim),
            ("final", nil)
        ]
        var summaries: [[String: Any]] = []
        for (name, stage) in stages {
            let frame = try #require(gpu.render(
                size: size, elapsed: 12.5, pulsePower: 0.2,
                isLandscape: false, lightAppearance: false,
                debugStage: stage))
            frame.commandBuffer.commit()
            frame.commandBuffer.waitUntilCompleted()
            #expect(frame.commandBuffer.status == .completed)
            let width = frame.texture.width
            let height = frame.texture.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes {
                frame.texture.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                    from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            let stats = analyze(name: name, pixels: pixels, width: width, height: height)
            summaries.append(stats.json)
            #if os(macOS)
            writePreview(pixels: pixels, width: width, height: height,
                         name: "luma-lyricify-stage-\(name).png")
            #endif
            print("LYRICIFY-STAGE \(stats.line)")
        }
        // Low Power freezes the ambient clock but keeps the same colour pipeline.
        // Render a frozen phase and check the material's shared output range.
        let frozenFrame = try #require(gpu.render(
            size: size, elapsed: 12.5, motionTime: 0, pulsePower: 0.2,
            isLandscape: false, lightAppearance: false))
        frozenFrame.commandBuffer.commit()
        frozenFrame.commandBuffer.waitUntilCompleted()
        #expect(frozenFrame.commandBuffer.status == .completed)
        var frozenPixels = [UInt8](repeating: 0, count: frozenFrame.texture.width * frozenFrame.texture.height * 4)
        frozenPixels.withUnsafeMutableBytes {
            frozenFrame.texture.getBytes($0.baseAddress!, bytesPerRow: frozenFrame.texture.width * 4,
                from: MTLRegionMake2D(0, 0, frozenFrame.texture.width, frozenFrame.texture.height),
                mipmapLevel: 0)
        }
        let frozenStats = analyze(name: "finalFrozen", pixels: frozenPixels,
            width: frozenFrame.texture.width, height: frozenFrame.texture.height)
        summaries.append(frozenStats.json)
        #if os(macOS)
        writePreview(pixels: frozenPixels, width: frozenFrame.texture.width,
            height: frozenFrame.texture.height, name: "luma-lyricify-stage-finalFrozen.png")
        #endif
        print("LYRICIFY-STAGE \(frozenStats.line)")

        let data = try JSONSerialization.data(withJSONObject: summaries,
            options: [.sortedKeys, .prettyPrinted])
        let json = FileManager.default.temporaryDirectory
            .appendingPathComponent("luma-lyricify-stage-stats.json")
        try data.write(to: json, options: .atomic)
        print("LYRICIFY-STAGE-JSON \(json.path)")
        func summary(_ name: String) throws -> [String: Any] {
            try #require(summaries.first { $0["stage"] as? String == name })
        }
        func value(_ summary: [String: Any], _ key: String) -> Double {
            summary[key] as? Double ?? 0
        }
        let final = try summary("final")
        let frozen = try summary("finalFrozen")
        // Both running and frozen scenes retain the reference black floor and chroma.
        for sample in [final, frozen] {
            #expect(value(sample, "p05") >= 17.0 / 255)
            #expect(value(sample, "dark_ratio") == 0)
            #expect(value(sample, "mean_luma") < 0.35)
            #expect(value(sample, "mean_saturation") > 0.05)
        }
    }

    #if os(macOS)
    @MainActor
    @Test("Production artwork cache uploads the image top at texture row 0")
    func productionArtworkUploadIsUpright() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let side = 16
        // Create a deterministic CGImage instead of an NSImage drawing handler.
        // The drawing handler's flipped-coordinate rasterization made the bottom
        // sample ambiguous; a data-provider image has an explicit top row.
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            let top = y < side / 2
            for x in 0..<side {
                let index = (y * side + x) * 4
                pixels[index] = top ? 240 : 10
                pixels[index + 1] = 20
                pixels[index + 2] = top ? 20 : 240
                pixels[index + 3] = 255
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let cgImage = try #require(CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue:
                CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent))
        let image = NSImage(cgImage: cgImage, size: NSSize(width: side, height: side))
        let prepared = try #require(await LyricifyArtworkTextureCache.shared.artwork(
            image: image, device: device))
        var top = [UInt8](repeating: 0, count: 4)
        var bottom = [UInt8](repeating: 0, count: 4)
        prepared.texture.getBytes(&top, bytesPerRow: 4,
            from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        prepared.texture.getBytes(&bottom, bytesPerRow: 4,
            from: MTLRegionMake2D(0, side - 1, 1, 1), mipmapLevel: 0)
        // The test image has a warm top and cool bottom. A bottom-up CGContext
        // upload would put blue at the texture top; the production cache must
        // preserve red at the top.
        #expect(Int(top[0]) > Int(top[2]) * 2)
        #expect(Int(bottom[2]) > Int(bottom[0]) * 2)
    }
    #endif

    private func analyze(name: String, pixels: [UInt8], width: Int, height: Int)
        -> (json: [String: Any], line: String) {
        var lumas: [Float] = []
        lumas.reserveCapacity(width * height)
        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        var sumSaturation = 0.0, saturationCount = 0
        var redCount = 0, blueCount = 0
        var redSumR = 0.0, blueSumB = 0.0
        var redDominantCount = 0, blueDominantCount = 0
        var darkCount = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let b = Float(pixels[index]) / 255
            let g = Float(pixels[index + 1]) / 255
            let r = Float(pixels[index + 2]) / 255
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            lumas.append(luma)
            sumR += Double(r); sumG += Double(g); sumB += Double(b)
            if luma < 0.05 { darkCount += 1 }
            let maximum = max(r, max(g, b))
            let minimum = min(r, min(g, b))
            if maximum > 0.01 {
                sumSaturation += Double((maximum - minimum) / maximum)
                saturationCount += 1
            }
            if r > 0.12, r > b * 1.2, r > g * 1.15 {
                redCount += 1
                redSumR += Double(r)
            }
            if b > 0.10, b > r * 1.15 {
                blueCount += 1
                blueSumB += Double(b)
            }
            if r > 0.02, r > b * 1.2, r > g * 1.15 { redDominantCount += 1 }
            if b > 0.02, b > r * 1.15 { blueDominantCount += 1 }
        }
        let sorted = lumas.sorted()
        let count = max(1, sorted.count)
        func percentile(_ q: Double) -> Double {
            Double(sorted[min(sorted.count - 1, max(0, Int(q * Double(sorted.count))))])
        }
        let mean = Double(lumas.reduce(0, +)) / Double(count)
        let dark = Double(darkCount) / Double(count)
        let p05 = percentile(0.05)
        let p50 = percentile(0.50)
        let p95 = percentile(0.95)
        let blackSlice = max(1, sorted.count / 20)
        let blackMean = Double(sorted[0..<blackSlice].reduce(0, +)) / Double(blackSlice)
        let saturation = sumSaturation / Double(max(1, saturationCount))
        let redRatio = Double(redCount) / Double(count)
        let blueRatio = Double(blueCount) / Double(count)
        let redMean = redSumR / Double(max(1, redCount))
        let blueMean = blueSumB / Double(max(1, blueCount))
        let json: [String: Any] = [
            "stage": name,
            "width": width,
            "height": height,
            "sample_count": count,
            "mean_luma": mean,
            "p05": p05,
            "p50": p50,
            "p95": p95,
            "black_mean": blackMean,
            "dark_ratio": dark,
            "mean_saturation": saturation,
            "red_ratio": redRatio,
            "red_mean_r": redMean,
            "red_dominant_ratio": Double(redDominantCount) / Double(count),
            "blue_ratio": blueRatio,
            "blue_mean_b": blueMean,
            "blue_dominant_ratio": Double(blueDominantCount) / Double(count),
            "mean_r": sumR / Double(count),
            "mean_g": sumG / Double(count),
            "mean_b": sumB / Double(count)
        ]
        let line = String(format:
            "%@ mean=%.4f p05=%.4f p50=%.4f p95=%.4f dark=%.3f sat=%.3f red=%.3f/%.3f blue=%.3f/%.3f rgb=%.3f,%.3f,%.3f",
            name, mean, p05, p50, p95, dark, saturation, redRatio, redMean,
            blueRatio, blueMean, sumR / Double(count), sumG / Double(count), sumB / Double(count))
        return (json, line)
    }

    #if os(macOS)
    private func writePreview(pixels: [UInt8], width: Int, height: Int, name: String) {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4, bitsPerPixel: 32
        ) else { return }
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
        try? data.write(to: FileManager.default.temporaryDirectory
            .appendingPathComponent(name))
    }
    #endif

    private func makeArtwork(device: any MTLDevice) throws -> any MTLTexture {
        let size = 512
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        func smoothstep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
            let x = min(1, max(0, (value - edge0) / (edge1 - edge0)))
            return x * x * (3 - 2 * x)
        }
        func hash(_ x: Float, _ y: Float) -> Float {
            let value = sin(x * 12.9898 + y * 78.233) * 43_758.5453
            return value - floor(value)
        }
        for y in 0..<size {
            let v = Float(y) / Float(size - 1)
            for x in 0..<size {
                let u = Float(x) / Float(size - 1)
                var r: Float = 0.008, g: Float = 0.009, b: Float = 0.018
                let top = max(0, 1 - v / 0.6)
                r += 0.016 * top; g += 0.030 * top; b += 0.090 * top
                let sky = max(0, 1 - hypot((u - 0.78) / 0.46, (v - 0.08) / 0.40))
                r += 0.030 * sky * sky; g += 0.090 * sky * sky; b += 0.22 * sky * sky
                let red = max(0, (v - 0.5) / 0.5)
                let glow = exp(-pow((u - 0.5) / 0.44, 2)) * red * red
                r += 0.55 * glow; g += 0.10 * glow; b += 0.030 * glow
                let flame = max(0, v - 0.66) * max(0, 1 - abs(u - 0.5) / 0.48)
                let streak = 0.55 + 0.45 * sin(u * 77 + v * 11 + hash(u, v))
                r += 0.22 * flame * streak
                g += 0.05 * flame * streak
                b += 0.012 * flame * streak
                let figure = max(0, 1 - abs(u - 0.5) / 0.105)
                    * smoothstep(0.08, 0.20, v) * (1 - smoothstep(0.88, 0.98, v))
                let helmet = max(0, 1 - hypot((u - 0.5) / 0.10, (v - 0.20) / 0.08))
                let metal = min(1, figure * 0.6 + helmet * 0.4)
                let sheen = 0.55 + 0.45 * sin(u * 95 + v * 17)
                r += 0.45 * metal * sheen
                g += 0.46 * metal * sheen
                b += 0.52 * metal * sheen
                let seam = max(0, 1 - abs(u - 0.5) / 0.012) * metal
                r -= 0.10 * seam; g -= 0.10 * seam; b -= 0.10 * seam
                let index = (y * size + x) * 4
                bytes[index] = UInt8(min(255, max(0, r * 255)))
                bytes[index + 1] = UInt8(min(255, max(0, g * 255)))
                bytes[index + 2] = UInt8(min(255, max(0, b * 255)))
                bytes[index + 3] = 255
            }
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        bytes.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: size * 4)
        }
        return texture
    }
}
