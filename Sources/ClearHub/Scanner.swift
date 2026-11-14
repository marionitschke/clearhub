import Foundation

/// Searches directory trees for `node_modules/` and project `vendor/` folders.
/// All functions are synchronous and blocking; they run on a background queue.
public enum Scanner {
    /// Project files that mark a `vendor/` folder as a dependency folder, and what the package manager
    /// itself puts into it. Bundler installs only to `vendor/bundle`; a Rails app's `vendor/` also holds
    /// committed code (`javascript/`, `assets/`), so there `bundle` must be all it holds.
    static let vendorMarkers: [(file: String, content: String, ecosystem: String)] = [
        ("composer.json", "composer", "Composer"),
        ("go.mod", "modules.txt", "Go"),
        ("Gemfile", "bundle", "Bundler"),
    ]

    static let composeFileNames: Set<String> = [
        "compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml",
    ]

    /// Files that identify a project folder. `.ddev/config.yaml` is only looked up next to them,
    /// because hidden folders are skipped otherwise.
    static let projectMarkerNames: Set<String> = [
        "composer.json", "package.json", "go.mod", "Gemfile",
    ]

    /// Paths that are never searched (system, app data, Trash).
    static var excludedPaths: Set<String> {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/Library",
            "\(home)/.Trash",
            "/System",
            "/Library",
            "/private",
            "/usr",
            "/bin",
            "/sbin",
            "/dev",
            "/cores",
        ]
    }

    /// Walks `roots` and reports every match via `onFound`.
    /// `onProgress` is called, throttled, with the number of folders checked and the current path.
    /// With `collectDockerProjects`, Compose files and DDEV projects are collected in `dockerProjects`.
    public static func scan(
        roots: [URL],
        kinds: Set<FolderKind>,
        collectDockerProjects: Bool = false,
        dockerProjects: inout DockerProjectIndex,
        token: CancelToken,
        onFound: (FoundFolder) -> Void,
        onProgress: (Int, String) -> Void
    ) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let excluded = excludedPaths
        var visited = 0
        var seen = Set<String>()
        var checkedForDDEV = Set<String>()

        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                // Hidden folders (.git, .nvm, .cache …) stay untouched; .nvm holds global npm packages.
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                if token.isCancelled { return }

                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isSymbolicLink != true
                else { continue }

                if values.isDirectory != true {
                    if collectDockerProjects {
                        collectDockerFile(url, into: &dockerProjects, checkedForDDEV: &checkedForDDEV)
                    }
                    continue
                }

                visited += 1
                if visited % 250 == 0 { onProgress(visited, url.path) }

                let path = url.standardizedFileURL.path
                if excluded.contains(path) {
                    enumerator.skipDescendants()
                    continue
                }

                switch url.lastPathComponent {
                case "node_modules":
                    // Never descend into node_modules, even if the type is deselected.
                    enumerator.skipDescendants()
                    if kinds.contains(.nodeModules), seen.insert(path).inserted {
                        onFound(makeFolder(url, kind: .nodeModules, ecosystem: nodeEcosystem(of: url.deletingLastPathComponent())))
                    }
                case "vendor" where kinds.contains(.vendor):
                    if let ecosystem = vendorEcosystem(of: url.deletingLastPathComponent()) {
                        enumerator.skipDescendants()
                        if seen.insert(path).inserted {
                            onFound(makeFolder(url, kind: .vendor, ecosystem: ecosystem))
                        }
                    }
                default:
                    break
                }
            }
        }
        onProgress(visited, "")
    }

    private static func collectDockerFile(_ url: URL, into index: inout DockerProjectIndex, checkedForDDEV: inout Set<String>) {
        let name = url.lastPathComponent
        if composeFileNames.contains(name) {
            index.addComposeFile(url)
        }
        if composeFileNames.contains(name) || projectMarkerNames.contains(name) {
            let project = url.deletingLastPathComponent()
            guard checkedForDDEV.insert(project.path).inserted else { return }
            let config = project.appendingPathComponent(".ddev/config.yaml")
            if FileManager.default.fileExists(atPath: config.path) {
                index.addDDEVConfig(config)
            }
        }
    }

    /// Disk space used by a folder in bytes, hidden files included.
    public static func size(of url: URL, token: CancelToken) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        while let file = enumerator.nextObject() as? URL {
            if token.isCancelled { break }
            let values = try? file.resourceValues(forKeys: Set(keys))
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Returns the package manager if `project` is a project with `vendor/` dependencies.
    static func vendorEcosystem(of project: URL) -> String? {
        let fm = FileManager.default
        let vendor = project.appendingPathComponent("vendor")
        return vendorMarkers.first { marker in
            guard fm.fileExists(atPath: project.appendingPathComponent(marker.file).path),
                  fm.fileExists(atPath: vendor.appendingPathComponent(marker.content).path)
            else { return false }
            guard marker.ecosystem == "Bundler" else { return true }
            let visible = (try? fm.contentsOfDirectory(atPath: vendor.path))?.filter { !$0.hasPrefix(".") }
            return visible == ["bundle"]
        }?.ecosystem
    }

    static func nodeEcosystem(of project: URL) -> String {
        let fm = FileManager.default
        let lockfiles = [("pnpm-lock.yaml", "pnpm"), ("yarn.lock", "Yarn"), ("bun.lockb", "Bun"), ("bun.lock", "Bun")]
        return lockfiles.first { fm.fileExists(atPath: project.appendingPathComponent($0.0).path) }?.1 ?? "npm"
    }

    private static func makeFolder(_ url: URL, kind: FolderKind, ecosystem: String) -> FoundFolder {
        let project = url.deletingLastPathComponent()
        let modified = (try? project.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return FoundFolder(url: url, kind: kind, ecosystem: ecosystem, modified: modified)
    }
}
