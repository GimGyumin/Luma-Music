import Foundation
import SwiftData
import Testing
@testable import Luma

@Suite("Playback downloads release bandwidth without cancelling user saves")
@MainActor
struct SharedDownloadCancellationTests {
    private func service(_ directory: URL) throws -> DownloadService {
        DownloadService(serverService: MockServerService(), modelContainer: try ModelContainer.luma(inMemory: true),
            toastService: ToastService(), journal: BackgroundDownloadJournal(directory: directory.appendingPathComponent("journal")),
            storageDirectory: directory)
    }

    private func waitForConsumers(_ count: Int, service: DownloadService) async throws {
        for _ in 0..<200 {
            if await service.audioDownloadConsumerCount(key: "track") == count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await service.audioDownloadConsumerCount(key: "track") == count)
    }

    @Test func soleAutomaticConsumerCancellationStopsItsTransfer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try service(directory)
        let automatic = Task {
            try await service.performSharedAudioDownload(key: "track") {
                try await Task.sleep(for: .seconds(10))
            }
        }
        try await waitForConsumers(1, service: service)
        automatic.cancel()
        do { _ = try await automatic.value; Issue.record("Cancelled automatic transfer completed") }
        catch { #expect(error is CancellationError) }
        #expect(await service.audioDownloadConsumerCount(key: "track") == 0)
    }

    @Test func userSaveSurvivesCancellationOfAutomaticConsumer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try service(directory)
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let automatic = Task {
            try await service.performSharedAudioDownload(key: "track") {
                for await _ in stream {}
                try Task.checkCancellation()
            }
        }
        try await waitForConsumers(1, service: service)
        let manual = Task {
            try await service.performSharedAudioDownload(key: "track") {
                Issue.record("A shared download issued a second transfer")
            }
        }
        try await waitForConsumers(2, service: service)
        automatic.cancel()
        try await waitForConsumers(1, service: service)
        continuation.finish()
        #expect(try await manual.value)
        do { _ = try await automatic.value; Issue.record("Cancelled consumer reported success") }
        catch { #expect(error is CancellationError) }
        #expect(await service.audioDownloadConsumerCount(key: "track") == 0)
    }
}
