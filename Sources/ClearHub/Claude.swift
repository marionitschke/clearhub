import Foundation

/// Why a Claude entry is locked.
public enum ClaudeLock: Hashable, Sendable {
    /// Claude Desktop is running and uses the data (browser cache, VM).
    case desktopRunning
    /// A running process was started from this version, or the process list is unknown.
    case running
    /// The version Claude uses now.
    case current
    /// Used within the last hour.
    case active
}

/// Classification of a Claude entry: can it go, and what happens then?
public enum ClaudeStatus: Hashable, Sendable {
    case inUse(ClaudeLock)
    /// Cache that Claude recreates (browser cache, MCP logs).
    case cache
    /// Rotated or long unused log files; the current log stays.
    case oldLogs
    /// A version Claude does not use; `current` is the one it uses, nil for a leftover update download.
    case oldVersion(current: String?)
    /// Cowork's Linux VM; Claude Desktop downloads it again when Cowork needs it.
    case vmImage
    /// Conversations of a project whose folder no longer exists.
    case orphanSessions
    /// Conversations of an existing project, unused for longer than `days` days.
    case oldSessions(count: Int, days: Int)

    public var isDeletable: Bool {
        if case .inUse = self { return false }
        return true
    }

    /// Safe to delete; included by „Verwaiste markieren“ (mark orphaned).
    public var isOrphaned: Bool {
        switch self {
        case .cache, .oldLogs, .oldVersion, .orphanSessions: true
        default: false
        }
    }

    public var sortRank: Int {
        switch self {
        case .orphanSessions: 0
        case .cache: 1
        case .oldVersion: 2
        case .oldLogs: 3
        case .oldSessions: 4
        case .vmImage: 5
        case .inUse: 6
        }
    }
}

public enum ClaudeApp: String, Sendable {
    case desktop = "Claude Desktop"
    case code = "Claude Code"
}

/// One deletable unit: a cache, a version, a log set or the conversations of one project.
public struct ClaudeItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let app: ClaudeApp
    /// Shown below the name: the project folder for conversations, otherwise the containing folder.
    public let location: String
    /// Everything that is deleted.
    public let urls: [URL]
    public let size: Int64
    public let modified: Date?
    public var status: ClaudeStatus
    /// Claude Desktop must be closed when this is deleted.
    public var needsDesktopClosed = false

    public var displayLocation: String { (location as NSString).abbreviatingWithTildeInPath }

    // Sort keys for the table.
    public var sizeSort: Int64 { size }
    public var modifiedSort: Date { modified ?? .distantPast }
    public var statusSort: Int { status.sortRank }
}

/// What the Claude scan depends on besides the file system; the checks pass their own.
public struct ClaudeEnvironment: Sendable {
    public var home: URL
    public var desktopRunning: Bool
    /// Command lines of all running processes; nil if unknown, then every older version counts as running.
    public var runningCommands: [String]?
    public var now: Date
    /// Conversations unused for longer count as old (Claude Code's own default for `cleanupPeriodDays`).
    public var sessionAgeDays: Int

    public init(home: URL, desktopRunning: Bool, runningCommands: [String]?, now: Date = Date(), sessionAgeDays: Int = 30) {
        self.home = home
        self.desktopRunning = desktopRunning
        self.runningCommands = runningCommands
        self.now = now
        self.sessionAgeDays = sessionAgeDays
    }
}

/// Finds caches, old versions, logs and conversations of Claude Desktop and Claude Code.
/// Only fixed locations in the home folder are read; the search locations play no part.
public enum Claude {
    public static let desktopBundleID = "com.anthropic.claudefordesktop"

    /// Chromium caches of Claude Desktop; it recreates them on its next start.
    static let desktopCacheNames = ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache", "GraphiteDawnCache"]

    struct Locations {
        let home: URL

        var config: URL { home.appendingPathComponent(".claude") }
        var projects: URL { config.appendingPathComponent("projects") }
        var downloads: URL { config.appendingPathComponent("downloads") }
        var debug: URL { config.appendingPathComponent("debug") }
        var desktop: URL { home.appendingPathComponent("Library/Application Support/Claude") }
        var desktopVersions: URL { desktop.appendingPathComponent("claude-code") }
        var vmVersions: URL { desktop.appendingPathComponent("claude-code-vm") }
        var vmBundles: URL { desktop.appendingPathComponent("vm_bundles") }
        var desktopCaches: URL { home.appendingPathComponent("Library/Caches/com.anthropic.claudefordesktop") }
        var mcpLogs: URL { home.appendingPathComponent("Library/Caches/claude-cli-nodejs") }
        var logs: URL { home.appendingPathComponent("Library/Logs/Claude") }
        var nativeVersions: URL { home.appendingPathComponent(".local/share/claude/versions") }
        var launcher: URL { home.appendingPathComponent(".local/bin/claude") }

        /// Folders of one conversation outside its project folder, named by the session ID.
        var sessionFolders: [URL] { ["file-history", "session-env"].map { config.appendingPathComponent($0) } }
        var todos: URL { config.appendingPathComponent("todos") }

        /// Everything ClearHub deletes lies strictly inside one of these folders, or is a desktop cache.
        var deletableRoots: [URL] {
            [projects, downloads, debug, todos, desktopVersions, vmVersions, vmBundles, desktopCaches, mcpLogs, logs, nativeVersions]
                + sessionFolders
        }

        func mayDelete(_ url: URL) -> Bool {
            let path = url.standardizedFileURL.path
            if Claude.desktopCacheNames.contains(where: { desktop.appendingPathComponent($0).standardizedFileURL.path == path }) {
                return true
            }
            return deletableRoots.contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
        }
    }

    /// Claude Desktop or Claude Code has left data in this home folder.
    public static func isInstalled(home: URL) -> Bool {
        let places = Locations(home: home)
        return [places.config, places.desktop].contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// All entries with their status. Blocking; runs on a background queue.
    public static func load(_ env: ClaudeEnvironment, token: CancelToken) -> [ClaudeItem] {
        let places = Locations(home: env.home)
        var items: [ClaudeItem] = []
        items += [desktopCache(places, env, token), mcpLogs(places, token)].compactMap { $0 }
        items += versions(in: places.desktopVersions, app: .desktop, current: nil, env: env, token: token) { "Claude Code \($0)" }
        items += versions(in: places.vmVersions, app: .desktop, current: nil, env: env, token: token) { "Claude Code \($0) (VM)" }
        items += versions(in: places.nativeVersions, app: .code, current: nativeCurrentVersion(places), env: env, token: token) { "Claude Code \($0)" }
        items += downloads(places, env, token)
        items += vmImages(places, env, token)
        items += [desktopLogs(places, env, token), debugLogs(places, env, token)].compactMap { $0 }
        items += sessions(places, env, token)
        return items
    }

    // MARK: Caches and logs

    private static func desktopCache(_ places: Locations, _ env: ClaudeEnvironment, _ token: CancelToken) -> ClaudeItem? {
        let urls = desktopCacheNames.map { places.desktop.appendingPathComponent($0) }.filter(exists)
            + children(of: places.desktopCaches)
        guard !urls.isEmpty else { return nil }
        return ClaudeItem(
            id: "desktop-cache", name: "Browser-Cache", app: .desktop, location: places.desktop.path,
            urls: urls, size: size(of: urls, token: token), modified: newest(urls),
            status: env.desktopRunning ? .inUse(.desktopRunning) : .cache, needsDesktopClosed: true
        )
    }

    /// Logs of MCP servers, one folder per project; Claude Code creates them again.
    private static func mcpLogs(_ places: Locations, _ token: CancelToken) -> ClaudeItem? {
        let urls = children(of: places.mcpLogs)
        guard !urls.isEmpty else { return nil }
        return ClaudeItem(
            id: "mcp-logs", name: "MCP-Logs", app: .code, location: places.mcpLogs.path,
            urls: urls, size: size(of: urls, token: token), modified: newest(urls), status: .cache
        )
    }

    /// Rotated logs (`main1.log` next to `main.log`) and logs unused for longer than the session age.
    private static func desktopLogs(_ places: Locations, _ env: ClaudeEnvironment, _ token: CancelToken) -> ClaudeItem? {
        let files = children(of: places.logs).filter { !isDirectory($0) && $0.pathExtension == "log" }
        let names = Set(files.map(\.lastPathComponent))
        let cutoff = env.now.addingTimeInterval(-Double(env.sessionAgeDays) * 86_400)
        let urls = files.filter { isRotatedLog($0.lastPathComponent, siblings: names) || (modified($0) ?? env.now) < cutoff }
        guard !urls.isEmpty else { return nil }
        return ClaudeItem(
            id: "desktop-logs", name: "Alte Logs", app: .desktop, location: places.logs.path,
            urls: urls, size: size(of: urls, token: token), modified: newest(urls), status: .oldLogs
        )
    }

    /// Debug logs of Claude Code sessions; the last day stays, a running session may still write.
    private static func debugLogs(_ places: Locations, _ env: ClaudeEnvironment, _ token: CancelToken) -> ClaudeItem? {
        let cutoff = env.now.addingTimeInterval(-86_400)
        let urls = children(of: places.debug).filter { (modified($0) ?? env.now) < cutoff }
        guard !urls.isEmpty else { return nil }
        return ClaudeItem(
            id: "debug-logs", name: "Debug-Logs", app: .code, location: places.debug.path,
            urls: urls, size: size(of: urls, token: token), modified: newest(urls), status: .oldLogs
        )
    }

    /// `main1.log` is rotated if `main.log` exists; `mcp-server-x2.log` alone is the current log of server "x2".
    static func isRotatedLog(_ name: String, siblings: Set<String>) -> Bool {
        guard name.hasSuffix(".log") else { return false }
        let stem = name.dropLast(4)
        var base = stem
        while let last = base.last, last.isNumber { base = base.dropLast() }
        return base.count < stem.count && siblings.contains("\(base).log")
    }

    // MARK: Versions

    /// Version folders (or binaries) such as `2.1.330`. The current one and those a process runs from stay.
    private static func versions(
        in dir: URL, app: ClaudeApp, current: String?, env: ClaudeEnvironment, token: CancelToken,
        name: (String) -> String
    ) -> [ClaudeItem] {
        let found = children(of: dir)
            .filter { !isSymbolicLink($0) }
            .compactMap { url in versionNumbers(url.lastPathComponent).map { (url, $0) } }
            .sorted { $0.1.lexicographicallyPrecedes($1.1) }
        guard let newest = found.last else { return [] }
        let currentVersion = current ?? newest.0.lastPathComponent
        return found.map { url, _ in
            let version = url.lastPathComponent
            let status: ClaudeStatus
            if version == currentVersion {
                status = .inUse(.current)
            } else if isRunning(url, env) {
                status = .inUse(.running)
            } else {
                status = .oldVersion(current: currentVersion)
            }
            return ClaudeItem(
                id: url.path, name: name(version), app: app, location: dir.path,
                urls: [url], size: size(of: [url], token: token), modified: modified(url), status: status
            )
        }
    }

    /// The native installer points `~/.local/bin/claude` at the version in use.
    private static func nativeCurrentVersion(_ places: Locations) -> String? {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: places.launcher.path) else { return nil }
        return URL(fileURLWithPath: target).lastPathComponent
    }

    /// `2.1.330` → [2, 1, 330]; anything else is no version.
    static func versionNumbers(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == parts.count ? numbers : nil
    }

    static func isRunning(_ url: URL, _ env: ClaudeEnvironment) -> Bool {
        guard let commands = env.runningCommands else { return true }
        let path = url.standardizedFileURL.path
        return commands.contains { $0 == path || $0.hasPrefix(path + " ") || $0.contains(path + "/") }
    }

    /// Leftover update downloads; one from the last hour may still be in progress.
    private static func downloads(_ places: Locations, _ env: ClaudeEnvironment, _ token: CancelToken) -> [ClaudeItem] {
        children(of: places.downloads).map { url in
            let changed = modified(url)
            return ClaudeItem(
                id: url.path, name: url.lastPathComponent, app: .code, location: places.downloads.path,
                urls: [url], size: size(of: [url], token: token), modified: changed,
                status: (changed ?? env.now) > env.now.addingTimeInterval(-3_600) ? .inUse(.active) : .oldVersion(current: nil)
            )
        }
    }

    private static func vmImages(_ places: Locations, _ env: ClaudeEnvironment, _ token: CancelToken) -> [ClaudeItem] {
        children(of: places.vmBundles).filter { $0.pathExtension == "bundle" && !isSymbolicLink($0) }.map { url in
            ClaudeItem(
                id: url.path, name: "Cowork-VM", app: .desktop, location: places.vmBundles.path,
                urls: [url], size: size(of: [url], token: token), modified: modified(url),
                status: env.desktopRunning ? .inUse(.desktopRunning) : .vmImage, needsDesktopClosed: true
            )
        }
    }

    // MARK: Conversations

    /// Per project folder in `~/.claude/projects`: all conversations if the project is gone,
    /// otherwise only those unused for longer than the session age. Memory stays with existing projects.
    private static func sessions(_ places: Locations, _ env: ClaudeEnvironment, _ token: CancelToken) -> [ClaudeItem] {
        let cutoff = env.now.addingTimeInterval(-Double(env.sessionAgeDays) * 86_400)
        let activeCutoff = env.now.addingTimeInterval(-3_600)
        var items: [ClaudeItem] = []
        for project in children(of: places.projects) where isDirectory(project) && !isSymbolicLink(project) {
            if token.isCancelled { break }
            let entries = children(of: project)
            // Transcripts are named by the session ID; newest first.
            let transcripts = entries
                .filter { $0.pathExtension == "jsonl" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
                .map { (url: $0, id: $0.deletingPathExtension().lastPathComponent, modified: modified($0) ?? env.now) }
                .sorted { $0.modified > $1.modified }
            guard let newest = transcripts.first,
                  let cwd = transcripts.lazy.compactMap({ sessionDirectory(ofTranscript: $0.url) }).first
            else { continue }
            let name = URL(fileURLWithPath: cwd).lastPathComponent

            if projectIsGone(cwd) {
                let urls = [project] + transcripts.flatMap { sessionExtras($0.id, places) }
                items.append(ClaudeItem(
                    id: project.path, name: name, app: .code, location: cwd,
                    urls: urls, size: size(of: urls, token: token), modified: newest.modified,
                    status: newest.modified > activeCutoff ? .inUse(.active) : .orphanSessions
                ))
            } else {
                let old = transcripts.filter { $0.modified < cutoff }
                guard let latest = old.first else { continue }
                let urls = old.flatMap { session in
                    entries.filter { $0.lastPathComponent == session.id || $0.lastPathComponent.hasPrefix(session.id + ".") }
                        + sessionExtras(session.id, places)
                }
                items.append(ClaudeItem(
                    id: project.path, name: name, app: .code, location: cwd,
                    urls: urls, size: size(of: urls, token: token), modified: latest.modified,
                    status: .oldSessions(count: old.count, days: env.sessionAgeDays)
                ))
            }
        }
        return items
    }

    /// Rewind backups, shell environment and todos of a session, kept outside its project folder.
    private static func sessionExtras(_ id: String, _ places: Locations) -> [URL] {
        places.sessionFolders.map { $0.appendingPathComponent(id) }.filter(exists)
            + children(of: places.todos).filter { $0.lastPathComponent.hasPrefix(id) }
    }

    /// The working folder of a conversation: the first `"cwd"` in its transcript (within the first MB).
    static func sessionDirectory(ofTranscript url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1 << 20) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let key = text.range(of: "\"cwd\":\"") else { return nil }
        // Copy the JSON string literal up to its closing quote, then let JSON undo the escapes.
        var literal = "\""
        var escaped = false
        for char in text[key.upperBound...] {
            literal.append(char)
            if escaped {
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if char == "\"" {
                break
            }
        }
        guard let path = try? JSONDecoder().decode(String.self, from: Data(literal.utf8)), path.hasPrefix("/") else { return nil }
        return path
    }

    /// A folder on a volume that is not mounted is not gone, only out of reach.
    static func projectIsGone(_ path: String) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { return false }
        let parts = URL(fileURLWithPath: path).pathComponents
        if parts.count > 2, parts[1] == "Volumes" {
            return fm.fileExists(atPath: "/Volumes/\(parts[2])")
        }
        return true
    }

    // MARK: Deletion

    /// Deletes the entries. Locked ones are never tried, Desktop data only while Claude Desktop is closed,
    /// and only paths inside Claude's own folders; links are never followed.
    public static func delete(_ items: [ClaudeItem], mode: DeleteMode, environment env: ClaudeEnvironment) -> DeleteResult {
        var result = DeleteResult()
        let places = Locations(home: env.home)
        let fm = FileManager.default
        for item in items where item.status.isDeletable {
            if item.needsDesktopClosed && env.desktopRunning {
                result.failures.append((item.name, "Claude Desktop läuft – erst beenden, dann erneut scannen."))
                continue
            }
            guard item.urls.allSatisfy(places.mayDelete) else {
                result.failures.append((item.name, "Liegt außerhalb der Claude-Ordner – übersprungen."))
                continue
            }
            var problem: String?
            for url in item.urls {
                // lstat, not the URL's cached values. Whatever vanished since the scan needs no deletion.
                guard let type = (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType else { continue }
                guard type != .typeSymbolicLink else {
                    problem = "\(url.lastPathComponent) ist ein Link – übersprungen."
                    continue
                }
                do {
                    switch mode {
                    case .trash: try fm.trashItem(at: url, resultingItemURL: nil)
                    case .permanent: try fm.removeItem(at: url)
                    }
                } catch {
                    problem = error.localizedDescription
                }
            }
            if let problem {
                result.failures.append((item.name, problem))
            } else {
                result.deletedClaude.append(item.id)
                result.freedBytes += item.size
            }
        }
        return result
    }

    // MARK: File helpers

    private static func children(of dir: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        return (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
    }

    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func newest(_ urls: [URL]) -> Date? { urls.compactMap(modified).max() }

    /// Disk space of files and folders together; links count as nothing.
    private static func size(of urls: [URL], token: CancelToken) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        return urls.reduce(0) { total, url in
            guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { return total }
            if values.isDirectory == true { return total + Scanner.size(of: url, token: token) }
            return total + Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
    }
}
