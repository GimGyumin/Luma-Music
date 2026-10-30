import Testing
import SwiftUI
import ImageIO
@testable import Luma

@Suite("Lyrics engine refinements")
struct LyricsEngineRefinementTests {
    @Test func pronunciationColumnsRequireActualMatchingProviderIntervals() {
        let original = [LyricDisplayWord(text: "We", startMs: 0, endMs: 1000, role: .main),
            LyricDisplayWord(text: "sing", startMs: 1000, endMs: 2000, role: .main)]
        let reading = [LyricDisplayWord(text: "위", startMs: 0, endMs: 1000, role: .main),
            LyricDisplayWord(text: "싱", startMs: 1000, endMs: 2000, role: .main)]
        #expect(LyricPronunciationPair.matching(original: original, reading: reading).count == 2)
        #expect(LyricPronunciationPair.matching(original: original, reading: Array(reading.reversed())).isEmpty)
        #expect(LyricPronunciationPair.matching(original: original, reading: []).isEmpty)
    }
    @Test(arguments: ["مرحبا بالعالم الجميل", "שָׁלוֹם, עולם!", "우리 👩🏽‍🎤 e\u{301} 光と音楽", "君の名前を呼んでいる"])
    @MainActor func shapedScriptsKeepNativeParagraphDimensions(text: String) throws {
        let timed = LyricWordKaraokeLine(words: [.init(text: text, startMs: 0, endMs: 1000,
            role: .main, preservesSourceSpacing: true)], adjustedMs: 2000, fontSize: 36, reduceMotion: true)
            .frame(width: 240).padding(16).background(.black)
        let plain = Text(verbatim: text).font(.system(size: 36, weight: .bold)).foregroundStyle(.white)
            .multilineTextAlignment(.leading).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            .frame(width: 240, alignment: .leading).padding(16).background(.black)
        let a = ImageRenderer(content: timed), b = ImageRenderer(content: plain)
        a.scale = 2; b.scale = 2
        let actual = try #require(a.cgImage), native = try #require(b.cgImage)
        #expect(actual.width == native.width && actual.height == native.height)
    }
    @Test func artworkSpeedChangesPreservePhaseAndPauseFreezesIt() {
        var clock = ArtworkSceneClock()
        clock.setRunning(true, now: 0)
        #expect(clock.sample(now: 10) == 10)
        clock.setSpeed(2, now: 10)
        #expect(clock.sample(now: 10) == 10)
        #expect(clock.sample(now: 11) == 12)
        clock.setRunning(false, now: 11)
        clock.setSpeed(0.5, now: 100)
        #expect(clock.sample(now: 200) == 12)
        clock.setRunning(true, now: 200)
        #expect(clock.sample(now: 202) == 13)
    }
    @Test func sustainedNoteKeepsGlowThenReturnsToBaseline() {
        for time in [2000.0, 3500, 4900] {
            #expect(LyricVocalEnvelope.glow(time: time, start: 0, end: 5000, fraction: 0.1) > 0.2)
        }
        #expect(LyricVocalEnvelope.glow(time: -1, start: 0, end: 5000, fraction: 0) == 0)
        let original = AMLLGlyphStyle(lift: 4, shiftX: 2, scale: 1.12, glow: 0.8, glowRadius: 10)
        let halfway = LyricVocalEnvelope.appearance(original, time: 5300, start: 0, end: 5000,
            fraction: 0, fontSize: 36, motion: true)
        let settled = LyricVocalEnvelope.appearance(original, time: 5600, start: 0, end: 5000,
            fraction: 0, fontSize: 36, motion: true)
        #expect(halfway.lift > 0 && halfway.lift < 2)
        #expect(halfway.scale <= 1.035)
        #expect(settled.lift == 0 && settled.scale == 1 && settled.glow == 0)
        #expect(LyricVocalEnvelope.appearance(original, time: 3000, start: 0, end: 5000,
            fraction: 0, fontSize: 36, motion: false) == AMLLGlyphStyle())
    }

    @Test func rapidScrollRetargetPreservesExistingLagAndHasBoundedHistory() {
        var motion = LyricLineCascade()
        let spring = LyricScrollConfiguration.spring(intervalMs: 400, distance: 100)
        motion.retarget(to: 1, travel: 100, spring: spring, now: 10)
        let before = motion.offset(row: 3, elapsed: 0.12)
        motion.retarget(to: 2, travel: 100, spring: spring, now: 10.12)
        #expect(abs(motion.offset(row: 3, elapsed: 0) - before) < 0.0001)
        for index in 3..<80 {
            motion.retarget(to: index, travel: 200, spring: spring, now: 10.12 + Double(index) * 0.02)
            #expect(motion.history.count <= 12)
            #expect(motion.offset(row: index + 1, elapsed: 0.1) <= LyricScrollConfiguration.maximumLag)
        }
        #expect(motion.offset(row: 80, elapsed: 10) == 0)
        let long = LyricScrollConfiguration.spring(intervalMs: 400, distance: 1500)
        #expect(long.stiffness < spring.stiffness)
    }

    @Test func automaticPronunciationPreservesPunctuationAndDoesNotInventWordTiming() throws {
        #expect(LyricPronunciationFallback.text("English only", language: "en") == nil)
        let korean = try #require(LyricPronunciationFallback.text("우리의 노래!", language: "ko"))
        #expect(korean.hasSuffix("!") && !korean.contains("우리"))
        let chinese = try #require(LyricPronunciationFallback.text("你好，世界！", language: "zh"))
        #expect(chinese.contains("，") && chinese.hasSuffix("！"))
        let japanese = try #require(LyricPronunciationFallback.text("君の名前を", language: "ja"))
        #expect(japanese.lowercased().contains("namae"))
        #expect(!japanese.lowercased().contains("ming"))
        #expect(LyricPronunciationFallback.text(String(repeating: "あ", count: 4096), language: "ja") == nil)
    }

    @Test @MainActor func nativeRTLRunHighlightsFromTheRight() throws {
        func pixels(_ time: Int) throws -> (Int, Int, [UInt8]) {
            let view = LyricWordKaraokeLine(words: [.init(text: "אבגדהוזחט", startMs: 0, endMs: 1000,
                role: .main, preservesSourceSpacing: true)], adjustedMs: time, fontSize: 40, reduceMotion: true)
                .frame(width: 338).padding(16).background(.black)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try #require(CGContext(data: &data, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            if time == 500 {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("luma-rtl-sweep.png")
                let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(dest, image, nil)
                #expect(CGImageDestinationFinalize(dest))
            }
            return (image.width, image.height, data)
        }
        let (width, height, dim) = try pixels(-1000)
        let (_, _, half) = try pixels(500)
        let (_, _, full) = try pixels(2000)
        let columns = (0..<width).filter { x in (0..<height).contains { full[($0 * width + x) * 4] > 150 } }
        let middle = (try #require(columns.first) + #require(columns.last)) / 2
        var left = 0, right = 0
        for y in 0..<height {
            for x in 0..<width {
                let delta = max(0, Int(half[(y * width + x) * 4]) - Int(dim[(y * width + x) * 4]))
                if x < middle { left += delta } else { right += delta }
            }
        }
        #expect(right > left * 2, "RTL sung ink must brighten on the right first")
    }
}
