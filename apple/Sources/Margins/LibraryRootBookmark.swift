import Foundation

/// Sandbox support for a user-chosen library root.
///
/// App Store builds run sandboxed, where an `NSOpenPanel` selection is
/// readable only until the app quits. The security-scoped bookmark created
/// when the root is picked is stored in `UserDefaults` and resolved at
/// launch, before the core store reads the library. Non-sandboxed (DMG)
/// builds use the same path, which is harmless.
@MainActor
enum LibraryRootBookmark {
    private static let defaultsKey = "libraryRootBookmark"

    /// Retains the resolved URL so scoped access outlives `restore()`.
    private static var activeURL: URL?

    /// Resolves the saved bookmark (if any) and opens scoped access. Call
    /// before the core store reads the library.
    static func restore() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return }
        var stale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        else { return }

        if stale, let refreshed = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(refreshed, forKey: defaultsKey)
        }

        _ = url.startAccessingSecurityScopedResource()
        activeURL = url
    }

    /// Remembers `url` as the library root and opens scoped access.
    static func remember(_ url: URL) {
        activeURL?.stopAccessingSecurityScopedResource()
        if let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        _ = url.startAccessingSecurityScopedResource()
        activeURL = url
    }
}
