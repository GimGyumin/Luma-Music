import Foundation
import OSLog
import Darwin

/// Process CPU/RSS samples are contextual (other app work may overlap), not energy estimates.
/// Signposts allow Time Profiler/Allocations to attribute each stage on the target device.
nonisolated struct SpotlightWorkMeasurement {
    private static let log = OSLog(subsystem: "com.luma", category: "Indexing")
    private let id: OSSignpostID
    private let start = ContinuousClock.now
    private let cpu: Double
    private let stage: String
    init(_ stage: String) {
        self.stage = stage
        id = OSSignpostID(log: Self.log)
        cpu = Self.usage().cpu
        os_signpost(.begin, log: Self.log, name: "Index work", signpostID: id, "%{public}@", stage as NSString)
    }
    func end(count: Int = 0) {
        let usage = Self.usage()
        os_signpost(.end, log: Self.log, name: "Index work", signpostID: id, "%{public}@ count=%d", stage as NSString, count)
        Logger.siri.info("[INDEX-METRIC] stage=\(stage, privacy: .public) count=\(count, privacy: .public) wall_ms=\(RuntimeDiagnostics.milliseconds(start.duration(to: .now)), privacy: .public) process_cpu_ms=\((usage.cpu - cpu) * 1000, privacy: .public) process_peak_rss_bytes=\(usage.rss, privacy: .public)")
    }
    private static func usage() -> (cpu: Double, rss: Int) {
        var value = rusage()
        guard getrusage(RUSAGE_SELF, &value) == 0 else { return (0, 0) }
        return (Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
            + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000, Int(value.ru_maxrss))
    }
}
