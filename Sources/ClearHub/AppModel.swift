import AppKit
import ClearHubCore
import Observation
import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case folders = "Ordner"
    case docker = "Docker"

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
    var includeDocker: Bool {
        didSet {
            UserDefaults.standard.set(includeDocker, forKey: "includeDocker")
            markSettingsChanged()
        }
    }
    var deleteMode: DeleteMode {
        didSet { UserDefaults.standard.set(deleteMode.rawValue, forKey: "deleteMode") }
    }

    // MARK: Zustand

    var section: Section = .folders
    var searchText = ""

    var results: [FoundFolder] = []
    var checked: Set<URL> = []
    var sortOrder = [KeyPathComparator(\FoundFolder.sizeSort, order: .reverse)]

    var dockerImages: [DockerImage] = []
    var checkedImages: Set<String> = []
    var dockerSortOrder = [KeyPathComparator(\DockerImage.statusSort), KeyPathComparator(\DockerImage.sizeSort, order: .reverse)]
    var isLoadingDocker = false
    var dockerError: String?

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
    /// Compose-/DDEV-Projekte aus dem letzten Scan – für das Neuladen nach dem Löschen.
    private var dockerProjects = DockerProjectIndex()
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
        includeDocker = defaults.object(forKey: "includeDocker") as? Bool ?? (Docker.findCLI() != nil)
        deleteMode = DeleteMode(rawValue: defaults.string(forKey: "deleteMode") ?? "") ?? .trash
    }

    // MARK: Abgeleitete Werte

    private var query: String { searchText.trimmingCharacters(in: .whitespaces).lowercased() }

    var visibleResults: [FoundFolder] {
        let query = query
        return results
            .filter { query.isEmpty || $0.url.path.lowercased().contains(query) }
            .sorted(using: sortOrder)
    }

    var visibleImages: [DockerImage] {
        let query = query
        return dockerImages
            .filter { image in
                guard !query.isEmpty else { return true }
                return image.displayName.lowercased().contains(query)
                    || image.statusDetail.lowercased().contains(query)
            }
            .sorted(using: dockerSortOrder)
    }

    var checkedFolders: [FoundFolder] { results.filter { checked.contains($0.id) } }
    var checkedDockerImages: [DockerImage] { dockerImages.filter { checkedImages.contains($0.id) } }
    var checkedCount: Int { checked.count + checkedImages.count }
    var checkedBytes: Int64 {
        checkedFolders.reduce(0) { $0 + ($1.size ?? 0) } + checkedDockerImages.reduce(0) { $0 + $1.uniqueSize }
    }
    var totalBytes: Int64 { results.reduce(0) { $0 + ($1.size ?? 0) } }
    var dockerBytes: Int64 { dockerImages.reduce(0) { $0 + $1.uniqueSize } }
    var orphanedBytes: Int64 { dockerImages.filter(\.status.isOrphaned).reduce(0) { $0 + $1.uniqueSize } }
    var canScan: Bool {
        !roots.isEmpty && (includeNodeModules || includeVendor || includeDocker) && !isDeleting
    }

    func isChecked(_ id: URL) -> Binding<Bool> {
        Binding(
            get: { self.checked.contains(id) },
            set: { on in
                if on { self.checked.insert(id) } else { self.checked.remove(id) }
            }
        )
    }

    func isChecked(image id: String) -> Binding<Bool> {
        Binding(
            get: { self.checkedImages.contains(id) },
            set: { on in
                if on { self.checkedImages.insert(id) } else { self.checkedImages.remove(id) }
            }
        )
    }

    /// Markiert alle sichtbaren Einträge der aktuellen Ansicht – bei Docker nur die verwaisten.
    func checkAllVisible() {
        switch section {
        case .folders:
            checked.formUnion(visibleResults.map(\.id))
        case .docker:
            checkedImages.formUnion(visibleImages.filter(\.status.isOrphaned).map(\.id))
        }
    }

    // MARK: Ordner-Auswahl (AppKit)

    func addRoots() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Hinzufügen"
        panel.message = "Ordner auswählen, die nach node_modules/, vendor/ und Docker-Projekten durchsucht werden sollen."
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
        dockerImages = []
        checkedImages = []
        dockerError = nil
        settingsChanged = false
        statusMessage = nil
        scannedCount = 0
        currentPath = ""
        isScanning = true
        hasScanned = true

        let token = CancelToken()
        scanToken = token
        let roots = roots
        let includeDocker = includeDocker
        var kinds = Set<FolderKind>()
        if includeNodeModules { kinds.insert(.nodeModules) }
        if includeVendor { kinds.insert(.vendor) }

        DispatchQueue.global(qos: .userInitiated).async { [self, sizeQueue] in
            var projects = DockerProjectIndex()
            Scanner.scan(
                roots: roots,
                kinds: kinds,
                collectDockerProjects: includeDocker,
                dockerProjects: &projects,
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
            let finishedProjects = projects
            Task { @MainActor in
                guard self.scanToken === token else { return }
                self.isScanning = false
                self.dockerProjects = finishedProjects
                if includeDocker { self.loadDocker() }
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

    /// Liest die Images neu ein (nach dem Scan und nach dem Löschen).
    func loadDocker() {
        isLoadingDocker = true
        dockerError = nil
        let projects = dockerProjects
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result { try Docker.loadImages(projects: projects) }
            Task { @MainActor in
                self.isLoadingDocker = false
                switch result {
                case .success(let images):
                    self.dockerImages = images
                    self.checkedImages.formIntersection(images.map(\.id))
                case .failure(let error):
                    self.dockerImages = []
                    self.dockerError = error.localizedDescription
                }
            }
        }
    }

    // MARK: Löschen

    func deleteChecked() {
        let folders = checkedFolders
        let images = checkedDockerImages
        guard !folders.isEmpty || !images.isEmpty, !isScanning else { return }
        let mode = deleteMode
        isDeleting = true
        statusMessage = nil

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var result = Deleter.delete(folders, mode: mode)
            result.merge(Docker.delete(images))
            Task { @MainActor in
                let deleted = Set(result.deleted)
                self.results.removeAll { deleted.contains($0.id) }
                self.checked.subtract(deleted)
                self.checkedImages.subtract(result.deletedImages)
                self.isDeleting = false

                var parts: [String] = []
                if !result.deleted.isEmpty {
                    parts.append(mode == .trash
                        ? "\(result.deleted.count) Ordner in den Papierkorb gelegt (Papierkorb leeren, um den Platz freizugeben)"
                        : "\(result.deleted.count) Ordner gelöscht")
                }
                if !result.deletedImages.isEmpty {
                    parts.append("\(result.deletedImages.count) Docker-Einträge entfernt")
                }
                if !parts.isEmpty {
                    self.statusMessage = parts.joined(separator: ", ") + " – \(result.freedBytes.formattedBytes)."
                }

                if !result.failures.isEmpty {
                    self.errorMessage = result.failures
                        .map { "\($0.name): \($0.message)" }
                        .joined(separator: "\n")
                }
                // Geteilte Schichten werden nach dem Löschen anderer Images ggf. „unique“ – neu einlesen.
                if !result.deletedImages.isEmpty { self.loadDocker() }
            }
        }
    }
}

extension Int64 {
    var formattedBytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

extension DockerImage {
    var statusLabel: String {
        switch status {
        case .inUse: "in Benutzung"
        case .project: "Projekt"
        case .dangling: "dangling"
        case .orphan: "verwaist"
        case .buildCache: "Build-Cache"
        }
    }

    var statusDetail: String {
        switch status {
        case .inUse(let count, let running, let project):
            let state = running ? "läuft" : "gestoppt"
            let containers = count == 1 ? "1 Container" : "\(count) Container"
            return [containers, state, project].compactMap { $0 }.joined(separator: " · ")
        case .project(let name, _):
            return name
        case .dangling:
            return "ohne Tag"
        case .orphan:
            return "kein Container, kein Projekt"
        case .buildCache:
            return "ungenutzt"
        }
    }

    var statusHelp: String {
        switch status {
        case .inUse:
            "Ein Container nutzt dieses Image. Docker verweigert das Löschen – erst den Container entfernen."
        case .project(_, let path):
            "Kein Container, aber das Projekt in \((path as NSString).abbreviatingWithTildeInPath) nutzt es beim nächsten Start. Löschen kostet dann einen Rebuild bzw. Pull."
        case .dangling:
            "Alte Version ohne Tag, z. B. nach einem Rebuild. Kann gefahrlos weg."
        case .orphan:
            "Weder ein Container noch ein bekanntes Projekt nutzt dieses Image."
        case .buildCache:
            "Ungenutzter Build-Cache (docker builder prune). Der nächste Build dauert länger."
        }
    }

    var statusColor: Color {
        switch status {
        case .inUse: .secondary
        case .project: .orange
        case .dangling, .orphan, .buildCache: .green
        }
    }
}
