import Foundation
import Darwin
import OSLog

/// Env-gated live-memory diagnostics for device automation.
///
/// Normal launches do nothing. `LUMA_TEST_MEMORY_PROBE=1` records the process
/// `phys_footprint` without touching SwiftUI state or adding a timer.
nonisolated enum MemoryFootprintProbe {
    static let isEnabled = ProcessInfo.processInfo.environment["LUMA_TEST_MEMORY_PROBE"] == "1"

    private static let logger = Logger(subsystem: "app.luma.diagnostics", category: "MemoryProbe")

    static func report(_ label: String) {
        guard isEnabled else { return }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    $0,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else {
            logger.error("[MEM] \(label, privacy: .public) task_info failed \(result, privacy: .public)")
            return
        }
        logger.notice(
            "[MEM] \(label, privacy: .public) phys=\(info.phys_footprint, privacy: .public) resident=\(info.resident_size, privacy: .public) virtual=\(info.virtual_size, privacy: .public)"
        )
    }
}
