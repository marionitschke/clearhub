import Foundation

public enum DeleteMode: String, CaseIterable, Identifiable, Sendable {
    case trash
    case permanent

    public var id: String { rawValue }
}

public struct DeleteResult: Sendable {
    public var deleted: [URL] = []
    public var freedBytes: Int64 = 0
    public var failures: [(url: URL, message: String)] = []
}

public enum Deleter {
    /// Löscht die Ordner synchron. Schlägt ein Ordner fehl, wird mit dem nächsten weitergemacht.
    public static func delete(_ folders: [FoundFolder], mode: DeleteMode) -> DeleteResult {
        var result = DeleteResult()
        let fm = FileManager.default
        for folder in folders {
            // Sicherheitsnetz: nur Ordner mit genau diesen Namen werden je angefasst.
            guard folder.url.lastPathComponent == folder.kind.rawValue else {
                result.failures.append((folder.url, "Unerwarteter Ordnername – übersprungen."))
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
                result.failures.append((folder.url, error.localizedDescription))
            }
        }
        return result
    }
}
