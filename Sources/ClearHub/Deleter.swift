import Foundation

public enum DeleteMode: String, CaseIterable, Identifiable, Sendable {
    case trash
    case permanent

    public var id: String { rawValue }
}

public struct DeleteResult: Sendable {
    public var deleted: [URL] = []
    public var deletedImages: [String] = []
    public var deletedVolumes: [String] = []
    public var freedBytes: Int64 = 0
    public var failures: [(name: String, message: String)] = []

    public init() {}

    public mutating func merge(_ other: DeleteResult) {
        deleted += other.deleted
        deletedImages += other.deletedImages
        deletedVolumes += other.deletedVolumes
        freedBytes += other.freedBytes
        failures += other.failures
    }
}

public enum Deleter {
    /// Deletes the folders synchronously. If one fails, it continues with the next.
    public static func delete(_ folders: [FoundFolder], mode: DeleteMode) -> DeleteResult {
        var result = DeleteResult()
        let fm = FileManager.default
        for folder in folders {
            // Safety net: only folders with exactly these names are ever touched.
            guard folder.url.lastPathComponent == folder.kind.rawValue else {
                result.failures.append((folder.displayPath, "Unerwarteter Ordnername – übersprungen."))
                continue
            }
            // It may have been replaced since the scan, e.g. by a link. lstat, not the URL: its cached
            // resource values are those of the scan.
            guard (try? fm.attributesOfItem(atPath: folder.url.path))?[.type] as? FileAttributeType == .typeDirectory else {
                result.failures.append((folder.displayPath, "Kein Ordner mehr (fehlt oder ist ein Link) – übersprungen."))
                continue
            }
            do {
                switch mode {
                case .trash: try fm.trashItem(at: folder.url, resultingItemURL: nil)
                case .permanent: try fm.removeItem(at: folder.url)
                }
                result.deleted.append(folder.url)
                result.freedBytes += folder.size ?? 0
            } catch {
                result.failures.append((folder.displayPath, error.localizedDescription))
            }
        }
        return result
    }
}
