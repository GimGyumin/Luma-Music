import Testing
import SwiftUI
import Darwin
import Metal
@testable import Luma

/// Reproducible software-render workload, not an on-device frame-rate/energy claim.
@Suite("Lyrics renderer benchmark", .serialized)
struct LyricsRendererBenchmarkTests {
    @Test func lowResolutionArtworkGPU() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let gpu = try LyricsArtworkGPU(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb,
            width: 32, height: 32, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        var pixels: [SIMD4<UInt8>] = []
        for index in 0..<1024 {
            let red = UInt8((index % 32) * 8)
            let blue = UInt8((index / 32) * 8)
            pixels.append(SIMD4<UInt8>(red, 75, blue, 255))
        }
        pixels.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, 32, 32), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: 128)
        }
        gpu.replaceArtwork(texture, crossfade: false)
        var samples: [Double] = []
        for index in 0..<36 {
            let frame = try #require(gpu.render(size: CGSize(width: 402, height: 874), elapsed: Float(index) / 15))
            frame.commandBuffer.commit()
            frame.commandBuffer.waitUntilCompleted()
            #expect(frame.commandBuffer.status == .completed)
            if index >= 6, frame.commandBuffer.gpuStartTime > 0 {
                samples.append(frame.commandBuffer.gpuEndTime - frame.commandBuffer.gpuStartTime)
            }
        }
        guard !samples.isEmpty else { return } // GPU timestamps are optional on some drivers.
        let sorted = samples.sorted()
        let result: [String: Any] = ["gpu": device.name, "samples": samples.count,
            "mean_ms": samples.reduce(0, +) / Double(samples.count) * 1000,
            "p95_ms": sorted[Int(Double(sorted.count - 1) * 0.95)] * 1000,
            "max_ms": sorted.last! * 1000, "render_longest_edge": 384,
            "scope": "offscreen GPU commands, excludes display presentation; not iPhone energy or utilization"]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("luma-lyrics-gpu-benchmark.json"), options: .atomic)
        print("LYRICS-GPU-BENCHMARK \(String(decoding: data, as: UTF8.self))")
    }
    @Test @MainActor func shapedTimedParagraph() throws {
        let words = ["우리의 ", "memories ", "光の ", "melody"].enumerated().map {
            LyricDisplayWord(text: $0.element, startMs: $0.offset * 1200,
                endMs: ($0.offset + 1) * 1200, role: .main, preservesSourceSpacing: true)
        }
        func frame(_ time: Int) throws {
            try autoreleasepool {
                let renderer = ImageRenderer(content: LyricWordKaraokeLine(words: words, adjustedMs: time,
                    fontSize: 36).frame(width: 338).padding(16).background(.black))
                renderer.scale = 2
                let image = try #require(renderer.cgImage)
                #expect(image.width == 740 && image.height > 0)
            }
        }
        for index in 0..<6 { try frame(index * 100) }
        let start = ProcessInfo.processInfo.systemUptime
        let cpuStart = clock()
        for index in 0..<120 { try frame(index * 40) }
        let cpu = Double(clock() - cpuStart) / Double(CLOCKS_PER_SEC)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let result: [String: Any] = ["frames": 120, "wall_seconds": elapsed, "cpu_seconds": cpu,
            "workload": "ImageRenderer: native shaping, view creation and software draw; 338pt, 2x, mixed CJK/Latin, four timed words"]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("luma-lyrics-render-benchmark.json"), options: .atomic)
        print("LYRICS-RENDER-BENCHMARK wall=\(elapsed) cpu=\(cpu) frames=120")
    }
}
