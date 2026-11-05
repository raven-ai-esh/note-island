import Foundation

/// A re-signed acceptance bundle can use synthetic files without opening the
/// installed user's library. Normal production bundle IDs keep existing paths.
enum NoteIslandPaths {
    static var isAcceptance: Bool {
        Bundle.main.bundleIdentifier?.hasSuffix(".acceptance") == true
    }

    static func resolveDirectory(bundleID: String?, acceptancePath: String?, applicationSupport: URL) throws -> URL {
        if bundleID?.hasSuffix(".acceptance") == true {
            guard let acceptancePath, acceptancePath.hasPrefix("/"), acceptancePath != "/" else {
                throw NSError(domain: "NoteIslandAcceptance", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Acceptance bundle requires an absolute synthetic data directory"])
            }
            return URL(fileURLWithPath: acceptancePath, isDirectory: true)
        }
        return applicationSupport.appendingPathComponent("NoteIsland", isDirectory: true)
    }

    static var directory: URL {
        // Deliberately fail closed for a misconfigured acceptance bundle rather
        // than falling back to a person's actual notes or screenshots.
        try! resolveDirectory(
            bundleID: Bundle.main.bundleIdentifier,
            acceptancePath: Bundle.main.object(forInfoDictionaryKey: "NoteIslandAcceptanceDirectory") as? String,
            applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        )
    }
}
