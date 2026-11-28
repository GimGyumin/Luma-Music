#if os(macOS)
import AppKit
import Foundation
import SwiftSonic
import Testing
@testable import Luma

@MainActor
@Suite("macOS docked player controls")
struct MacDockedPlayerControlsTests {
    @Test func shellAndLibraryGridFollowMeasuredRules() {
        #expect(MacDesign.Metrics.sidebarWidth == 200)
        #expect(MacShellMetrics.playerBarReservedHeight == 73)
        #expect(MacDesign.Grid.columnCount(for: 513) == 2)
        #expect(MacDesign.Grid.columnCount(for: 780) == 4)
        #expect(MacDesign.Grid.columnCount(for: 1000) == 4)
        #expect(MacDesign.Grid.columnCount(for: 1240) == 5)
        #expect(MacDesign.Grid.columnCount(for: 1510) == 6)
        for width: CGFloat in [513, 780, 1000, 1240, 1510] {
            #expect(MacDesign.Grid.cardWidth(for: width) <= 228)
            #expect(MacDesign.Grid.cardWidth(for: width) >= 160)
        }
    }

    @Test func referenceSeparatesOuterCapsuleFromContentAndTimeline() {
        #expect(MacDockedPlayerMetrics.outerWidth == 700)
        #expect(MacShellMetrics.playerBarMaxWidth == MacDockedPlayerMetrics.outerWidth)
        #expect(MacDockedPlayerMetrics.height == 54)
        #expect(MacDockedPlayerMetrics.outerWidth - 2 * MacDockedPlayerMetrics.inset == 682)
        #expect(MacDockedPlayerMetrics.metadataWidth(in: 700) == 385)
        #expect(MacDockedPlayerMetrics.transportWidth == CGFloat(28 * 4 + 36))
        #expect(MacDockedPlayerMetrics.actionsWidth == CGFloat(36 * 4 + 3))
    }

    @Test func lyricsPanelCompressionKeepsEveryControlSlot() {
        for width: CGFloat in [980, 1200, 1440, 1710] {
            for panel: CGFloat in [0, MacShellMetrics.lyricsPanelWidth] {
                let capsule = min(MacShellMetrics.playerBarMaxWidth,
                                  width - MacShellMetrics.sidebarWidth - panel - 2 * MacShellMetrics.playerBarHorizontalInset)
                let metadata = MacDockedPlayerMetrics.metadataWidth(in: capsule)
                #expect(metadata >= 139)
                #expect(metadata + 2 * MacDockedPlayerMetrics.inset + 2 * MacDockedPlayerMetrics.groupGap
                        + MacDockedPlayerMetrics.transportWidth + MacDockedPlayerMetrics.actionsWidth == capsule)
            }
        }
    }

    @Test func visualCounterpartsExistAndLoadingCanBePaused() {
        for name in [MacPlayerSymbols.previous, MacPlayerSymbols.next, MacPlayerSymbols.shuffle,
                     MacPlayerSymbols.lyrics, MacPlayerSymbols.queue, "play.fill", "pause.fill", "repeat", "repeat.1",
                     MacPlayerSymbols.volume(0.7, variant: .docked), MacPlayerSymbols.volume(0, variant: .docked)] {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil)
        }
        #expect(MacPlayerSymbols.playback(.loading) == "pause.fill")
        #expect(MacPlayerSymbols.playback(.paused) == "play.fill")
        #expect(MacPlayerSymbols.volume(0.7, variant: .immersive) == "speaker.wave.2.fill")
    }

    @Test func muteRestoresAudibleVolumeWithoutPersistingZero() throws {
        let suite = "Luma.DockedControls.Tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0.42, forKey: "luma.lastVolume")
        let output = MacPlayerVolume(defaults: defaults)
        #expect(output.toggleMute() == 0)
        #expect(defaults.double(forKey: "luma.lastVolume") == 0.42)
        #expect(output.toggleMute() == 0.42)
        #expect(output.set(2) == 1)
        #expect(output.set(-1) == 0)
        #expect(output.toggleMute() == 1)
        #expect(output.set(.nan) == 1)
        #expect(output.set(.infinity) == 1)
        defaults.set(0.55, forKey: "luma.lastVolume")
        output.synchronizeStoredValue()
        #expect(output.value == 0.55)
        output.toggleMute()
        output.synchronizeStoredValue()
        #expect(output.value == 0)
    }

    @Test func allSurfacesRouteThroughExistingServiceCommands() async {
        let service = DockedControlRecordingService()
        let commands = MacPlayerCommands(state: service.state, service: service)
        for waiting in [PlaybackState.playing, .loading, .buffering, .recovering] {
            service.state.playbackState = waiting
            await commands.perform(.playback)
            #expect(service.calls.last == "pause")
        }
        service.state.playbackState = .paused
        await commands.perform(.playback)
        #expect(service.calls.last == "resume")
        await commands.perform(.previous)
        #expect(service.calls.last == "previous")
        await commands.perform(.next)
        #expect(service.calls.last == "next")
        await commands.perform(.shuffle)
        #expect(service.state.isShuffled)
        await commands.perform(.shuffle)
        #expect(!service.state.isShuffled)
        for mode in [RepeatMode.all, .one, .off] {
            await commands.perform(.repeatMode)
            #expect(service.state.repeatMode == mode)
        }
        let count = service.calls.count
        await MacPlayerCommands(state: nil, service: service).perform(.playback)
        #expect(service.calls.count == count)
    }
}

@MainActor
private final class DockedControlRecordingService: PlayerServiceProtocol {
    let state = PlayerState()
    var calls: [String] = []
    func resume() async { calls.append("resume") }
    func pause() async { calls.append("pause") }
    func skipToPrevious() async throws { calls.append("previous") }
    func skipToNext() async throws { calls.append("next") }
    func toggleShuffle() async { state.isShuffled.toggle() }
    func setRepeatMode(_ mode: RepeatMode) async { state.repeatMode = mode }
    func play(tracks: [DisplayableSong], startIndex: Int) async throws {}
    func stop() async {}
    func seek(to position: TimeInterval) async {}
    func appendToQueue(_ tracks: [DisplayableSong]) async {}
    func playNext(_ song: DisplayableSong) async {}
    func playNext(_ songs: [DisplayableSong]) async {}
    func addToQueue(_ song: DisplayableSong) async {}
    func addToQueue(_ songs: [DisplayableSong]) async {}
    func removeFromQueue(at index: Int) async {}
    func clearQueueHistory() async {}
    func clearUpNext() async {}
    func moveInQueue(fromIndex: Int, toIndex: Int) async {}
    func restoreSession() async {}
    func handleNetworkRestored() async {}
    func playRadio(_ station: InternetRadioStation) async throws {}
    func playSmartShuffle() async throws {}
    func setAutoExtendEnabled(_ enabled: Bool) async {}
    func setVolume(_ volume: Float) async {}
    func togglePlayPause() async {}
    func saveCurrentPosition() async {}
    func handleAppBecameActive() async {}
    func handleAppWillResignActive() async {}
    func handleAppDidEnterBackground() async {}
    func replayGainSettingsDidChange() async {}
    func crossfadeSettingsDidChange() async {}
    func gaplessSettingsDidChange() async {}
    nonisolated func stopAudioEngineSync() {}
}
#endif
