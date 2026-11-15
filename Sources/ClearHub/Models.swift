import Foundation

/// Kind of folder to search for.
public enum FolderKind: String, CaseIterable, Identifiable, Sendable, Codable {
    case nodeModules = "node_modules"
    case vendor = "vendor"

    public var id: String { rawValue }
}

/// A found, deletable dependency folder.
public struct FoundFolder: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let kind: FolderKind
    /// Package manager that created the folder (e.g. "npm", "Composer").
    public let ecosystem: String
    public let modified: Date?
    public var size: Int64?

    public init(url: URL, kind: FolderKind, ecosystem: String, modified: Date?, size: Int64? = nil) {
        self.url = url
        self.kind = kind
        self.ecosystem = ecosystem
        self.modified = modified
        self.size = size
    }

    public var projectURL: URL { url.deletingLastPathComponent() }
    public var projectName: String { projectURL.lastPathComponent }
    public var projectPath: String { (projectURL.path as NSString).abbreviatingWithTildeInPath }
    public var displayPath: String { (url.path as NSString).abbreviatingWithTildeInPath }

    // Sort keys for the table (optionals are not Comparable).
    public var sizeSort: Int64 { size ?? -1 }
    public var modifiedSort: Date { modified ?? .distantPast }
    public var kindLabel: String { "\(kind.rawValue) · \(ecosystem)" }
}

/// Thread-safe cancellation flag for background work.
public final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }
    public func cancel() { lock.withLock { cancelled = true } }
}
