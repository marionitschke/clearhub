import Foundation

/// Classification of an image: can it go, and what happens then?
public enum DockerImageStatus: Hashable, Sendable {
    /// A running or stopped container uses the image; Docker refuses to delete it.
    case inUse(containers: Int, running: Bool, project: String?)
    /// No container, but a Compose/DDEV project on disk would use it on its next start.
    case project(name: String, path: String)
    /// Untagged, e.g. an old version after a rebuild.
    case dangling
    /// Tagged, but neither a container nor a known project uses it.
    case orphan
    /// Unused build cache (not an image, removed via `docker builder prune`).
    case buildCache

    public var isDeletable: Bool {
        if case .inUse = self { return false }
        return true
    }

    /// Safe to delete; included by „Verwaiste markieren“ (mark orphaned).
    public var isOrphaned: Bool {
        switch self {
        case .dangling, .orphan, .buildCache: true
        default: false
        }
    }

    public var sortRank: Int {
        switch self {
        case .dangling: 0
        case .buildCache: 1
        case .orphan: 2
        case .project: 3
        case .inUse: 4
        }
    }
}

public struct DockerImage: Identifiable, Hashable, Sendable {
    public static let buildCacheID = "build-cache"

    /// Image ID plus tag, because an image can have several tags.
    public var id: String { "\(imageID)|\(reference)" }
    public let imageID: String
    public let repository: String
    public let tag: String
    public let created: Date?
    /// Space used only by this image; freed on deletion.
    public let uniqueSize: Int64
    public let sharedSize: Int64
    public var status: DockerImageStatus

    public init(imageID: String, repository: String, tag: String, created: Date?, uniqueSize: Int64, sharedSize: Int64, status: DockerImageStatus) {
        self.imageID = imageID
        self.repository = repository
        self.tag = tag
        self.created = created
        self.uniqueSize = uniqueSize
        self.sharedSize = sharedSize
        self.status = status
    }

    public var isDangling: Bool { repository == "<none>" || tag == "<none>" }
    public var reference: String { isDangling ? imageID : "\(repository):\(tag)" }
    public var displayName: String {
        if status == .buildCache { return "Build-Cache" }
        return isDangling ? "<none>" : reference
    }
    public var shortID: String {
        let hex = imageID.hasPrefix("sha256:") ? String(imageID.dropFirst(7)) : imageID
        return String(hex.prefix(12))
    }

    // Sort keys for the table.
    public var sizeSort: Int64 { uniqueSize }
    public var createdSort: Date { created ?? .distantPast }
    public var statusSort: Int { status.sortRank }
}

/// Classification of a volume. Volumes hold data (databases, uploads) that no rebuild brings back.
public enum DockerVolumeStatus: Hashable, Sendable {
    /// Mounted by a running or stopped container; Docker refuses to delete it.
    case inUse(containers: Int, running: Bool, project: String?)
    /// No container, but a Compose/DDEV project on disk keeps its data here. Not deletable from ClearHub.
    case project(name: String, path: String)
    /// Used by a tool itself (DDEV global cache, SSH agent), which recreates it.
    case tool(name: String)
    /// Anonymous volume of a removed container (what `docker volume prune` removes).
    case anonymous
    /// Named volume that neither a container nor a known project uses.
    /// `ddevSite` is set for volumes of a DDEV project that DDEV no longer knows.
    case orphan(ddevSite: String?)
    /// Labelled for a Compose project that the scan did not find. Compose has no global project list,
    /// so the project may simply live outside the search locations.
    case missingProject(name: String)

    public var isDeletable: Bool {
        switch self {
        case .inUse, .project: false
        default: true
        }
    }

    /// Included by „Verwaiste markieren“ (mark orphaned).
    public var isOrphaned: Bool {
        switch self {
        case .anonymous, .orphan: true
        default: false
        }
    }

    public var sortRank: Int {
        switch self {
        case .anonymous: 0
        case .orphan: 1
        case .missingProject: 2
        case .tool: 3
        case .project: 4
        case .inUse: 5
        }
    }
}

public struct DockerVolume: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let driver: String
    public let size: Int64
    public var status: DockerVolumeStatus

    public init(name: String, driver: String, size: Int64, status: DockerVolumeStatus) {
        self.name = name
        self.driver = driver
        self.size = size
        self.status = status
    }

    /// Docker names anonymous volumes with 64 hex digits.
    public var isAnonymous: Bool { name.count == 64 && name.allSatisfy(\.isHexDigit) }
    public var displayName: String { isAnonymous ? "\(name.prefix(12))…" : name }

    // Sort keys for the table.
    public var sizeSort: Int64 { size }
    public var statusSort: Int { status.sortRank }
}

public struct DockerInventory: Sendable {
    public var images: [DockerImage] = []
    public var volumes: [DockerVolume] = []
}

/// Projects on disk that reference Docker images (Compose files, DDEV).
public struct DockerProjectIndex: Sendable {
    struct Project: Sendable {
        let name: String
        let path: String
    }

    /// `repo:tag` from `image:` lines.
    var imageRefs: [String: Project] = [:]
    /// Compose project names; locally built images are named `<project>-<service>`.
    var composeProjects: [String: Project] = [:]
    /// DDEV site names; built images are tagged `<version>-<site>-built`.
    var ddevSites: [String: Project] = [:]

    public init() {}

    public var isEmpty: Bool { imageRefs.isEmpty && composeProjects.isEmpty && ddevSites.isEmpty }

    public mutating func addComposeFile(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let dir = url.deletingLastPathComponent()
        let name = Self.topLevelValue("name", in: text) ?? dir.lastPathComponent
        let project = Project(name: Self.normalizedProjectName(name), path: dir.path)
        composeProjects[project.name] = project

        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("image:") else { continue }
            var ref = trimmed.dropFirst("image:".count).trimmingCharacters(in: .whitespaces)
            if let hash = ref.firstIndex(of: "#") { ref = String(ref[..<hash]).trimmingCharacters(in: .whitespaces) }
            ref = ref.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            // Variables such as ${PHP_VERSION} cannot be resolved without the .env file.
            guard !ref.isEmpty, !ref.contains("$") else { continue }
            imageRefs[Self.normalizedReference(ref)] = project
        }
    }

    public mutating func addDDEVConfig(_ url: URL) {
        let projectDir = url.deletingLastPathComponent().deletingLastPathComponent()
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let name = Self.topLevelValue("name", in: text) ?? projectDir.lastPathComponent
        ddevSites[name] = Project(name: name, path: projectDir.path)
    }

    func project(for image: DockerImage) -> Project? {
        if let project = imageRefs[Self.normalizedReference(image.reference)] { return project }
        // Compose v2 names built images `<project>-<service>`, v1 `<project>_<service>`.
        let repo = image.repository
        if let project = composeProjects.first(where: { repo.hasPrefix("\($0.key)-") || repo.hasPrefix("\($0.key)_") })?.value {
            return project
        }
        return ddevSites.first(where: { image.tag.hasSuffix("-\($0.key)-built") })?.value
    }

    /// DDEV registers every project in `~/.ddev/project_list.yaml`, also outside the search locations.
    /// Only entries whose `.ddev/config.yaml` still exists count.
    public mutating func addDDEVProjectList(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard line.first?.isWhitespace == true, trimmed.hasPrefix("approot:") else { continue }
            let path = trimmed.dropFirst("approot:".count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let config = URL(fileURLWithPath: path).appendingPathComponent(".ddev/config.yaml")
            if FileManager.default.fileExists(atPath: config.path) { addDDEVConfig(config) }
        }
    }

    func project(forVolume name: String, composeProject: String?) -> Project? {
        if let label = composeProject?.lowercased() {
            if let project = composeProjects[label] { return project }
            if label.hasPrefix("ddev-"), let project = ddevSite(String(label.dropFirst(5))) { return project }
            // The label names the owner; a similar name of another project must not claim it.
            return nil
        }
        // Without labels: Compose names volumes `<project>_<volume>`; DDEV uses `<site>-mariadb`,
        // `<site>_project_mutagen` and `ddev-<site>-snapshots`.
        let lower = name.lowercased()
        if let project = composeProjects.first(where: { lower.hasPrefix("\($0.key)_") })?.value { return project }
        return ddevSites.first(where: { entry in
            let site = entry.key.lowercased()
            return lower.hasPrefix("\(site)-") || lower.hasPrefix("\(site)_") || lower.hasPrefix("ddev-\(site)-")
        })?.value
    }

    private func ddevSite(_ name: String) -> Project? {
        ddevSites.first { $0.key.lowercased() == name }?.value
    }

    static func topLevelValue(_ key: String, in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("\(key):") {
            let value = line.dropFirst(key.count + 1)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Compose allows only lowercase letters, digits, `-` and `_` in project names.
    static func normalizedProjectName(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter {
            CharacterSet.lowercaseLetters.contains($0) || CharacterSet.decimalDigits.contains($0) || $0 == "-" || $0 == "_"
        }.map(Character.init))
    }

    /// `nginx` → `nginx:latest`, `docker.io/library/nginx:1` → `nginx:1`.
    static func normalizedReference(_ ref: String) -> String {
        var ref = ref
        for prefix in ["docker.io/library/", "docker.io/", "index.docker.io/library/"] where ref.hasPrefix(prefix) {
            ref = String(ref.dropFirst(prefix.count))
            break
        }
        if let at = ref.firstIndex(of: "@") { ref = String(ref[..<at]) }
        let lastComponent = ref.split(separator: "/").last ?? ""
        return lastComponent.contains(":") ? ref : "\(ref):latest"
    }
}

public enum DockerError: LocalizedError {
    case notInstalled
    case failed(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            "Kein docker-Befehl gefunden (Docker Desktop, OrbStack, Colima oder Rancher Desktop)."
        case .failed(let message):
            Self.isNotRunning(message)
                ? "Docker läuft nicht. Starte Docker Desktop bzw. OrbStack und scanne erneut."
                : message
        case .timedOut:
            "Docker antwortet nicht und wurde abgebrochen. Starte Docker Desktop bzw. OrbStack neu und versuche es erneut."
        }
    }

    /// Only an unreachable daemon. Refusals such as "Error response from daemon: … volume is in use"
    /// mention the daemon too, but must reach the user as they are.
    static func isNotRunning(_ message: String) -> Bool {
        ["Cannot connect to the Docker daemon", "Is the docker daemon running", "failed to connect to the docker API", "error during connect"]
            .contains { message.localizedCaseInsensitiveContains($0) }
    }
}

/// Reads a pipe to its end on a background thread.
private final class PipeReader: @unchecked Sendable {
    private let finished = DispatchSemaphore(value: 0)
    /// Written once on the reading thread; read only after `wait(until:)` succeeded.
    private(set) var data = Data()

    init(_ handle: FileHandle) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.data = handle.readDataToEndOfFile()
            self.finished.signal()
        }
    }

    func wait(until deadline: DispatchTime) -> Bool {
        finished.wait(timeout: deadline) == .success
    }
}

public enum Docker {
    /// Apps launched from the Finder do not inherit the shell PATH, hence the usual install locations.
    static var searchPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "\(home)/.orbstack/bin",
            "\(home)/.docker/bin",
            "\(home)/.rd/bin",
            "/Applications/Docker.app/Contents/Resources/bin",
            "/Applications/OrbStack.app/Contents/MacOS/xbin",
        ]
    }

    public static func findCLI() -> URL? {
        searchPaths
            .map { URL(fileURLWithPath: $0).appendingPathComponent("docker") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Docker Desktop can stop answering (VM stuck or still starting); without a limit, loading or
    /// deleting would never finish. Stopping the CLI never deletes more than was asked for.
    @discardableResult
    static func run(_ arguments: [String], timeout: TimeInterval = 180) throws -> Data {
        guard let cli = findCLI() else { throw DockerError.notInstalled }
        return try execute(cli, arguments, timeout: timeout)
    }

    /// Runs a program without a shell and returns its standard output; stops it after `timeout`.
    static func execute(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (searchPaths + ["/usr/bin", "/bin"]).joined(separator: ":")
        process.environment = environment
        // A prompt (e.g. "Are you sure?") must fail instead of waiting for input.
        process.standardInput = FileHandle.nullDevice

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        // Both pipes are read at once: reading one to its end first blocks as soon as the other is full.
        let output = PipeReader(stdout.fileHandleForReading)
        let errorOutput = PipeReader(stderr.fileHandleForReading)
        let deadline = DispatchTime.now() + timeout
        guard output.wait(until: deadline), errorOutput.wait(until: deadline),
              exited.wait(timeout: deadline) == .success
        else {
            process.terminate()
            throw DockerError.timedOut
        }

        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorOutput.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw DockerError.failed(message.isEmpty
                ? "\(executable.lastPathComponent) \(arguments.joined(separator: " ")) ist fehlgeschlagen." : message)
        }
        return output.data
    }

    /// Names and IDs come from Docker and never start with "-"; one that did would be read as an option.
    static func isSafeArgument(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-") && !value.contains { $0.isWhitespace }
    }

    /// Loads all images with their status plus the unused build cache, and all volumes.
    public static func load(projects: DockerProjectIndex) throws -> DockerInventory {
        try parse(systemDF: run(["system", "df", "-v", "--format", "{{json .}}"]), projects: projects)
    }

    // MARK: Parsing `docker system df -v --format '{{json .}}'`

    private struct SystemDF: Decodable {
        let Images: [ImageRow]?
        let Containers: [ContainerRow]?
        let BuildCache: [CacheRow]?
        let Volumes: [VolumeRow]?
    }

    private struct ImageRow: Decodable {
        let ID: String
        let Repository: String
        let Tag: String
        let CreatedAt: String
        let Containers: String
        let UniqueSize: String
        let SharedSize: String
    }

    private struct ContainerRow: Decodable {
        let Image: String
        let Labels: String?
        let State: String?
        /// Comma-separated volume names.
        let Mounts: String?
    }

    private struct VolumeRow: Decodable {
        let Name: String
        let Driver: String?
        let Labels: String?
        /// Number of containers (running or stopped) that mount the volume.
        let Links: String?
        let Size: String?
    }

    private struct CacheRow: Decodable {
        let InUse: String
        let Size: String
    }

    static func parse(systemDF data: Data, projects: DockerProjectIndex) throws -> DockerInventory {
        let df = try JSONDecoder().decode(SystemDF.self, from: data)
        let containers = df.Containers ?? []

        var images: [DockerImage] = (df.Images ?? []).map { row in
            var image = DockerImage(
                imageID: row.ID,
                repository: row.Repository,
                tag: row.Tag,
                created: parseDate(row.CreatedAt),
                uniqueSize: parseSize(row.UniqueSize),
                sharedSize: parseSize(row.SharedSize),
                status: .orphan
            )
            let users = containers.filter { matches($0.Image, image) }
            let count = max(Int(row.Containers) ?? 0, users.count)
            if count > 0 {
                let project = users.lazy.compactMap { label("com.docker.compose.project", in: $0.Labels) }.first
                image.status = .inUse(containers: count, running: users.contains { $0.State == "running" }, project: project)
            } else if image.isDangling {
                image.status = .dangling
            } else if let project = projects.project(for: image) {
                image.status = .project(name: project.name, path: project.path)
            }
            return image
        }

        let cacheBytes = (df.BuildCache ?? []).filter { $0.InUse != "true" }.reduce(Int64(0)) { $0 + parseSize($1.Size) }
        if cacheBytes > 0 {
            images.append(DockerImage(
                imageID: DockerImage.buildCacheID, repository: "", tag: "", created: nil,
                uniqueSize: cacheBytes, sharedSize: 0, status: .buildCache
            ))
        }

        let volumes: [DockerVolume] = (df.Volumes ?? []).map { row in
            var volume = DockerVolume(name: row.Name, driver: row.Driver ?? "", size: parseSize(row.Size ?? ""), status: .anonymous)
            let users = containers.filter { ($0.Mounts ?? "").split(separator: ",").contains { $0 == row.Name } }
            let count = max(Int(row.Links ?? "") ?? 0, users.count)
            let composeProject = label("com.docker.compose.project", in: row.Labels)
            if count > 0 {
                let project = composeProject ?? users.lazy.compactMap { label("com.docker.compose.project", in: $0.Labels) }.first
                volume.status = .inUse(containers: count, running: users.contains { $0.State == "running" }, project: project)
            } else if volume.isAnonymous {
                volume.status = .anonymous
            } else if row.Name == "ddev-global-cache" || row.Name.hasPrefix("ddev-ssh-agent")
                        || composeProject == "ddev-ssh-agent" || composeProject == "ddev-router" {
                volume.status = .tool(name: "DDEV")
            } else if let project = projects.project(forVolume: row.Name, composeProject: composeProject) {
                volume.status = .project(name: project.name, path: project.path)
            } else if let composeProject, composeProject.hasPrefix("ddev-") {
                volume.status = .orphan(ddevSite: String(composeProject.dropFirst(5)))
            } else if let composeProject {
                volume.status = .missingProject(name: composeProject)
            } else {
                volume.status = .orphan(ddevSite: nil)
            }
            return volume
        }
        return DockerInventory(images: images, volumes: volumes)
    }

    /// Containers reference images by `repo:tag`, `repo` (= latest) or ID.
    private static func matches(_ containerImage: String, _ image: DockerImage) -> Bool {
        if !image.isDangling {
            if containerImage == image.reference { return true }
            if image.tag == "latest", containerImage == image.repository { return true }
        }
        let hex = image.imageID.replacingOccurrences(of: "sha256:", with: "")
        let ref = containerImage.replacingOccurrences(of: "sha256:", with: "")
        return ref.count >= 12 && hex.hasPrefix(ref)
    }

    private static func label(_ key: String, in labels: String?) -> String? {
        labels?.split(separator: ",")
            .first { $0.hasPrefix("\(key)=") }
            .map { String($0.dropFirst(key.count + 1)) }
    }

    /// Docker prints decimal sizes: `408.2MB`, `9.557kB`, `0B`, `N/A`.
    static func parseSize(_ text: String) -> Int64 {
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (suffix, factor) in units where text.hasSuffix(suffix) {
            // Anything outside 0 B … 1 PB is no real size ("inf", "nan"); Int64(_:) would trap on it,
            // and sums of such values could overflow.
            guard let value = Double(text.dropLast(suffix.count)), value >= 0, value * factor < 1e15 else { return 0 }
            return Int64((value * factor).rounded())
        }
        return 0
    }

    /// `2026-10-22 17:06:28 +0200 CEST`; the time zone abbreviation is ignored.
    static func parseDate(_ text: String) -> Date? {
        let parts = text.split(separator: " ")
        guard parts.count >= 3 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let time = parts[1].split(separator: ".").first ?? parts[1]
        return formatter.date(from: "\(parts[0]) \(time) \(parts[2])")
    }

    // MARK: Deletion

    /// Removes images without `--force`: Docker itself refuses anything a container uses.
    public static func delete(_ images: [DockerImage]) -> DeleteResult {
        var result = DeleteResult()
        var unresponsive = false
        for image in images where image.status.isDeletable {
            do {
                // After one timeout every further call would only wait out the limit again.
                if unresponsive { throw DockerError.timedOut }
                if image.status == .buildCache {
                    // Here `--force` only skips the confirmation prompt; cache in use stays.
                    try run(["builder", "prune", "--all", "--force"], timeout: 600)
                } else {
                    guard isSafeArgument(image.reference) else { throw DockerError.failed("Ungültiger Name – übersprungen.") }
                    try run(["image", "rm", image.reference])
                }
                result.deletedImages.append(image.id)
                result.freedBytes += image.uniqueSize
            } catch {
                if case DockerError.timedOut = error { unresponsive = true }
                result.failures.append((image.displayName, error.localizedDescription))
            }
        }
        return result
    }

    /// Removes volumes. Volumes in use or owned by a project on disk are never even tried.
    public static func delete(_ volumes: [DockerVolume]) -> DeleteResult {
        var result = DeleteResult()
        var unresponsive = false
        for volume in volumes where volume.status.isDeletable {
            do {
                if unresponsive { throw DockerError.timedOut }
                guard isSafeArgument(volume.name) else { throw DockerError.failed("Ungültiger Name – übersprungen.") }
                try run(["volume", "rm", volume.name])
                result.deletedVolumes.append(volume.id)
                result.freedBytes += volume.size
            } catch {
                if case DockerError.timedOut = error { unresponsive = true }
                result.failures.append((volume.displayName, error.localizedDescription))
            }
        }
        return result
    }
}
