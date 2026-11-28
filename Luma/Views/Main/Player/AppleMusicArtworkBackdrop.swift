// Luma — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The phone player's artwork-derived backdrop.
///
/// Apple Music does not paint a flat tint or the raw, full-resolution sleeve. It
/// spreads a heavily blurred, border-weighted version of the artwork across the
/// viewport, then lays a directional shade over the lower half. This type keeps the
/// same shape without a runtime Gaussian pass: a tiny border-weighted colour grid is
/// sampled off the main thread once per artwork and rendered as a smooth 3 × 5 mesh.
nonisolated struct AppleMusicArtworkBackdrop: Equatable, Sendable {
    /// Row-major 3 × 5 packed 0xRRGGBB colours.
    let grid: [Int]
    /// The artwork's representative border colour after exposure mapping.
    let base: Int

    func color(at index: Int) -> Color {
        let packed = grid.indices.contains(index) ? grid[index] : base
        return Self.color(packed)
    }

    var colors: [Color] { (0..<15).map(color(at:)) }

    static func color(_ packed: Int) -> Color {
        Color(.sRGB,
              red: Double((packed >> 16) & 255) / 255,
              green: Double((packed >> 8) & 255) / 255,
              blue: Double(packed & 255) / 255)
    }

    static func packed(_ red: Double, _ green: Double, _ blue: Double) -> Int {
        func channel(_ value: Double) -> Int {
            Int((min(max(value, 0), 1) * 255).rounded())
        }
        return channel(red) << 16 | channel(green) << 8 | channel(blue)
    }

    /// Immediate stand-in used until the artwork grid finishes analysing. It is
    /// built from the prepared palette (when available), so opening the player
    /// never flashes black before the sleeve loads.
    static func solid(from color: Color) -> AppleMusicArtworkBackdrop {
        let rgb = ArtworkColorMath.srgb(color).map { BackdropRGB($0.0, $0.1, $0.2) }
            ?? BackdropRGB(0.32, 0.32, 0.32)
        let exposed = AppleMusicBackdropAnalyzer.exposedBase(rgb)
        let packed = packed(exposed.r, exposed.g, exposed.b)
        return AppleMusicArtworkBackdrop(grid: Array(repeating: packed, count: 15), base: packed)
    }
}

/// How strongly the lower half is shaded. The album surface keeps a touch more
/// light around the middle; lyrics sit a little deeper so the active line reads.
nonisolated enum AppleMusicBackdropRole: Sendable {
    case player
    case lyrics

    /// Black overlay opacity at 0%, 42%, 50%, 58%, 70%, 76%, 88%, 100%.
    var shadeStops: [Double] {
        switch self {
        case .player: return [0.035, 0.015, 0.02, 0.05, 0.14, 0.22, 0.31, 0.38]
        case .lyrics: return [0.02, 0.0, 0.0, 0.03, 0.12, 0.20, 0.30, 0.38]
        }
    }

    var shadeLocations: [CGFloat] {
        [0, 0.42, 0.50, 0.58, 0.70, 0.76, 0.88, 1]
    }
}

struct AppleMusicArtworkBackdropView: View {
    let coverArtID: String
    let image: PlatformImage?
    let palette: ArtworkPalette?
    let fallbackColor: Color
    var role: AppleMusicBackdropRole = .player
    /// Reports the backdrop's lower-centre colour so the player controls use the
    /// same artwork field instead of a separate, sometimes neutral, atmosphere.
    var onPaletteReady: ((Color) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var analysed: AppleMusicArtworkBackdrop?

    private var cacheKey: String {
        let imageKey = image.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue)) } ?? "none"
        let edge = palette?.edgeAnalysis?.fingerprint ?? 0
        return "\(coverArtID)|\(imageKey)|\(palette?.packedBackground ?? 0)|\(edge)"
    }

    /// The prepared palette is a much better opening tint than the Now Playing
    /// wash, which is intentionally dark for white chrome. Prefer the sleeve's
    /// lower edge: it usually carries the body colour (warm cloak, ground, stage)
    /// instead of the sky or a bright corner that a border median would pick.
    private var seedColor: Color {
        guard let palette else { return fallbackColor }
        if let bottom = palette.edgeAnalysis?.bottomBackground, bottom != .clear {
            return bottom
        }
        return palette.background
    }

    private var visible: AppleMusicArtworkBackdrop {
        analysed
            ?? ArtworkBackdropCache.shared.backdrop(for: cacheKey)
            ?? .solid(from: seedColor)
    }

    var body: some View {
        ZStack {
            seedColor
            mesh(visible)
                .overlay { shade }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: cacheKey) {
            // Do not keep the previous album's mesh while the new sleeve loads.
            // The palette seed is already the new artwork's colour, so the view
            // can hand over immediately and then settle onto the sampled grid.
            analysed = nil
            onPaletteReady?(seedColor)
            if let cached = ArtworkBackdropCache.shared.backdrop(for: cacheKey) {
                analysed = cached
                report(cached)
                return
            }
            guard let image else { return }
            let palette = palette
            let result = await Task.detached(priority: .utility) {
                AppleMusicBackdropAnalyzer.make(image: image, palette: palette)
            }.value
            guard !Task.isCancelled else { return }
            ArtworkBackdropCache.shared.store(result, for: cacheKey)
            report(result)
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.42)) {
                analysed = result
            }
        }
    }

    private func report(_ backdrop: AppleMusicArtworkBackdrop) {
        // Row 4 centre is the artwork field behind the scrubber and footer.
        onPaletteReady?(backdrop.color(at: 12))
    }

    private func mesh(_ backdrop: AppleMusicArtworkBackdrop) -> some View {
        MeshGradient(width: 3, height: 5, points: Self.points, colors: backdrop.colors)
    }

    private var shade: some View {
        LinearGradient(
            stops: zip(role.shadeStops, role.shadeLocations).map {
                .init(color: .black.opacity($0.0), location: $0.1)
            },
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private static let points: [SIMD2<Float>] = {
        let xs: [Float] = [0, 0.5, 1]
        let ys: [Float] = [0, 0.25, 0.5, 0.75, 1]
        return ys.flatMap { y in xs.map { SIMD2<Float>($0, y) } }
    }()
}

/// Analysis is keyed by the artwork's stable id plus the image/palette identity,
/// so a track change reuses the previous look until the next sleeve is ready.
nonisolated final class ArtworkBackdropCache: @unchecked Sendable {
    static let shared = ArtworkBackdropCache()

    private final class Box {
        let value: AppleMusicArtworkBackdrop
        init(_ value: AppleMusicArtworkBackdrop) { self.value = value }
    }

    private let cache = NSCache<NSString, Box>()

    private init() {
        cache.countLimit = 24
    }

    func backdrop(for key: String) -> AppleMusicArtworkBackdrop? {
        cache.object(forKey: key as NSString)?.value
    }

    func store(_ backdrop: AppleMusicArtworkBackdrop, for key: String) {
        cache.setObject(Box(backdrop), forKey: key as NSString)
    }
}

/// The expensive part is deliberately tiny: the sleeve is drawn once into a 32 × 32
/// buffer and the whole image is summarised in OKLab. A lower/centre spatial bias
/// keeps a bright sky, a corner logo or a single saturated costume from outvoting
/// the body of the artwork. Only the 3 × 5 grid is retained; nothing here touches
/// the main thread.
private nonisolated struct BackdropRGB {
    var r: Double
    var g: Double
    var b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    var luma: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    func scaled(to target: Double) -> BackdropRGB {
        let source = luma
        guard source > 0.0005 else { return self }
        let factor = target / source
        return BackdropRGB(min(1, r * factor), min(1, g * factor), min(1, b * factor))
    }

    func desaturated(_ amount: Double) -> BackdropRGB {
        let l = luma
        return BackdropRGB(
            l + (r - l) * amount,
            l + (g - l) * amount,
            l + (b - l) * amount
        )
    }
}

/// Perceptual colour used for averaging. Averaging sRGB directly mixes
/// complementary colours toward mud; OKLab keeps the dominant hue and chroma.
private nonisolated struct BackdropLab {
    var L: Double
    var a: Double
    var b: Double

    var rgb: BackdropRGB {
        let l_ = L + 0.3963377774 * a + 0.2158037573 * b
        let m_ = L - 0.1055613458 * a - 0.0638541728 * b
        let s_ = L - 0.0894841775 * a - 1.2914855480 * b
        let l = l_ * l_ * l_
        let m = m_ * m_ * m_
        let s = s_ * s_ * s_
        let red = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let green = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let blue = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        return BackdropRGB(
            Self.encoded(red),
            Self.encoded(green),
            Self.encoded(blue)
        )
    }

    static func from(_ color: BackdropRGB) -> BackdropLab {
        let r = linear(color.r)
        let g = linear(color.g)
        let b = linear(color.b)
        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
        let l_ = cbrt(l)
        let m_ = cbrt(m)
        let s_ = cbrt(s)
        return BackdropLab(
            L: 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            a: 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            b: 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
        )
    }

    func mixed(with other: BackdropLab, amount: Double) -> BackdropLab {
        BackdropLab(
            L: L + (other.L - L) * amount,
            a: a + (other.a - a) * amount,
            b: b + (other.b - b) * amount
        )
    }

    private static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private static func encoded(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped <= 0.0031308
            ? 12.92 * clamped
            : 1.055 * pow(clamped, 1 / 2.4) - 0.055
    }
}

nonisolated enum AppleMusicBackdropAnalyzer {
    private static let rasterSize = 32
    private static let regionRows = 5
    private static let regionColumns = 3
    private static let cellCount = regionRows * regionColumns

    static func make(image: PlatformImage, palette: ArtworkPalette?) -> AppleMusicArtworkBackdrop {
        guard let raster = raster(from: image), let analysis = analyze(raster) else {
            return fallback(palette: palette)
        }

        let exposed = exposedBase(analysis.base.rgb)
        let targetLuma = exposed.luma
        var softened: [BackdropLab] = []
        softened.reserveCapacity(cellCount)
        for row in 0..<regionRows {
            // The top row often contains a bright sky or a white margin. Music's
            // backdrop follows the sleeve body, so it is pulled almost entirely
            // toward the global identity colour. Lower rows keep a little more of
            // their own hue for a natural vertical blend.
            let pull = row == 0 ? 0.96 : (row == regionRows - 1 ? 0.82 : 0.75)
            for column in 0..<regionColumns {
                let cell = analysis.grid[row * regionColumns + column]
                softened.append(cell.mixed(with: analysis.base, amount: pull))
            }
        }

        let mean = softened.reduce(0.0) { $0 + $1.rgb.luma } / Double(cellCount)
        guard mean > 0.0005 else { return fallback(palette: palette) }

        let scale = targetLuma / mean
        let grid = softened.map { cell -> Int in
            let rgb = cell.rgb
            let mapped = rgb
                .scaled(to: max(0.025, min(0.78, rgb.luma * scale)))
                .desaturated(0.98)
            return AppleMusicArtworkBackdrop.packed(mapped.r, mapped.g, mapped.b)
        }
        let packedBase = AppleMusicArtworkBackdrop.packed(exposed.r, exposed.g, exposed.b)
        return AppleMusicArtworkBackdrop(grid: grid, base: packedBase)
    }

    /// Bright sleeves are brought down to the same comfortable band as Music's
    /// backdrop; dark sleeves get a small lift away from pure black but keep their
    /// darkness. The curve is derived from the artwork's measured luminance.
    fileprivate static func exposedBase(_ color: BackdropRGB) -> BackdropRGB {
        let source = color.luma
        let target = min(0.505, max(source * 0.68, min(0.13, source * 1.40)))
        return color.scaled(to: target)
    }

    /// Whole-image OKLab average plus a 3 × 5 region breakdown. The average is
    /// weighted toward the lower/central sleeve, where the subject and the large
    /// field usually live, instead of trusting one bright border.
    private static func analyze(_ pixels: [UInt8]) -> (base: BackdropLab, grid: [BackdropLab])? {
        var baseL = 0.0
        var baseA = 0.0
        var baseB = 0.0
        var baseWeight = 0.0
        var regionL = [Double](repeating: 0, count: cellCount)
        var regionA = [Double](repeating: 0, count: cellCount)
        var regionB = [Double](repeating: 0, count: cellCount)
        var regionWeight = [Double](repeating: 0, count: cellCount)

        for y in 0..<rasterSize {
            for x in 0..<rasterSize {
                guard let rgb = colorPixel(pixels, x, y) else { continue }
                let lab = BackdropLab.from(rgb)
                let nx = (Double(x) + 0.5) / Double(rasterSize)
                let ny = (Double(y) + 0.5) / Double(rasterSize)
                let vertical = 0.35 + 0.90 * ny
                let center = 0.72 + 0.28 * (1 - abs(nx - 0.5) * 2)
                let weight = vertical * center
                baseL += lab.L * weight
                baseA += lab.a * weight
                baseB += lab.b * weight
                baseWeight += weight

                let region = (y * regionRows / rasterSize) * regionColumns
                    + (x * regionColumns / rasterSize)
                // A mild centre preference keeps a corner logo or border from
                // defining a whole edge of the backdrop.
                let regionSampleWeight = 0.85 + 0.15 * center
                regionL[region] += lab.L * regionSampleWeight
                regionA[region] += lab.a * regionSampleWeight
                regionB[region] += lab.b * regionSampleWeight
                regionWeight[region] += regionSampleWeight
            }
        }

        guard baseWeight > 0.0005 else { return nil }
        let base = BackdropLab(
            L: baseL / baseWeight,
            a: baseA / baseWeight,
            b: baseB / baseWeight
        )
        let grid = (0..<cellCount).map { index -> BackdropLab in
            guard regionWeight[index] > 0.0005 else { return base }
            return BackdropLab(
                L: regionL[index] / regionWeight[index],
                a: regionA[index] / regionWeight[index],
                b: regionB[index] / regionWeight[index]
            )
        }
        return (base, grid)
    }

    private static func fallback(palette: ArtworkPalette?) -> AppleMusicArtworkBackdrop {
        var colors: [Color] = []
        if let bottom = palette?.edgeAnalysis?.bottomBackground { colors.append(bottom) }
        if let background = palette?.background { colors.append(background) }
        if let edge = palette?.edgeAnalysis?.background { colors.append(edge) }
        let base = colors
            .filter { $0 != .clear }
            .compactMap { ArtworkColorMath.srgb($0) }
            .first
            .map { BackdropRGB($0.0, $0.1, $0.2) }
            ?? BackdropRGB(0.22, 0.22, 0.22)
        let exposed = exposedBase(base)
        let packed = AppleMusicArtworkBackdrop.packed(exposed.r, exposed.g, exposed.b)
        return AppleMusicArtworkBackdrop(grid: Array(repeating: packed, count: cellCount), base: packed)
    }

    private static func raster(from image: PlatformImage) -> [UInt8]? {
        #if canImport(UIKit)
        guard let cgImage = image.cgImage else { return nil }
        #elseif canImport(AppKit)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #endif
        let size = rasterSize
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        return drew ? pixels : nil
    }

    private static func colorPixel(_ pixels: [UInt8], _ x: Int, _ y: Int) -> BackdropRGB? {
        guard x >= 0, y >= 0, x < rasterSize, y < rasterSize else { return nil }
        let index = (y * rasterSize + x) * 4
        guard pixels[index + 3] >= 26 else { return nil }
        return BackdropRGB(
            Double(pixels[index]) / 255,
            Double(pixels[index + 1]) / 255,
            Double(pixels[index + 2]) / 255
        )
    }
}
