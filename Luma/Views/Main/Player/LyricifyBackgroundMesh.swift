// Lyricify Backgrounds — Apple Music Inspired · iOS, modern iOS background.
// Ported from https://github.com/WXRIW/Lyricify-Backgrounds
// Reference commit: cbef8a667c02a01707c78c7e76dc67d65cf161ed
// Source: Lyricify.Backgrounds.AppleMusicInspired.Ios.Shared/Rendering/AppleMusicIosMesh.cs
// Copyright the Lyricify Backgrounds contributors. Licensed under Apache License 2.0.
// Swift/Metal port © 2026 Luma contributors. Changes: platform-only adaptation.
// See Luma/Resources/Licenses/Lyricify-Apache-2.0.txt and THIRD_PARTY_NOTICES.md.

import Foundation

nonisolated struct LyricifyPinchVertex: Sendable {
    let from: SIMD2<Float>
    let to: SIMD2<Float>
    let uv: SIMD2<Float>
}

/// Exact portrait/landscape mesh presets and Catmull-Clark subdivision from Lyricify.
nonisolated enum LyricifyBackgroundMesh {
    static let presetSlotCount = 5
    static let minimumControlPointCount = 2
    static let maximumControlPointCount = 16
    static let maximumSubdivisionLevels = 4
    static let defaultPortraitControlPointCount = 6
    static let defaultPortraitSubdivisionLevels = 2
    static let defaultLandscapeControlPointCount = 9
    static let defaultLandscapeSubdivisionLevels = 2

    struct Mesh: Sendable {
        let vertices: [LyricifyPinchVertex]
        let indices: [UInt16]
        let presetSlot: Int
    }

    static func resolvePortraitPreset(_ slot: Int) -> Int {
        switch min(max(0, slot), presetSlotCount - 1) {
        case 0: return 0
        case 1: return 1
        case 2, 3: return 2
        default: return 3
        }
    }

    static func make(
        presetSlot: Int? = nil,
        isVerticalLayout: Bool = true,
        controlPointCount: Int? = nil,
        subdivisionLevels: Int? = nil
    ) -> Mesh {
        let slot = min(max(0, presetSlot ?? Int.random(in: 0..<presetSlotCount)), presetSlotCount - 1)
        let presetIndex = isVerticalLayout ? resolvePortraitPreset(slot) : slot
        let sourceControlPointCount = isVerticalLayout
            ? defaultPortraitControlPointCount : defaultLandscapeControlPointCount
        let defaultSubdivisionLevels = isVerticalLayout
            ? defaultPortraitSubdivisionLevels : defaultLandscapeSubdivisionLevels
        let effectiveControlPointCount = min(max(
            controlPointCount.map { $0 < 0 ? sourceControlPointCount : $0 } ?? sourceControlPointCount,
            minimumControlPointCount), maximumControlPointCount)
        let effectiveSubdivisionLevels = min(max(
            subdivisionLevels.map { $0 < 0 ? defaultSubdivisionLevels : $0 } ?? defaultSubdivisionLevels,
            0), maximumSubdivisionLevels)

        let preset = isVerticalLayout ? portraitPresets[presetIndex] : landscapePresets[presetIndex]
        var from = grid(preset.from, count: sourceControlPointCount)
        var to = grid(preset.to, count: sourceControlPointCount)
        if effectiveControlPointCount != sourceControlPointCount {
            from = resample(from, count: effectiveControlPointCount)
            to = resample(to, count: effectiveControlPointCount)
        }
        for _ in 0..<effectiveSubdivisionLevels {
            from = subdivide(from)
            to = subdivide(to)
        }
        let rows = from.count
        let columns = from[0].count
        var vertices: [LyricifyPinchVertex] = []
        vertices.reserveCapacity(rows * columns)
        for row in 0..<rows {
            let v = 1 - Float(row) / Float(rows - 1)
            for column in 0..<columns {
                let u = Float(column) / Float(columns - 1)
                vertices.append(LyricifyPinchVertex(
                    from: from[row][column] * 2 - SIMD2<Float>(repeating: 1),
                    to: to[row][column] * 2 - SIMD2<Float>(repeating: 1),
                    uv: SIMD2<Float>(u, v)))
            }
        }
        var indices: [UInt16] = []
        indices.reserveCapacity((rows - 1) * (columns - 1) * 6)
        for row in 0..<(rows - 1) {
            for column in 0..<(columns - 1) {
                let bottomLeft = UInt16(row * columns + column)
                let bottomRight = bottomLeft + 1
                let topLeft = bottomLeft + UInt16(columns)
                let topRight = topLeft + 1
                indices += [bottomLeft, topLeft, topRight, topRight, bottomRight, bottomLeft]
            }
        }
        return Mesh(vertices: vertices, indices: indices, presetSlot: slot)
    }

    private static func grid(_ points: [SIMD2<Float>], count: Int) -> [[SIMD2<Float>]] {
        (0..<count).map { row in
            (0..<count).map { column in points[row * count + column] }
        }
    }

    private static func resample(_ source: [[SIMD2<Float>]], count: Int) -> [[SIMD2<Float>]] {
        let sourceRows = source.count
        let sourceColumns = source[0].count
        let denominator = Float(count - 1)
        return (0..<count).map { row in
            let sourceY = Float(row) * Float(sourceRows - 1) / denominator
            let firstRow = min(Int(sourceY), sourceRows - 1)
            let secondRow = min(firstRow + 1, sourceRows - 1)
            let rowMix = sourceY - Float(firstRow)
            return (0..<count).map { column in
                let sourceX = Float(column) * Float(sourceColumns - 1) / denominator
                let firstColumn = min(Int(sourceX), sourceColumns - 1)
                let secondColumn = min(firstColumn + 1, sourceColumns - 1)
                let columnMix = sourceX - Float(firstColumn)
                let first = mix(source[firstRow][firstColumn], source[firstRow][secondColumn], columnMix)
                let second = mix(source[secondRow][firstColumn], source[secondRow][secondColumn], columnMix)
                return mix(first, second, rowMix)
            }
        }
    }

    private static func mix(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ t: Float) -> SIMD2<Float> {
        a + (b - a) * t
    }

    /// Structured-grid Catmull-Clark step: boundary corners stay sharp, boundary
    /// curves use 1/8-6/8-1/8, interior uses (F + 2R + P) / 4.
    private static func subdivide(_ source: [[SIMD2<Float>]]) -> [[SIMD2<Float>]] {
        let rows = source.count
        let columns = source[0].count
        var facePoints = Array(repeating: Array(repeating: SIMD2<Float>.zero, count: columns - 1), count: rows - 1)
        for row in 0..<(rows - 1) {
            for column in 0..<(columns - 1) {
                facePoints[row][column] = (source[row][column] + source[row][column + 1]
                    + source[row + 1][column] + source[row + 1][column + 1]) / 4
            }
        }
        var result = Array(repeating: Array(repeating: SIMD2<Float>.zero, count: columns * 2 - 1), count: rows * 2 - 1)
        for row in 0..<rows {
            for column in 0..<columns {
                let boundaryRow = row == 0 || row == rows - 1
                let boundaryColumn = column == 0 || column == columns - 1
                let point = source[row][column]
                if boundaryRow && boundaryColumn {
                    result[row * 2][column * 2] = point
                } else if boundaryRow {
                    result[row * 2][column * 2] = (source[row][column - 1] + point * 6 + source[row][column + 1]) / 8
                } else if boundaryColumn {
                    result[row * 2][column * 2] = (source[row - 1][column] + point * 6 + source[row + 1][column]) / 8
                } else {
                    let faceAverage = (facePoints[row - 1][column - 1] + facePoints[row - 1][column]
                        + facePoints[row][column - 1] + facePoints[row][column]) / 4
                    let edgeAverage = ((point + source[row - 1][column]) / 2
                        + (point + source[row + 1][column]) / 2
                        + (point + source[row][column - 1]) / 2
                        + (point + source[row][column + 1]) / 2) / 4
                    result[row * 2][column * 2] = (faceAverage + edgeAverage * 2 + point) / 4
                }
            }
        }
        for row in 0..<rows {
            for column in 0..<(columns - 1) {
                let first = source[row][column]
                let second = source[row][column + 1]
                result[row * 2][column * 2 + 1] = row == 0 || row == rows - 1
                    ? (first + second) / 2
                    : (first + second + facePoints[row - 1][column] + facePoints[row][column]) / 4
            }
        }
        for row in 0..<(rows - 1) {
            for column in 0..<columns {
                let first = source[row][column]
                let second = source[row + 1][column]
                result[row * 2 + 1][column * 2] = column == 0 || column == columns - 1
                    ? (first + second) / 2
                    : (first + second + facePoints[row][column - 1] + facePoints[row][column]) / 4
            }
        }
        for row in 0..<(rows - 1) {
            for column in 0..<(columns - 1) {
                result[row * 2 + 1][column * 2 + 1] = facePoints[row][column]
            }
        }
        return result
    }

    private struct Preset {
        let from: [SIMD2<Float>]
        let to: [SIMD2<Float>]
    }

    private static let identity9 = createIdentityGrid(9)

    private static func createIdentityGrid(_ count: Int) -> [SIMD2<Float>] {
        let denominator = Float(count - 1)
        return (0..<count).flatMap { row in
            (0..<count).map { column in
                SIMD2<Float>(Float(column) / denominator, Float(row) / denominator)
            }
        }
    }

    static let Preset0From: [SIMD2<Float>] = [
        SIMD2<Float>(0, 0),
        SIMD2<Float>(0.2, 0),
        SIMD2<Float>(0.4, 0),
        SIMD2<Float>(0.6, 0),
        SIMD2<Float>(0.8, 0),
        SIMD2<Float>(1, 0),
        SIMD2<Float>(0, 0.2),
        SIMD2<Float>(-0.0933, 0.4),
        SIMD2<Float>(0.4, 0.2),
        SIMD2<Float>(0.6, 0.2),
        SIMD2<Float>(0.3653, 0.1335),
        SIMD2<Float>(1, 0.2),
        SIMD2<Float>(0, 0.4),
        SIMD2<Float>(0.4232, 0.359),
        SIMD2<Float>(0.3429, 0.5349),
        SIMD2<Float>(0.6, 0.4),
        SIMD2<Float>(0.832, 0.4148),
        SIMD2<Float>(1, 0.4),
        SIMD2<Float>(0, 0.6),
        SIMD2<Float>(0.2, 0.6),
        SIMD2<Float>(0.2293, 0.7775),
        SIMD2<Float>(0.7829, 0.5595),
        SIMD2<Float>(0.6514, 0.7302),
        SIMD2<Float>(1, 0.6),
        SIMD2<Float>(0, 0.8),
        SIMD2<Float>(0.2, 0.8),
        SIMD2<Float>(0.28, 0.9195),
        SIMD2<Float>(0.4773, 0.8),
        SIMD2<Float>(0.8, 0.8),
        SIMD2<Float>(1, 0.8),
        SIMD2<Float>(0, 1),
        SIMD2<Float>(0.6514, 1.1073),
        SIMD2<Float>(0.4, 1),
        SIMD2<Float>(1, 1.0317),
        SIMD2<Float>(1, 1.1302),
        SIMD2<Float>(1, 1)
    ]
    static let Preset0To: [SIMD2<Float>] = [
        SIMD2<Float>(0, 0),
        SIMD2<Float>(0.2, 0),
        SIMD2<Float>(0.4, 0),
        SIMD2<Float>(0.6, 0),
        SIMD2<Float>(0.8, 0),
        SIMD2<Float>(1, 0),
        SIMD2<Float>(0, 0.2),
        SIMD2<Float>(-0.0933, 0.4),
        SIMD2<Float>(0.4, 0.2),
        SIMD2<Float>(0.6, 0.2),
        SIMD2<Float>(0.8587, 0.2234),
        SIMD2<Float>(1, 0.2),
        SIMD2<Float>(0, 0.4),
        SIMD2<Float>(0.4526, 0.6053),
        SIMD2<Float>(0.3429, 0.5349),
        SIMD2<Float>(0.6, 0.4),
        SIMD2<Float>(0.832, 0.4148),
        SIMD2<Float>(1, 0.4),
        SIMD2<Float>(0, 0.6),
        SIMD2<Float>(0.2, 0.6),
        SIMD2<Float>(0.2293, 0.7775),
        SIMD2<Float>(0.7829, 0.5595),
        SIMD2<Float>(0.6514, 0.7302),
        SIMD2<Float>(1, 0.6),
        SIMD2<Float>(0, 0.8),
        SIMD2<Float>(0.2, 0.8),
        SIMD2<Float>(0.28, 0.9195),
        SIMD2<Float>(0.4773, 0.8),
        SIMD2<Float>(0.8, 0.8),
        SIMD2<Float>(1, 0.8),
        SIMD2<Float>(0, 1),
        SIMD2<Float>(0.6514, 1.1073),
        SIMD2<Float>(0.4, 1),
        SIMD2<Float>(1, 1.0317),
        SIMD2<Float>(1, 1.1302),
        SIMD2<Float>(1, 1)
    ]
    static let Preset1From: [SIMD2<Float>] = [
        SIMD2<Float>(0, 0),
        SIMD2<Float>(0.2, 0),
        SIMD2<Float>(0.4, 0),
        SIMD2<Float>(0.6, 0),
        SIMD2<Float>(0.8, 0),
        SIMD2<Float>(1, 0),
        SIMD2<Float>(0, 0.2),
        SIMD2<Float>(0.3265, 0.3839),
        SIMD2<Float>(0.4, 0.2),
        SIMD2<Float>(0.462, 0.3424),
        SIMD2<Float>(0.683, 0.2797),
        SIMD2<Float>(1, 0.2),
        SIMD2<Float>(0, 0.4),
        SIMD2<Float>(0.2, 0.4),
        SIMD2<Float>(0.4, 0.4),
        SIMD2<Float>(0.6, 0.4903),
        SIMD2<Float>(0.6574, 0.4903),
        SIMD2<Float>(1.1357, 0.4),
        SIMD2<Float>(-0.1173, 0.4597),
        SIMD2<Float>(0.3771, 0.4384),
        SIMD2<Float>(0.6415, 0.5947),
        SIMD2<Float>(0.8254, 0.6935),
        SIMD2<Float>(0.9334, 0.5862),
        SIMD2<Float>(1, 0.6),
        SIMD2<Float>(-0.0437, 0.6533),
        SIMD2<Float>(0.2, 0.6618),
        SIMD2<Float>(0.683, 0.7362),
        SIMD2<Float>(0.8139, 0.833),
        SIMD2<Float>(0.9104, 0.8085),
        SIMD2<Float>(1, 0.8),
        SIMD2<Float>(0, 1),
        SIMD2<Float>(0.2, 1),
        SIMD2<Float>(0.4, 1),
        SIMD2<Float>(0.6, 1),
        SIMD2<Float>(0.8, 1),
        SIMD2<Float>(1, 1)
    ]
    static let Preset1To: [SIMD2<Float>] = [
        SIMD2<Float>(0, 0),
        SIMD2<Float>(0.2, 0),
        SIMD2<Float>(0.4, 0),
        SIMD2<Float>(0.6, 0),
        SIMD2<Float>(0.8, 0),
        SIMD2<Float>(1, 0),
        SIMD2<Float>(0, 0.2),
        SIMD2<Float>(0.2437, 0.4392),
        SIMD2<Float>(0.4, 0.2),
        SIMD2<Float>(0.462, 0.3424),
        SIMD2<Float>(0.683, 0.2797),
        SIMD2<Float>(1, 0.2),
        SIMD2<Float>(0, 0.4),
        SIMD2<Float>(0.1494, 0.4787),
        SIMD2<Float>(0.4, 0.5063),
        SIMD2<Float>(0.6966, 0.516),
        SIMD2<Float>(0.8139, 0.4478),
        SIMD2<Float>(1.1357, 0.4),
        SIMD2<Float>(-0.1173, 0.4597),
        SIMD2<Float>(0.2437, 0.6085),
        SIMD2<Float>(0.6414, 0.5756),
        SIMD2<Float>(0.8254, 0.6935),
        SIMD2<Float>(0.9334, 0.5862),
        SIMD2<Float>(1, 0.6),
        SIMD2<Float>(-0.0437, 0.6533),
        SIMD2<Float>(0.2, 0.6618),
        SIMD2<Float>(0.683, 0.7362),
        SIMD2<Float>(0.8139, 0.833),
        SIMD2<Float>(0.9104, 0.8085),
        SIMD2<Float>(1, 0.8),
        SIMD2<Float>(0, 1),
        SIMD2<Float>(0.2, 1),
        SIMD2<Float>(0.4, 1),
        SIMD2<Float>(0.6, 1),
        SIMD2<Float>(0.8, 1),
        SIMD2<Float>(1, 1)
    ]
    static let Preset2From: [SIMD2<Float>] = [
        SIMD2<Float>(0, 0),
        SIMD2<Float>(0.2, 0),
        SIMD2<Float>(0.4, 0),
        SIMD2<Float>(0.7465, -0.0935),
        SIMD2<Float>(0.9702, -0.0872),
        SIMD2<Float>(1.5935, -0.0308),
        SIMD2<Float>(-0.1675, 0.2878),
        SIMD2<Float>(0.7185, 0.3087),
        SIMD2<Float>(0.5952, 0.0728),
        SIMD2<Float>(0.7823, 0.0815),
        SIMD2<Float>(0.9318, 0.301),
        SIMD2<Float>(1.1369, 0.3756),
        SIMD2<Float>(0, 0.4),
        SIMD2<Float>(0.3295, 0.4607),
        SIMD2<Float>(0.7823, 0.3087),
        SIMD2<Float>(0.7465, 0.365),
        SIMD2<Float>(0.9514, 0.4305),
        SIMD2<Float>(1.1514, 0.4424),
        SIMD2<Float>(0, 0.6),
        SIMD2<Float>(0.2, 0.6),
        SIMD2<Float>(0.3295, 0.4424),
        SIMD2<Float>(0.5703, 0.5),
        SIMD2<Float>(0.7887, 0.4847),
        SIMD2<Float>(1, 0.6),
        SIMD2<Float>(0, 0.8),
        SIMD2<Float>(0.2414, 0.7926),
        SIMD2<Float>(0.0418, 0.7303),
        SIMD2<Float>(0.5952, 0.4688),
        SIMD2<Float>(0.9433, 0.6929),
        SIMD2<Float>(1, 0.8),
        SIMD2<Float>(0, 1),
        SIMD2<Float>(0.2, 1),
        SIMD2<Float>(0.4, 1),
        SIMD2<Float>(0.6, 1),
        SIMD2<Float>(0.8, 1),
        SIMD2<Float>(1, 1)
    ]
    static let Preset2To: [SIMD2<Float>] = [
        SIMD2<Float>(0, 0),
        SIMD2<Float>(0.2, 0),
        SIMD2<Float>(0.4, 0),
        SIMD2<Float>(0.7465, -0.0935),
        SIMD2<Float>(0.9702, -0.0872),
        SIMD2<Float>(1.5935, -0.0308),
        SIMD2<Float>(-0.1675, 0.2878),
        SIMD2<Float>(0.5414, 0.2825),
        SIMD2<Float>(0.5952, 0.0728),
        SIMD2<Float>(0.7823, 0.0815),
        SIMD2<Float>(0.9318, 0.301),
        SIMD2<Float>(1.1369, 0.3756),
        SIMD2<Float>(0, 0.4),
        SIMD2<Float>(0.2881, 0.4479),
        SIMD2<Float>(0.7823, 0.3087),
        SIMD2<Float>(0.8363, 0.3661),
        SIMD2<Float>(0.9514, 0.4305),
        SIMD2<Float>(1.1514, 0.4424),
        SIMD2<Float>(0, 0.6),
        SIMD2<Float>(0.177, 0.6),
        SIMD2<Float>(0.4, 0.4775),
        SIMD2<Float>(0.5703, 0.5),
        SIMD2<Float>(0.7887, 0.4847),
        SIMD2<Float>(1, 0.6),
        SIMD2<Float>(0, 0.8),
        SIMD2<Float>(0.2414, 0.7926),
        SIMD2<Float>(0.1499, 0.7324),
        SIMD2<Float>(0.5952, 0.5623),
        SIMD2<Float>(0.9433, 0.6929),
        SIMD2<Float>(1, 0.8),
        SIMD2<Float>(0, 1),
        SIMD2<Float>(0.2, 1),
        SIMD2<Float>(0.4, 1),
        SIMD2<Float>(0.6, 1),
        SIMD2<Float>(0.8, 1),
        SIMD2<Float>(1, 1)
    ]
    static let Preset3From: [SIMD2<Float>] = [
        SIMD2<Float>(-0.2351, -0.0967),
        SIMD2<Float>(0.2135, -0.1414),
        SIMD2<Float>(0.9221, -0.0908),
        SIMD2<Float>(0.9221, -0.0685),
        SIMD2<Float>(1.3027, 0.0253),
        SIMD2<Float>(1.2351, 0.1786),
        SIMD2<Float>(-0.3768, 0.1851),
        SIMD2<Float>(0.2, 0.2),
        SIMD2<Float>(0.6615, 0.3146),
        SIMD2<Float>(0.9543, 0),
        SIMD2<Float>(0.6969, 0.1911),
        SIMD2<Float>(1, 0.2),
        SIMD2<Float>(0, 0.4),
        SIMD2<Float>(0.2, 0.4),
        SIMD2<Float>(0.0776, 0.2318),
        SIMD2<Float>(0.6, 0.4),
        SIMD2<Float>(0.6615, 0.3851),
        SIMD2<Float>(1, 0.4),
        SIMD2<Float>(0, 0.6),
        SIMD2<Float>(0.1291, 0.6),
        SIMD2<Float>(0.4, 0.6),
        SIMD2<Float>(0.4, 0.4304),
        SIMD2<Float>(0.4264, 0.5792),
        SIMD2<Float>(1.2029, 0.8188),
        SIMD2<Float>(-0.1192, 1),
        SIMD2<Float>(0.6, 0.8),
        SIMD2<Float>(0.4264, 0.8104),
        SIMD2<Float>(0.6, 0.8),
        SIMD2<Float>(0.8, 0.8),
        SIMD2<Float>(1, 0.8),
        SIMD2<Float>(0, 1),
        SIMD2<Float>(0.0776, 1.0283),
        SIMD2<Float>(0.4, 1),
        SIMD2<Float>(0.6, 1),
        SIMD2<Float>(0.8, 1),
        SIMD2<Float>(1.1868, 1.0283)
    ]
    static let Preset3To: [SIMD2<Float>] = [
        SIMD2<Float>(-0.2351, -0.0967),
        SIMD2<Float>(0.2135, -0.1414),
        SIMD2<Float>(0.9221, -0.0908),
        SIMD2<Float>(0.9221, -0.0685),
        SIMD2<Float>(1.3027, 0.0253),
        SIMD2<Float>(1.2351, 0.1786),
        SIMD2<Float>(-0.3768, 0.1851),
        SIMD2<Float>(0.1839, 0.2),
        SIMD2<Float>(0.7034, 0.2952),
        SIMD2<Float>(0.9543, 0),
        SIMD2<Float>(0.7775, 0.3339),
        SIMD2<Float>(1, 0.2),
        SIMD2<Float>(0, 0.4),
        SIMD2<Float>(0.0357, 0.5369),
        SIMD2<Float>(0.0776, 0.2318),
        SIMD2<Float>(0.6, 0.4),
        SIMD2<Float>(0.6615, 0.3851),
        SIMD2<Float>(1, 0.4),
        SIMD2<Float>(0, 0.6),
        SIMD2<Float>(0.2, 0.6878),
        SIMD2<Float>(0.4, 0.6),
        SIMD2<Float>(0.5, 0.5896),
        SIMD2<Float>(0.6454, 0.6878),
        SIMD2<Float>(1.2029, 0.8188),
        SIMD2<Float>(-0.1192, 1),
        SIMD2<Float>(0.6193, 0.9027),
        SIMD2<Float>(0.4264, 0.8104),
        SIMD2<Float>(0.6, 0.8),
        SIMD2<Float>(0.8, 0.8),
        SIMD2<Float>(1, 0.8),
        SIMD2<Float>(0, 1),
        SIMD2<Float>(0.0776, 1.0283),
        SIMD2<Float>(0.4, 1),
        SIMD2<Float>(0.6, 1),
        SIMD2<Float>(0.8, 1),
        SIMD2<Float>(1.1868, 1.0283)
    ]

    private static let portraitPresets: [Preset] = [
        Preset(from: Preset0From, to: Preset0To),
        Preset(from: Preset1From, to: Preset1To),
        Preset(from: Preset2From, to: Preset2To),
        Preset(from: Preset3From, to: Preset3To),
    ]
    static let LandscapePreset0To: [SIMD2<Float>] = [
        SIMD2<Float>(-0.2292, -0.0529),
        SIMD2<Float>(-0.0402, -0.127),
        SIMD2<Float>(0.1116, -0.3122),
        SIMD2<Float>(0.0923, -0.336),
        SIMD2<Float>(1.1205, -0.164),
        SIMD2<Float>(1.0089, -0.0635),
        SIMD2<Float>(1.1205, -0.0529),
        SIMD2<Float>(1.1116, -0.0899),
        SIMD2<Float>(1.1979, -0.0741),
        SIMD2<Float>(-0.2202, 0.2685),
        SIMD2<Float>(0.0238, 0.1435),
        SIMD2<Float>(0.0997, 0.0933),
        SIMD2<Float>(0.0774, 0.1091),
        SIMD2<Float>(0.75, 0.0933),
        SIMD2<Float>(0.7738, 0.1091),
        SIMD2<Float>(0.7991, 0.1435),
        SIMD2<Float>(1.2798, 0.088),
        SIMD2<Float>(1.1801, 0.1435),
        SIMD2<Float>(-0.1667, 0.3611),
        SIMD2<Float>(0.0432, 0.25),
        SIMD2<Float>(0.1116, 0.25),
        SIMD2<Float>(0.0923, 0.2791),
        SIMD2<Float>(0.5387, 0.2791),
        SIMD2<Float>(0.5908, 0.3161),
        SIMD2<Float>(0.625, 0.3161),
        SIMD2<Float>(0.9896, 0.2791),
        SIMD2<Float>(1.0893, 0.2341),
        SIMD2<Float>(-0.1176, 0.4544),
        SIMD2<Float>(0.0625, 0.3909),
        SIMD2<Float>(0.1503, 0.4418),
        SIMD2<Float>(0.1637, 0.4306),
        SIMD2<Float>(0.4836, 0.3909),
        SIMD2<Float>(0.6161, 0.4544),
        SIMD2<Float>(0.6458, 0.4544),
        SIMD2<Float>(0.7411, 0.3909),
        SIMD2<Float>(1.064, 0.338),
        SIMD2<Float>(-0.0625, 0.5344),
        SIMD2<Float>(0.0997, 0.5159),
        SIMD2<Float>(0.2664, 0.5721),
        SIMD2<Float>(0.2589, 0.5721),
        SIMD2<Float>(0.4836, 0.5344),
        SIMD2<Float>(0.7113, 0.5344),
        SIMD2<Float>(0.7411, 0.5344),
        SIMD2<Float>(0.7991, 0.5159),
        SIMD2<Float>(1.0461, 0.5),
        SIMD2<Float>(-0.0402, 0.6574),
        SIMD2<Float>(0.375, 0.713),
        SIMD2<Float>(0.3929, 0.6574),
        SIMD2<Float>(0.375, 0.625),
        SIMD2<Float>(0.5, 0.6038),
        SIMD2<Float>(0.7991, 0.5721),
        SIMD2<Float>(0.808, 0.625),
        SIMD2<Float>(0.875, 0.625),
        SIMD2<Float>(1.0461, 0.6435),
        SIMD2<Float>(-0.0298, 0.7685),
        SIMD2<Float>(0.3586, 0.9041),
        SIMD2<Float>(0.4063, 0.8003),
        SIMD2<Float>(0.4568, 0.75),
        SIMD2<Float>(0.625, 0.6574),
        SIMD2<Float>(0.8616, 0.67),
        SIMD2<Float>(0.8408, 0.713),
        SIMD2<Float>(0.8943, 0.7288),
        SIMD2<Float>(1.1265, 0.8214),
        SIMD2<Float>(-0.0402, 0.9041),
        SIMD2<Float>(0.2589, 1.0152),
        SIMD2<Float>(0.4747, 0.9676),
        SIMD2<Float>(0.4568, 0.8882),
        SIMD2<Float>(0.7411, 0.8538),
        SIMD2<Float>(0.8616, 0.8538),
        SIMD2<Float>(0.8408, 0.875),
        SIMD2<Float>(0.9211, 0.9438),
        SIMD2<Float>(1.1116, 0.9676),
        SIMD2<Float>(-0.0625, 1.0979),
        SIMD2<Float>(0.0238, 1.2196),
        SIMD2<Float>(0.3304, 1.0688),
        SIMD2<Float>(0.375, 1),
        SIMD2<Float>(0.7887, 1.0556),
        SIMD2<Float>(0.8408, 1.0556),
        SIMD2<Float>(0.875, 1.0688),
        SIMD2<Float>(0.9435, 1.0688),
        SIMD2<Float>(1.0893, 1.2196)
    ]
    static let LandscapePreset1To: [SIMD2<Float>] = [
        SIMD2<Float>(-0.1726, -0.1984),
        SIMD2<Float>(0.0551, -0.2593),
        SIMD2<Float>(0.2158, -0.2593),
        SIMD2<Float>(0.3839, -0.1984),
        SIMD2<Float>(0.5119, -0.1984),
        SIMD2<Float>(0.6473, -0.1243),
        SIMD2<Float>(0.744, -0.2698),
        SIMD2<Float>(1.0179, -0.4259),
        SIMD2<Float>(1.2515, -0.2698),
        SIMD2<Float>(0, 0.0562),
        SIMD2<Float>(0.125, 0.1971),
        SIMD2<Float>(0.2381, 0.2679),
        SIMD2<Float>(0.375, 0.2917),
        SIMD2<Float>(0.5, 0.2202),
        SIMD2<Float>(0.625, 0.125),
        SIMD2<Float>(0.8467, -0.1111),
        SIMD2<Float>(1, -0.1528),
        SIMD2<Float>(1.1042, 0.0146),
        SIMD2<Float>(-0.0193, 0.0357),
        SIMD2<Float>(0.125, 0.1766),
        SIMD2<Float>(0.25, 0.25),
        SIMD2<Float>(0.375, 0.3082),
        SIMD2<Float>(0.5, 0.25),
        SIMD2<Float>(0.625, 0.1766),
        SIMD2<Float>(0.7887, 0.0146),
        SIMD2<Float>(0.9598, -0.0648),
        SIMD2<Float>(1.0551, -0.0172),
        SIMD2<Float>(0, 0.3353),
        SIMD2<Float>(0.125, 0.3896),
        SIMD2<Float>(0.2167, 0.3444),
        SIMD2<Float>(0.375, 0.3231),
        SIMD2<Float>(0.5119, 0.3772),
        SIMD2<Float>(0.625, 0.3353),
        SIMD2<Float>(0.7768, 0.1025),
        SIMD2<Float>(0.9464, 0.0562),
        SIMD2<Float>(1.0685, 0.1647),
        SIMD2<Float>(-0.0521, 0.5192),
        SIMD2<Float>(0.125, 0.4471),
        SIMD2<Float>(0.2229, 0.3824),
        SIMD2<Float>(0.375, 0.3444),
        SIMD2<Float>(0.5119, 0.3933),
        SIMD2<Float>(0.6577, 0.4353),
        SIMD2<Float>(0.75, 0.4677),
        SIMD2<Float>(0.8601, 0.4353),
        SIMD2<Float>(1.1473, 0.2345),
        SIMD2<Float>(-0.0402, 0.6442),
        SIMD2<Float>(0.125, 0.5192),
        SIMD2<Float>(0.2277, 0.4),
        SIMD2<Float>(0.375, 0.3664),
        SIMD2<Float>(0.5119, 0.4074),
        SIMD2<Float>(0.6577, 0.4677),
        SIMD2<Float>(0.75, 0.5),
        SIMD2<Float>(0.8527, 0.4471),
        SIMD2<Float>(1.128, 0.2345),
        SIMD2<Float>(-0.0253, 0.7718),
        SIMD2<Float>(0.1116, 0.5675),
        SIMD2<Float>(0.2339, 0.4353),
        SIMD2<Float>(0.3708, 0.4219),
        SIMD2<Float>(0.5148, 0.4353),
        SIMD2<Float>(0.6726, 0.5),
        SIMD2<Float>(0.7649, 0.578),
        SIMD2<Float>(0.8601, 0.5357),
        SIMD2<Float>(1.1622, 0.3082),
        SIMD2<Float>(-0.0253, 0.9041),
        SIMD2<Float>(0.0982, 0.7718),
        SIMD2<Float>(0.2381, 0.6872),
        SIMD2<Float>(0.375, 0.6442),
        SIMD2<Float>(0.5119, 0.6442),
        SIMD2<Float>(0.6577, 0.6872),
        SIMD2<Float>(0.8229, 0.7348),
        SIMD2<Float>(0.875, 0.875),
        SIMD2<Float>(1.2411, 1.1343),
        SIMD2<Float>(-0.0521, 1.1005),
        SIMD2<Float>(0.0982, 1.0556),
        SIMD2<Float>(0.2277, 1.0556),
        SIMD2<Float>(0.3557, 1.0556),
        SIMD2<Float>(0.5, 1.1587),
        SIMD2<Float>(0.625, 1.1799),
        SIMD2<Float>(0.7649, 1.3677),
        SIMD2<Float>(0.8958, 1.4841),
        SIMD2<Float>(1.0685, 1.3519)
    ]
    static let LandscapePreset2To: [SIMD2<Float>] = [
        SIMD2<Float>(-0.064, -0.1323),
        SIMD2<Float>(0.0893, -0.1614),
        SIMD2<Float>(0.25, -0.0608),
        SIMD2<Float>(0.5729, -0.1614),
        SIMD2<Float>(0.6771, -0.1614),
        SIMD2<Float>(0.7292, -0.1614),
        SIMD2<Float>(0.7634, -0.1217),
        SIMD2<Float>(0.875, -0.0608),
        SIMD2<Float>(1.0164, -0.0423),
        SIMD2<Float>(-0.0714, 0.1091),
        SIMD2<Float>(0.2054, 0.0985),
        SIMD2<Float>(0.2292, 0.1091),
        SIMD2<Float>(0.375, 0.125),
        SIMD2<Float>(0.5357, 0.2077),
        SIMD2<Float>(0.6131, 0.25),
        SIMD2<Float>(0.6458, 0.125),
        SIMD2<Float>(0.75, -0.0284),
        SIMD2<Float>(1.0164, 0.1091),
        SIMD2<Float>(-0.0565, 0.25),
        SIMD2<Float>(0.1696, 0.2077),
        SIMD2<Float>(0.1771, 0.2262),
        SIMD2<Float>(0.2143, 0.2262),
        SIMD2<Float>(0.375, 0.1759),
        SIMD2<Float>(0.625, 0.2937),
        SIMD2<Float>(0.6369, 0.3161),
        SIMD2<Float>(0.6652, 0.2262),
        SIMD2<Float>(1.0104, 0.2262),
        SIMD2<Float>(-0.0565, 0.375),
        SIMD2<Float>(0.0997, 0.375),
        SIMD2<Float>(0.125, 0.375),
        SIMD2<Float>(0.1771, 0.3882),
        SIMD2<Float>(0.3616, 0.2077),
        SIMD2<Float>(0.6131, 0.3406),
        SIMD2<Float>(0.6548, 0.3406),
        SIMD2<Float>(0.7068, 0.375),
        SIMD2<Float>(1.0313, 0.3538),
        SIMD2<Float>(-0.1429, 0.6058),
        SIMD2<Float>(0.1414, 0.5),
        SIMD2<Float>(0.1563, 0.5),
        SIMD2<Float>(0.1949, 0.5),
        SIMD2<Float>(0.5193, 0.2937),
        SIMD2<Float>(0.6964, 0.4517),
        SIMD2<Float>(0.7158, 0.4517),
        SIMD2<Float>(0.7902, 0.4841),
        SIMD2<Float>(1.0461, 0.4841),
        SIMD2<Float>(-0.0714, 0.6753),
        SIMD2<Float>(0.2054, 0.625),
        SIMD2<Float>(0.2054, 0.625),
        SIMD2<Float>(0.2292, 0.625),
        SIMD2<Float>(0.6131, 0.375),
        SIMD2<Float>(0.7158, 0.5298),
        SIMD2<Float>(0.7634, 0.5456),
        SIMD2<Float>(0.8557, 0.625),
        SIMD2<Float>(1.0789, 0.625),
        SIMD2<Float>(-0.0565, 0.8108),
        SIMD2<Float>(0.2143, 0.75),
        SIMD2<Float>(0.2292, 0.75),
        SIMD2<Float>(0.25, 0.7315),
        SIMD2<Float>(0.6652, 0.6865),
        SIMD2<Float>(0.7634, 0.6462),
        SIMD2<Float>(0.8095, 0.7077),
        SIMD2<Float>(0.8914, 0.75),
        SIMD2<Float>(1.0923, 0.75),
        SIMD2<Float>(-0.0565, 0.9306),
        SIMD2<Float>(0.2054, 0.9067),
        SIMD2<Float>(0.2054, 0.9306),
        SIMD2<Float>(0.2292, 0.9411),
        SIMD2<Float>(0.625, 0.875),
        SIMD2<Float>(0.7634, 0.7718),
        SIMD2<Float>(0.8557, 0.8108),
        SIMD2<Float>(0.939, 0.8538),
        SIMD2<Float>(1.0789, 0.9306),
        SIMD2<Float>(0, 1),
        SIMD2<Float>(-0.0714, 1.2169),
        SIMD2<Float>(0.125, 1.4021),
        SIMD2<Float>(0.25, 1.0794),
        SIMD2<Float>(0.625, 1.0794),
        SIMD2<Float>(0.7902, 1.0794),
        SIMD2<Float>(0.875, 1.0794),
        SIMD2<Float>(0.9509, 1.0582),
        SIMD2<Float>(1.0104, 1.0794)
    ]
    static let LandscapePreset3To: [SIMD2<Float>] = [
        SIMD2<Float>(-0.2292, -0.3968),
        SIMD2<Float>(0.0699, -0.3439),
        SIMD2<Float>(0.2217, -0.1799),
        SIMD2<Float>(0.3512, -0.1376),
        SIMD2<Float>(0.6533, -0.2407),
        SIMD2<Float>(0.6845, -0.164),
        SIMD2<Float>(0.7753, -0.3148),
        SIMD2<Float>(0.9494, -0.3677),
        SIMD2<Float>(1.381, -0.5476),
        SIMD2<Float>(-0.1711, 0.0827),
        SIMD2<Float>(-0.0387, -0.1263),
        SIMD2<Float>(0.25, 0.125),
        SIMD2<Float>(0.2887, 0.125),
        SIMD2<Float>(0.5, 0.125),
        SIMD2<Float>(0.5565, 0.125),
        SIMD2<Float>(0.7827, -0.0787),
        SIMD2<Float>(0.9182, -0.1799),
        SIMD2<Float>(1.2039, -0.0628),
        SIMD2<Float>(-0.1057, 0.2209),
        SIMD2<Float>(0.0268, 0.1918),
        SIMD2<Float>(0.25, 0.25),
        SIMD2<Float>(0.2679, 0.2844),
        SIMD2<Float>(0.2887, 0.2685),
        SIMD2<Float>(0.3958, 0.2844),
        SIMD2<Float>(0.6771, 0.125),
        SIMD2<Float>(0.9702, 0.0542),
        SIMD2<Float>(1.2113, 0.1091),
        SIMD2<Float>(-0.1176, 0.2983),
        SIMD2<Float>(0.1101, 0.33),
        SIMD2<Float>(0.25, 0.42),
        SIMD2<Float>(0.317, 0.42),
        SIMD2<Float>(0.3571, 0.42),
        SIMD2<Float>(0.3958, 0.42),
        SIMD2<Float>(0.6369, 0.2983),
        SIMD2<Float>(0.9107, 0.2844),
        SIMD2<Float>(1.2113, 0.33),
        SIMD2<Float>(-0.1533, 0.375),
        SIMD2<Float>(0.1533, 0.375),
        SIMD2<Float>(0.2292, 0.42),
        SIMD2<Float>(0.375, 0.5),
        SIMD2<Float>(0.4301, 0.5377),
        SIMD2<Float>(0.4583, 0.5377),
        SIMD2<Float>(0.6845, 0.4735),
        SIMD2<Float>(0.811, 0.4735),
        SIMD2<Float>(1.1369, 0.463),
        SIMD2<Float>(-0.0938, 0.5728),
        SIMD2<Float>(0.1533, 0.4054),
        SIMD2<Float>(0.3363, 0.5),
        SIMD2<Float>(0.4167, 0.5377),
        SIMD2<Float>(0.5, 0.625),
        SIMD2<Float>(0.5476, 0.6991),
        SIMD2<Float>(0.7887, 0.6118),
        SIMD2<Float>(0.8378, 0.588),
        SIMD2<Float>(1.1563, 0.5608),
        SIMD2<Float>(-0.0789, 0.75),
        SIMD2<Float>(0.25, 0.5608),
        SIMD2<Float>(0.3958, 0.5608),
        SIMD2<Float>(0.4732, 0.625),
        SIMD2<Float>(0.5402, 0.75),
        SIMD2<Float>(0.5967, 0.7976),
        SIMD2<Float>(0.8839, 0.7361),
        SIMD2<Float>(0.8839, 0.7811),
        SIMD2<Float>(1.1563, 0.6389),
        SIMD2<Float>(-0.1057, 0.9226),
        SIMD2<Float>(0.125, 0.875),
        SIMD2<Float>(0.2976, 0.875),
        SIMD2<Float>(0.4464, 0.8882),
        SIMD2<Float>(0.5908, 0.9041),
        SIMD2<Float>(0.625, 0.875),
        SIMD2<Float>(0.9702, 0.9041),
        SIMD2<Float>(1.0268, 1),
        SIMD2<Float>(1.1726, 1.0443),
        SIMD2<Float>(-0.0387, 1.1138),
        SIMD2<Float>(0.0878, 1.1349),
        SIMD2<Float>(0.2292, 1.1138),
        SIMD2<Float>(0.4301, 1.1852),
        SIMD2<Float>(0.625, 1.2804),
        SIMD2<Float>(0.625, 1.3254),
        SIMD2<Float>(1.0372, 1.2328),
        SIMD2<Float>(0.9568, 1.2328),
        SIMD2<Float>(1.0938, 1.2328)
    ]
    static let LandscapePreset4To: [SIMD2<Float>] = [
        SIMD2<Float>(-0.0952, -0.1561),
        SIMD2<Float>(0.0997, -0.1561),
        SIMD2<Float>(0.2396, -0.0847),
        SIMD2<Float>(0.3586, -0.0608),
        SIMD2<Float>(0.4926, -0.0608),
        SIMD2<Float>(0.6086, -0.1561),
        SIMD2<Float>(0.7426, -0.1772),
        SIMD2<Float>(0.8616, -0.1561),
        SIMD2<Float>(1.064, -0.2275),
        SIMD2<Float>(-0.0521, 0.0933),
        SIMD2<Float>(-0.0521, 0.3062),
        SIMD2<Float>(0.2708, 0.375),
        SIMD2<Float>(0.375, 0.3485),
        SIMD2<Float>(0.4926, 0.3062),
        SIMD2<Float>(0.625, 0.2335),
        SIMD2<Float>(0.75, 0.125),
        SIMD2<Float>(0.875, -0.0337),
        SIMD2<Float>(1.064, -0.1772),
        SIMD2<Float>(-0.125, 0.3611),
        SIMD2<Float>(0.0789, 0.5),
        SIMD2<Float>(0.2827, 0.4147),
        SIMD2<Float>(0.3824, 0.375),
        SIMD2<Float>(0.4926, 0.33),
        SIMD2<Float>(0.625, 0.25),
        SIMD2<Float>(0.75, 0.1812),
        SIMD2<Float>(0.8988, 0.0146),
        SIMD2<Float>(1.0804, -0.123),
        SIMD2<Float>(-0.0952, 0.5119),
        SIMD2<Float>(0.1518, 0.5344),
        SIMD2<Float>(0.2827, 0.4683),
        SIMD2<Float>(0.3824, 0.4147),
        SIMD2<Float>(0.4926, 0.375),
        SIMD2<Float>(0.625, 0.2851),
        SIMD2<Float>(0.7589, 0.2163),
        SIMD2<Float>(0.8988, 0.2335),
        SIMD2<Float>(1.119, 0.4147),
        SIMD2<Float>(-0.0521, 0.625),
        SIMD2<Float>(0.2827, 0.5344),
        SIMD2<Float>(0.2961, 0.5985),
        SIMD2<Float>(0.3646, 0.5119),
        SIMD2<Float>(0.4926, 0.3995),
        SIMD2<Float>(0.6324, 0.3062),
        SIMD2<Float>(0.7589, 0.2619),
        SIMD2<Float>(0.9286, 0.3062),
        SIMD2<Float>(1.1071, 0.4683),
        SIMD2<Float>(-0.1399, 0.6938),
        SIMD2<Float>(0.2902, 0.5721),
        SIMD2<Float>(0.2604, 0.6759),
        SIMD2<Float>(0.3586, 0.5344),
        SIMD2<Float>(0.5, 0.4286),
        SIMD2<Float>(0.6414, 0.33),
        SIMD2<Float>(0.8006, 0.3062),
        SIMD2<Float>(0.9673, 0.375),
        SIMD2<Float>(1.119, 0.5985),
        SIMD2<Float>(-0.0521, 0.7897),
        SIMD2<Float>(0.192, 0.8294),
        SIMD2<Float>(0.25, 0.75),
        SIMD2<Float>(0.2708, 0.6759),
        SIMD2<Float>(0.5, 0.5119),
        SIMD2<Float>(0.7738, 0.5589),
        SIMD2<Float>(0.8988, 0.7315),
        SIMD2<Float>(0.9286, 0.713),
        SIMD2<Float>(1.119, 0.75),
        SIMD2<Float>(-0.0685, 0.9438),
        SIMD2<Float>(0.1518, 0.9438),
        SIMD2<Float>(0.1979, 0.875),
        SIMD2<Float>(0.25, 0.957),
        SIMD2<Float>(0.5, 0.7718),
        SIMD2<Float>(0.7738, 0.7315),
        SIMD2<Float>(0.936, 0.9755),
        SIMD2<Float>(1, 1.0205),
        SIMD2<Float>(1.1726, 0.957),
        SIMD2<Float>(-0.0283, 1.0873),
        SIMD2<Float>(0.0997, 1.1561),
        SIMD2<Float>(0.125, 1.1799),
        SIMD2<Float>(0.2604, 1.1243),
        SIMD2<Float>(0.4926, 1.0688),
        SIMD2<Float>(0.8006, 1.0873),
        SIMD2<Float>(0.9167, 1.1376),
        SIMD2<Float>(1.0313, 1.2698),
        SIMD2<Float>(1.1548, 1.3228)
    ]

    private static let landscapePresets: [Preset] = [
        Preset(from: identity9, to: LandscapePreset0To),
        Preset(from: identity9, to: LandscapePreset1To),
        Preset(from: identity9, to: LandscapePreset2To),
        Preset(from: identity9, to: LandscapePreset3To),
        Preset(from: identity9, to: LandscapePreset4To),
    ]
}
