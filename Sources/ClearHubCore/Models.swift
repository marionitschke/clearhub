import Foundation

/// Art des Ordners, nach dem gesucht wird.
public enum FolderKind: String, CaseIterable, Identifiable, Sendable, Codable {
    case nodeModules = "node_modules"
    case vendor = "vendor"

    public var id: String { rawValue }
}

/// Ein gefundener, löschbarer Abhängigkeits-Ordner.
public struct FoundFolder: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let kind: FolderKind
    /// Paketmanager, der den Ordner erzeugt hat (z. B. "npm", "Composer").
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

    // Sortier-Schlüssel für die Tabelle (Optionals sind nicht Comparable).
    public var sizeSort: Int64 { size ?? -1 }
    public var modifiedSort: Date { modified ?? .distantPast }
    public var kindLabel: String { "\(kind.rawValue) · \(ecosystem)" }
}

/// Thread-sicheres Abbruch-Flag für Hintergrundarbeit.
public final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }
    public func cancel() { lock.withLock { cancelled = true } }
}
