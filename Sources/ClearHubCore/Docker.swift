import Foundation

/// Einordnung eines Images: Darf es weg, und was passiert dann?
public enum DockerImageStatus: Hashable, Sendable {
    /// Ein laufender oder gestoppter Container nutzt das Image – Docker verweigert das Löschen.
    case inUse(containers: Int, running: Bool, project: String?)
    /// Kein Container, aber ein Compose-/DDEV-Projekt auf der Platte würde es beim nächsten Start nutzen.
    case project(name: String, path: String)
    /// Ohne Tag, z. B. alte Version nach einem Rebuild.
    case dangling
    /// Getaggt, aber weder Container noch bekanntes Projekt.
    case orphan
    /// Ungenutzter Build-Cache (kein Image, wird per `docker builder prune` entfernt).
    case buildCache

    public var isDeletable: Bool {
        if case .inUse = self { return false }
        return true
    }

    /// Ohne Risiko löschbar – wird von „Verwaiste markieren“ erfasst.
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

    /// Bild-ID plus Tag, denn ein Image kann mehrere Tags haben.
    public var id: String { "\(imageID)|\(reference)" }
    public let imageID: String
    public let repository: String
    public let tag: String
    public let created: Date?
    /// Platz, den nur dieses Image belegt – wird beim Löschen frei.
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

    // Sortier-Schlüssel für die Tabelle.
    public var sizeSort: Int64 { uniqueSize }
    public var createdSort: Date { created ?? .distantPast }
    public var statusSort: Int { status.sortRank }
}

/// Projekte auf der Platte, die Docker-Images referenzieren (Compose-Dateien, DDEV).
public struct DockerProjectIndex: Sendable {
    struct Project: Sendable {
        let name: String
        let path: String
    }

    /// `repo:tag` aus `image:`-Zeilen.
    var imageRefs: [String: Project] = [:]
    /// Compose-Projektnamen – selbst gebaute Images heißen `<projekt>-<service>`.
    var composeProjects: [String: Project] = [:]
    /// DDEV-Sitenamen – gebaute Images haben den Tag `<version>-<site>-built`.
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
            // Variablen wie ${PHP_VERSION} lassen sich ohne .env nicht auflösen.
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
        // Compose v2 benennt gebaute Images `<projekt>-<service>`, v1 `<projekt>_<service>`.
        let repo = image.repository
        if let project = composeProjects.first(where: { repo.hasPrefix("\($0.key)-") || repo.hasPrefix("\($0.key)_") })?.value {
            return project
        }
        return ddevSites.first(where: { image.tag.hasSuffix("-\($0.key)-built") })?.value
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

    /// Compose erlaubt im Projektnamen nur Kleinbuchstaben, Ziffern, `-` und `_`.
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

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            "Kein docker-Befehl gefunden (Docker Desktop, OrbStack, Colima oder Rancher Desktop)."
        case .failed(let message):
            message.contains("Cannot connect") || message.contains("daemon")
                ? "Docker läuft nicht. Starte Docker Desktop bzw. OrbStack und scanne erneut."
                : message
        }
    }
}

public enum Docker {
    /// Apps aus dem Finder erben den Shell-PATH nicht – daher die üblichen Installationsorte.
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

    @discardableResult
    static func run(_ arguments: [String]) throws -> Data {
        guard let cli = findCLI() else { throw DockerError.notInstalled }
        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (searchPaths + ["/usr/bin", "/bin"]).joined(separator: ":")
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Erst lesen, dann warten – sonst blockiert ein voller Pipe-Puffer.
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw DockerError.failed(message.isEmpty ? "docker \(arguments.joined(separator: " ")) ist fehlgeschlagen." : message)
        }
        return output
    }

    /// Lädt alle Images samt Status und den ungenutzten Build-Cache.
    public static func loadImages(projects: DockerProjectIndex) throws -> [DockerImage] {
        try parse(systemDF: run(["system", "df", "-v", "--format", "{{json .}}"]), projects: projects)
    }

    // MARK: Parsing von `docker system df -v --format '{{json .}}'`

    private struct SystemDF: Decodable {
        let Images: [ImageRow]?
        let Containers: [ContainerRow]?
        let BuildCache: [CacheRow]?
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
    }

    private struct CacheRow: Decodable {
        let InUse: String
        let Size: String
    }

    static func parse(systemDF data: Data, projects: DockerProjectIndex) throws -> [DockerImage] {
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
        return images
    }

    /// Container referenzieren Images per `repo:tag`, `repo` (= latest) oder ID.
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

    /// Docker gibt Größen dezimal aus: `408.2MB`, `9.557kB`, `0B`, `N/A`.
    static func parseSize(_ text: String) -> Int64 {
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (suffix, factor) in units where text.hasSuffix(suffix) {
            guard let value = Double(text.dropLast(suffix.count)) else { return 0 }
            return Int64(value * factor)
        }
        return 0
    }

    /// `2026-10-22 17:06:28 +0200 CEST` – die Zeitzonen-Abkürzung wird ignoriert.
    static func parseDate(_ text: String) -> Date? {
        let parts = text.split(separator: " ")
        guard parts.count >= 3 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let time = parts[1].split(separator: ".").first ?? parts[1]
        return formatter.date(from: "\(parts[0]) \(time) \(parts[2])")
    }

    // MARK: Löschen

    /// Entfernt Images ohne `--force`: Was ein Container nutzt, lehnt Docker selbst ab.
    public static func delete(_ images: [DockerImage]) -> DeleteResult {
        var result = DeleteResult()
        for image in images where image.status.isDeletable {
            do {
                if image.status == .buildCache {
                    try run(["builder", "prune", "--all", "--force"])
                } else {
                    try run(["image", "rm", image.reference])
                }
                result.deletedImages.append(image.id)
                result.freedBytes += image.uniqueSize
            } catch {
                result.failures.append((image.displayName, error.localizedDescription))
            }
        }
        return result
    }
}
