import Foundation

/// Locates test fixtures in the test bundle, with a macOS source-tree fallback.
/// On a device, `#filePath` points at the Mac checkout and is not accessible
/// inside the test runner sandbox, so bundled resources are the primary path.
final class LumaTestBundleToken: NSObject {}

enum LumaTestResources {
    static var bundle: Bundle { Bundle(for: LumaTestBundleToken.self) }

    static func fixture(_ relativePath: String, sourceFile: String = #filePath) -> URL {
        let path = relativePath as NSString
        let name = path.lastPathComponent
        let directory = path.deletingLastPathComponent
        if let url = bundle.url(
            forResource: name,
            withExtension: nil,
            subdirectory: directory.isEmpty ? nil : directory
        ) {
            return url
        }
        if let url = bundle.url(forResource: name, withExtension: nil) {
            return url
        }
        return URL(fileURLWithPath: sourceFile)
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    /// A writable location inside the test runner's sandbox.
    static func temporaryFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }
}
