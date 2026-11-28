import Foundation
import Metal

/// Warms one idle Lyricify pipeline during app preparation and transfers it to the
/// first visible player surface. No command buffer or drawable is shared across views.
actor LyricifyRendererPreparation {
    static let shared = LyricifyRendererPreparation()

    private var prepared: LyricifyBackgroundGPU?
    private var worker: Task<LyricifyBackgroundGPU?, Never>?
    private var workerID: UUID?

    func warm() async {
        guard prepared == nil else { return }
        if worker == nil {
            let id = UUID()
            workerID = id
            worker = Task.detached(priority: .utility) {
                guard let device = MTLCreateSystemDefaultDevice() else { return nil }
                return try? LyricifyBackgroundGPU(device: device)
            }
        }
        let id = workerID
        let result = await worker?.value
        guard workerID == id else { return }
        prepared = result
        worker = nil
        workerID = nil
    }

    func renderer(device: any MTLDevice) async -> LyricifyBackgroundGPU? {
        if worker != nil { await warm() }
        if let prepared, prepared.device.registryID == device.registryID {
            self.prepared = nil
            return prepared
        }
        let task = Task.detached(priority: .utility) {
            try? LyricifyBackgroundGPU(device: device)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
