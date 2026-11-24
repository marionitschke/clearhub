import AppKit
import Observation
import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case folders = "Ordner"
    case docker = "Images"
    case volumes = "Volumes"
    case claude = "Claude"

    var id: String { rawValue }
}

@MainActor
@Observable
final class AppModel {
    // MARK: Settings (persisted)

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
    var includeClaude: Bool {
        didSet {
            UserDefaults.standard.set(includeClaude, forKey: "includeClaude")
            markSettingsChanged()
        }
    }
    var deleteMode: DeleteMode {
        didSet { UserDefaults.standard.set(deleteMode.rawValue, forKey: "deleteMode") }
    }

    // MARK: State

    var section: Section = .folders
    var searchText = ""

    var results: [FoundFolder] = []
    var checked: Set<URL> = []
    var sortOrder = [KeyPathComparator(\FoundFolder.sizeSort, order: .reverse)]

    var dockerImages: [DockerImage] = []
    var checkedImages: Set<String> = []
    var dockerSortOrder = [KeyPathComparator(\DockerImage.statusSort), KeyPathComparator(\DockerImage.sizeSort, order: .reverse)]
    var dockerVolumes: [DockerVolume] = []
    var checkedVolumes: Set<String> = []
    var volumeSortOrder = [KeyPathComparator(\DockerVolume.statusSort), KeyPathComparator(\DockerVolume.sizeSort, order: .reverse)]
    var isLoadingDocker = false
    var dockerError: String?

    var claudeItems: [ClaudeItem] = []
    var checkedClaude: Set<String> = []
    var claudeSortOrder = [KeyPathComparator(\ClaudeItem.statusSort), KeyPathComparator(\ClaudeItem.sizeSort, order: .reverse)]
    var isLoadingClaude = false

    var isScanning = false
    var hasScanned = false
    /// Search locations or types changed since the last scan; the results are stale.
    var settingsChanged = false
    var scannedCount = 0
    var currentPath = ""
    var pendingSizes = 0

    var isDeleting = false
    var statusMessage: String?
    var errorMessage: String?

    private var scanToken: CancelToken?
    /// Counts Docker loads; only the latest one may show its result.
    private var dockerLoad = 0
    /// Counts Claude loads; only the latest one may show its result.
    private var claudeLoad = 0
    private var claudeToken: CancelToken?
    /// Compose/DDEV projects from the last scan, for reloading after a deletion.
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
        includeClaude = defaults.object(forKey: "includeClaude") as? Bool
            ?? Claude.isInstalled(home: FileManager.default.homeDirectoryForCurrentUser)
        deleteMode = DeleteMode(rawValue: defaults.string(forKey: "deleteMode") ?? "") ?? .trash
    }

    // MARK: Derived values

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

    var visibleVolumes: [DockerVolume] {
        let query = query
        return dockerVolumes
            .filter { volume in
                guard !query.isEmpty else { return true }
                return volume.name.lowercased().contains(query)
                    || volume.statusDetail.lowercased().contains(query)
            }
            .sorted(using: volumeSortOrder)
    }

    var visibleClaude: [ClaudeItem] {
        let query = query
        return claudeItems
            .filter { item in
                guard !query.isEmpty else { return true }
                return item.name.lowercased().contains(query)
                    || item.location.lowercased().contains(query)
                    || item.statusDetail.lowercased().contains(query)
            }
            .sorted(using: claudeSortOrder)
    }

    var checkedFolders: [FoundFolder] { results.filter { checked.contains($0.id) } }
    var checkedDockerImages: [DockerImage] { dockerImages.filter { checkedImages.contains($0.id) } }
    var checkedDockerVolumes: [DockerVolume] { dockerVolumes.filter { checkedVolumes.contains($0.id) } }
    var checkedClaudeItems: [ClaudeItem] { claudeItems.filter { checkedClaude.contains($0.id) } }
    var checkedCount: Int { checked.count + checkedImages.count + checkedVolumes.count + checkedClaude.count }
    var checkedBytes: Int64 {
        checkedFolders.reduce(0) { $0 + ($1.size ?? 0) }
            + checkedDockerImages.reduce(0) { $0 + $1.uniqueSize }
            + checkedDockerVolumes.reduce(0) { $0 + $1.size }
            + checkedClaudeItems.reduce(0) { $0 + $1.size }
    }
    var totalBytes: Int64 { results.reduce(0) { $0 + ($1.size ?? 0) } }
    var dockerBytes: Int64 { dockerImages.reduce(0) { $0 + $1.uniqueSize } }
    var orphanedBytes: Int64 { dockerImages.filter(\.status.isOrphaned).reduce(0) { $0 + $1.uniqueSize } }
    var orphanedVolumeBytes: Int64 { dockerVolumes.filter(\.status.isOrphaned).reduce(0) { $0 + $1.size } }
    var orphanedClaudeBytes: Int64 { claudeItems.filter(\.status.isOrphaned).reduce(0) { $0 + $1.size } }
    /// Claude data lies in fixed places, so it needs no search location.
    var canScan: Bool {
        (includeClaude || !roots.isEmpty && (includeNodeModules || includeVendor || includeDocker)) && !isDeleting
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

    func isChecked(volume id: String) -> Binding<Bool> {
        Binding(
            get: { self.checkedVolumes.contains(id) },
            set: { on in
                if on { self.checkedVolumes.insert(id) } else { self.checkedVolumes.remove(id) }
            }
        )
    }

    func isChecked(claude id: String) -> Binding<Bool> {
        Binding(
            get: { self.checkedClaude.contains(id) },
            set: { on in
                if on { self.checkedClaude.insert(id) } else { self.checkedClaude.remove(id) }
            }
        )
    }

    /// Marks all visible entries of the current view; for Docker and Claude only the orphaned ones.
    func checkAllVisible() {
        switch section {
        case .folders:
            checked.formUnion(visibleResults.map(\.id))
        case .docker:
            checkedImages.formUnion(visibleImages.filter(\.status.isOrphaned).map(\.id))
        case .volumes:
            checkedVolumes.formUnion(visibleVolumes.filter(\.status.isOrphaned).map(\.id))
        case .claude:
            checkedClaude.formUnion(visibleClaude.filter(\.status.isOrphaned).map(\.id))
        }
    }

    // MARK: Folder selection (AppKit)

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
        dockerVolumes = []
        checkedVolumes = []
        claudeItems = []
        checkedClaude = []
        dockerLoad += 1
        isLoadingDocker = false
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
        var wanted = Set<FolderKind>()
        if includeNodeModules { wanted.insert(.nodeModules) }
        if includeVendor { wanted.insert(.vendor) }
        let kinds = wanted
        // Claude data does not depend on the search locations, so it loads alongside the scan.
        if includeClaude { loadClaude() }
        let walk = !kinds.isEmpty || includeDocker

        DispatchQueue.global(qos: .userInitiated).async { [self, sizeQueue] in
            var projects = DockerProjectIndex()
            Scanner.scan(
                // Without folder types or Docker there is nothing to walk for.
                roots: walk ? roots : [],
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
            if includeDocker {
                projects.addDDEVProjectList(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ddev/project_list.yaml"))
            }
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
        claudeToken?.cancel()
        claudeToken = nil
        claudeLoad += 1
        isLoadingClaude = false
    }

    /// Reloads the Claude entries (with a scan and after a deletion).
    func loadClaude() {
        claudeToken?.cancel()
        let token = CancelToken()
        claudeToken = token
        claudeLoad += 1
        let load = claudeLoad
        isLoadingClaude = true
        let desktopRunning = Claude.isDesktopRunning
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let items = Claude.load(.current(desktopRunning: desktopRunning), token: token)
            Task { @MainActor in
                // A newer scan or load has replaced this one.
                guard self.claudeLoad == load else { return }
                self.isLoadingClaude = false
                self.claudeItems = items
                // Only marks that are still deletable survive: Claude may have started meanwhile.
                self.checkedClaude.formIntersection(items.filter(\.status.isDeletable).map(\.id))
            }
        }
    }

    /// Reloads images and volumes (after a scan and after a deletion).
    func loadDocker() {
        dockerLoad += 1
        let load = dockerLoad
        isLoadingDocker = true
        dockerError = nil
        let projects = dockerProjects
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result { try Docker.load(projects: projects) }
            Task { @MainActor in
                // A newer scan or load has replaced this one.
                guard self.dockerLoad == load else { return }
                self.isLoadingDocker = false
                switch result {
                case .success(let inventory):
                    // Only marks that are still deletable survive: a container may have started meanwhile.
                    self.dockerImages = inventory.images
                    self.checkedImages.formIntersection(inventory.images.filter(\.status.isDeletable).map(\.id))
                    self.dockerVolumes = inventory.volumes
                    self.checkedVolumes.formIntersection(inventory.volumes.filter(\.status.isDeletable).map(\.id))
                case .failure(let error):
                    self.dockerImages = []
                    self.dockerVolumes = []
                    self.dockerError = error.localizedDescription
                }
            }
        }
    }

    // MARK: Deletion

    func deleteChecked() {
        let folders = checkedFolders
        let images = checkedDockerImages
        let volumes = checkedDockerVolumes
        let claude = checkedClaudeItems
        guard !folders.isEmpty || !images.isEmpty || !volumes.isEmpty || !claude.isEmpty, !isScanning else { return }
        let mode = deleteMode
        isDeleting = true
        statusMessage = nil
        // Checked again now: Claude Desktop may have started since the scan.
        let claudeEnvironment = ClaudeEnvironment(
            home: FileManager.default.homeDirectoryForCurrentUser, desktopRunning: Claude.isDesktopRunning, runningCommands: nil
        )

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var result = Deleter.delete(folders, mode: mode)
            result.merge(Claude.delete(claude, mode: mode, environment: claudeEnvironment))
            result.merge(Docker.delete(images))
            result.merge(Docker.delete(volumes))
            Task { @MainActor in
                let deleted = Set(result.deleted)
                self.results.removeAll { deleted.contains($0.id) }
                self.checked.subtract(deleted)
                self.checkedImages.subtract(result.deletedImages)
                self.checkedVolumes.subtract(result.deletedVolumes)
                self.checkedClaude.subtract(result.deletedClaude)
                self.isDeleting = false

                var parts: [String] = []
                if !result.deleted.isEmpty {
                    parts.append(mode == .trash
                        ? "\(result.deleted.count) Ordner in den Papierkorb gelegt"
                        : "\(result.deleted.count) Ordner gelöscht")
                }
                if !result.deletedClaude.isEmpty {
                    let entries = result.deletedClaude.count == 1 ? "1 Claude-Eintrag" : "\(result.deletedClaude.count) Claude-Einträge"
                    parts.append(mode == .trash ? "\(entries) in den Papierkorb gelegt" : "\(entries) gelöscht")
                }
                if !result.deletedImages.isEmpty {
                    parts.append("\(result.deletedImages.count) Docker-Einträge entfernt")
                }
                if !result.deletedVolumes.isEmpty {
                    parts.append(result.deletedVolumes.count == 1 ? "1 Volume entfernt" : "\(result.deletedVolumes.count) Volumes entfernt")
                }
                if !parts.isEmpty {
                    var message = parts.joined(separator: ", ") + " – \(result.freedBytes.formattedBytes)."
                    if mode == .trash, !result.deleted.isEmpty || !result.deletedClaude.isEmpty {
                        message += " Papierkorb leeren, um den Platz freizugeben."
                    }
                    self.statusMessage = message
                }

                if !result.failures.isEmpty {
                    self.errorMessage = result.failures
                        .map { "\($0.name): \($0.message)" }
                        .joined(separator: "\n")
                }
                // Shared layers may become unique once other images are gone, so reload.
                if !result.deletedImages.isEmpty || !result.deletedVolumes.isEmpty { self.loadDocker() }
                if !result.deletedClaude.isEmpty { self.loadClaude() }
            }
        }
    }
}

extension Claude {
    @MainActor static var isDesktopRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: desktopBundleID).isEmpty
    }
}

extension ClaudeEnvironment {
    /// The real home folder and all running command lines. Calls ps, so off the main thread.
    static func current(desktopRunning: Bool) -> ClaudeEnvironment {
        let output = try? Docker.execute(URL(fileURLWithPath: "/bin/ps"), ["-axww", "-o", "command="], timeout: 20)
        let commands = output.map { String(decoding: $0, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init) }
        return ClaudeEnvironment(
            home: FileManager.default.homeDirectoryForCurrentUser, desktopRunning: desktopRunning, runningCommands: commands
        )
    }
}

extension ClaudeItem {
    var statusLabel: String {
        switch status {
        case .inUse: "in Benutzung"
        case .cache: "Cache"
        case .oldLogs: "alte Logs"
        case .oldVersion: "alte Version"
        case .vmImage: "VM-Image"
        case .orphanSessions: "verwaist"
        case .oldSessions: "alt"
        }
    }

    var statusDetail: String {
        switch status {
        case .inUse(.desktopRunning): "Claude läuft – erst beenden"
        case .inUse(.running): "läuft gerade"
        case .inUse(.current): "aktuelle Version"
        case .inUse(.active): "gerade aktiv"
        case .cache: "wird neu angelegt"
        case .oldLogs: urls.count == 1 ? "1 Datei" : "\(urls.count) Dateien"
        case .oldVersion(let current): current.map { "aktuell: \($0)" } ?? "Update-Download"
        case .vmImage: "wird bei Bedarf neu geladen"
        case .orphanSessions: "Projektordner fehlt"
        case .oldSessions(let count, let days):
            count == 1 ? "1 Verlauf älter als \(days) Tage" : "\(count) Verläufe älter als \(days) Tage"
        }
    }

    var statusHelp: String {
        switch status {
        case .inUse(.desktopRunning):
            "Claude Desktop nutzt diese Daten gerade. Claude beenden und erneut scannen."
        case .inUse(.running):
            "Ein laufender Claude-Prozess nutzt diese Version."
        case .inUse(.current):
            "Die Version, die Claude derzeit verwendet."
        case .inUse(.active):
            "In der letzten Stunde benutzt – bleibt unangetastet."
        case .cache:
            "Zwischenspeicher, den Claude beim nächsten Start neu anlegt."
        case .oldLogs:
            "Ältere Logdateien. Die aktuellen Logs bleiben."
        case .oldVersion(let current):
            current.map { "Programmversion, die Claude nicht nutzt. Aktuell ist \($0)." }
                ?? "Übrig gebliebener Download eines Updates."
        case .vmImage:
            "Linux-VM für Cowork. Claude Desktop lädt sie beim nächsten Einsatz von Cowork neu herunter (mehrere GB). „Verwaiste markieren“ erfasst sie nicht."
        case .orphanSessions:
            "Chat-Verläufe und Memory eines Projekts, dessen Ordner \(displayLocation) nicht mehr existiert. Sie lassen sich nicht mehr fortsetzen."
        case .oldSessions(_, let days):
            "Verläufe, die seit über \(days) Tagen nicht benutzt wurden. Danach lassen sie sich nicht mehr fortsetzen. Memory und neuere Verläufe bleiben. „Verwaiste markieren“ erfasst sie nicht."
        }
    }

    var statusColor: Color {
        switch status {
        case .inUse: Color(nsColor: Darcula.muted)
        case .vmImage, .oldSessions: Color(nsColor: Darcula.warn)
        case .cache, .oldLogs, .oldVersion, .orphanSessions: Color(nsColor: Darcula.success)
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
        case .inUse: Color(nsColor: Darcula.muted)
        case .project: Color(nsColor: Darcula.warn)
        case .dangling, .orphan, .buildCache: Color(nsColor: Darcula.success)
        }
    }
}

extension DockerVolume {
    var statusLabel: String {
        switch status {
        case .inUse: "in Benutzung"
        case .project: "Projekt"
        case .tool: "Werkzeug"
        case .anonymous: "anonym"
        case .orphan: "verwaist"
        case .missingProject: "Projekt fehlt"
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
        case .tool(let name):
            return name
        case .anonymous:
            return "Container gelöscht"
        case .orphan(let ddevSite):
            return ddevSite.map { "DDEV-Projekt \($0) gibt es nicht mehr" } ?? "kein Container, kein Projekt"
        case .missingProject(let name):
            return "Compose-Projekt \(name) nicht in den Suchorten"
        }
    }

    var statusHelp: String {
        switch status {
        case .inUse:
            "Ein Container nutzt dieses Volume. Docker verweigert das Löschen – erst den Container entfernen."
        case .project(_, let path):
            "Kein Container, aber das Projekt in \((path as NSString).abbreviatingWithTildeInPath) hält hier seine Daten (z. B. die Datenbank). ClearHub löscht es nicht."
        case .tool(let name):
            "Wird von \(name) selbst genutzt (Cache, SSH-Agent) und beim nächsten Start neu angelegt."
        case .anonymous:
            "Anonymes Volume eines gelöschten Containers. Wird nicht wiederverwendet und kann weg."
        case .orphan(let ddevSite):
            ddevSite.map {
                "Gehörte zum DDEV-Projekt „\($0)“, das DDEV nicht mehr kennt bzw. dessen .ddev/config.yaml fehlt. Die Daten darin sind nach dem Löschen weg."
            } ?? "Weder ein Container noch ein bekanntes Projekt nutzt dieses Volume. Die Daten darin sind nach dem Löschen weg."
        case .missingProject(let name):
            "Gehört zum Compose-Projekt „\(name)“, das in den Suchorten nicht gefunden wurde. Liegt es woanders, den Ordner hinzufügen und erneut scannen. „Verwaiste markieren“ erfasst es nicht."
        }
    }

    var statusColor: Color {
        switch status {
        case .inUse, .project: Color(nsColor: Darcula.muted)
        case .tool, .missingProject: Color(nsColor: Darcula.warn)
        case .anonymous, .orphan: Color(nsColor: Darcula.success)
        }
    }
}
