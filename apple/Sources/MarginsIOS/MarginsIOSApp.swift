// iOS app entry point. Phase 1 placeholder: proves the shared package
// graph builds and links on both platforms, and that the FFI xcframework
// resolves at link/run time; the real SwiftUI app and its scenes arrive in
// Phase 4 (docs/ios-plan.md).
import Foundation
import MarginsCore

@main
struct MarginsIOSApp {
    static func main() {
        do {
            let dataDir = NSTemporaryDirectory() + "margins-ios-placeholder"
            let core = try MarginsCore(dataDir: dataDir)
            print("Margins iOS — placeholder (docs/ios-plan.md Phase 4)")
            print("library root: \(try core.libraryRoot())")
        } catch {
            print("Margins iOS — FFI smoke test failed: \(error)")
            exit(1)
        }
    }
}
