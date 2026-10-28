import AppKit
import ClearHubCore
import Observation
import SwiftUI

enum KindFilter: String, CaseIterable, Identifiable {
    case all = "Alle"
    case nodeModules = "node_modules"
    case vendor = "vendor"

    var id: String { rawValue }
}

@MainActor
@Observable
final class AppModel {
    // MARK: Einstellungen (persistiert)

    var roots: [URL] {
        didSet {
            UserDefaults.standard.set(roots.map(\.path), forKey: "roots")
            markSettingsChanged()
        }
    }
    var includeNodeModules: Bool {
        didSet {
            UserDefaults.standard.set(includeNodeModules, forKey: "includeNodeModules")
            markSettingsChanged()
        }
    }
    var includeVendor: Bool {
        didSet {
            UserDefaults.standard.set(includeVendor, forKey: "includeVendor")
            markSettingsChanged()
        }
    }
    var deleteMode: DeleteMode {
        didSet { UserDefaults.standard.set(deleteMode.rawValue, forKey: "deleteMode") }
    }

    // MARK: Zustand

    var results: [FoundFolder] = []
    var checked: Set<URL> = []
    var filter: KindFilter = .all
    var searchText = ""
    var sortOrder = [KeyPathComparator(\FoundFolder.sizeSort, order: .reverse)]

    var isScanning = false
    var hasScanned = false
    /// Suchorte oder Typen wurden seit dem letzten Scan geändert – Ergebnisse sind veraltet.
    var settingsChanged = false
    var scannedCount = 0
    var currentPath = ""
    var pendingSizes = 0

    var isDeleting = false
    var statusMessage: String?
    var errorMessage: String?

    private var scanToken: CancelToken?
    private let sizeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init() {
        let defaults = UserDefaults.standard
        let stored = defaults.stringArray(forKey: "roots") ?? []
        roots = stored.isEmpty
            ? [FileManager.default.homeDirectoryForCurrentUser]
            : stored.map { URL(fileURLWithPath: $0, isDirectory: true) }
        includeNodeModules = defaults.object(forKey: "includeNodeModules") as? Bool ?? true
        includeVendor = defaults.object(forKey: "includeVendor") as? Bool ?? true
        deleteMode = DeleteMode(rawValue: defaults.string(forKey: "deleteMode") ?? "") ?? .trash
    }

    // MARK: Abgeleitete Werte

    var visibleResults: [FoundFolder] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return results
            .filter { folder in
                switch filter {
                case .all: true
                case .nodeModules: folder.kind == .nodeModules
                case .vendor: folder.kind == .vendor
                }
            }
            .filter { query.isEmpty || $0.url.path.lowercased().contains(query) }
            .sorted(using: sortOrder)
    }

    var checkedFolders: [FoundFolder] { results.filter { checked.contains($0.id) } }
    var checkedBytes: Int64 { checkedFolders.reduce(0) { $0 + ($1.size ?? 0) } }
    var totalBytes: Int64 { results.reduce(0) { $0 + ($1.size ?? 0) } }
    var canScan: Bool { !roots.isEmpty && (includeNodeModules || includeVendor) && !isDeleting }

    func isChecked(_ id: URL) -> Binding<Bool> {
        Binding(
            get: { self.checked.contains(id) },
            set: { on in
                if on { self.checked.insert(id) } else { self.checked.remove(id) }
            }
        )
    }

    // MARK: Ordner-Auswahl (AppKit)

    func addRoots() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Hinzufügen"
        panel.message = "Ordner auswählen, die nach node_modules/ und vendor/ durchsucht werden sollen."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !roots.contains(url) {
            roots.append(url)
        }
    }

    private func markSettingsChanged() {
        if hasScanned { settingsChanged = true }
    }

    func removeRoot(_ url: URL) {
        roots.removeAll { $0 == url }
    }

    func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: Scan

    func startScan() {
        guard canScan else { return }
        cancelScan()

        results = []
        checked = []
        settingsChanged = false
        statusMessage = nil
        scannedCount = 0
        currentPath = ""
        isScanning = true
        hasScanned = true

        let token = CancelToken()
        scanToken = token
        let roots = roots
        var kinds = Set<FolderKind>()
        if includeNodeModules { kinds.insert(.nodeModules) }
        if includeVendor { kinds.insert(.vendor) }

        DispatchQueue.global(qos: .userInitiated).async { [self, sizeQueue] in
            Scanner.scan(
                roots: roots,
                kinds: kinds,
                token: token,
                onFound: { folder in
                    Task { @MainActor in
                        guard !token.isCancelled else { return }
                        self.results.append(folder)
                        self.pendingSizes += 1
                    }
                    sizeQueue.addOperation {
                        let size = Scanner.size(of: folder.url, token: token)
                        Task { @MainActor in
                            guard !token.isCancelled else { return }
                            self.pendingSizes -= 1
                            if let index = self.results.firstIndex(where: { $0.id == folder.id }) {
                                self.results[index].size = size
                            }
                        }
                    }
                },
                onProgress: { count, path in
                    Task { @MainActor in
                        guard !token.isCancelled else { return }
                        self.scannedCount = count
                        self.currentPath = path
                    }
                }
            )
            Task { @MainActor in
                guard self.scanToken === token else { return }
                self.isScanning = false
            }
        }
    }

    func cancelScan() {
        scanToken?.cancel()
        scanToken = nil
        sizeQueue.cancelAllOperations()
        isScanning = false
        pendingSizes = 0
    }

    // MARK: Löschen

    func deleteChecked() {
        let targets = checkedFolders
        guard !targets.isEmpty, !isScanning else { return }
        let mode = deleteMode
        isDeleting = true
        statusMessage = nil

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Deleter.delete(targets, mode: mode)
            Task { @MainActor in
                let deleted = Set(result.deleted)
                self.results.removeAll { deleted.contains($0.id) }
                self.checked.subtract(deleted)
                self.isDeleting = false

                let bytes = ByteCountFormatter.string(fromByteCount: result.freedBytes, countStyle: .file)
                self.statusMessage = mode == .trash
                    ? "\(result.deleted.count) Ordner in den Papierkorb gelegt (\(bytes)). Papierkorb leeren, um den Platz freizugeben."
                    : "\(result.deleted.count) Ordner gelöscht – \(bytes) frei geworden."

                if !result.failures.isEmpty {
                    self.errorMessage = result.failures
                        .map { "\(($0.url.path as NSString).abbreviatingWithTildeInPath): \($0.message)" }
                        .joined(separator: "\n")
                }
            }
        }
    }
}

extension Int64 {
    var formattedBytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
