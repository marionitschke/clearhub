import Foundation

/// Durchsucht Verzeichnisbäume nach `node_modules/` und Projekt-`vendor/`-Ordnern.
/// Alle Funktionen sind synchron und blockierend – sie laufen auf einer Hintergrund-Queue.
public enum Scanner {
    /// Projektdateien, die einen `vendor/`-Ordner als Abhängigkeits-Ordner ausweisen.
    static let vendorMarkers: [(file: String, ecosystem: String)] = [
        ("composer.json", "Composer"),
        ("go.mod", "Go"),
        ("Gemfile", "Bundler"),
    ]

    static let composeFileNames: Set<String> = [
        "compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml",
    ]

    /// Dateien, an denen ein Projektordner erkannt wird – dort wird nach `.ddev/config.yaml` geschaut,
    /// weil versteckte Ordner sonst übersprungen werden.
    static let projectMarkerNames: Set<String> = [
        "composer.json", "package.json", "go.mod", "Gemfile",
    ]

    /// Pfade, in die nie hineingesucht wird (System, App-Daten, Papierkorb).
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

    /// Durchläuft `roots` und meldet jeden Fund über `onFound`.
    /// `onProgress` wird gedrosselt mit der Zahl geprüfter Ordner und dem aktuellen Pfad aufgerufen.
    /// Mit `collectDockerProjects` werden Compose-Dateien und DDEV-Projekte in `dockerProjects` gesammelt.
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
                // Versteckte Ordner (.git, .nvm, .cache …) bleiben unangetastet.
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
                    // Nie in node_modules hineinsuchen – auch wenn der Typ abgewählt ist.
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

    /// Belegter Speicherplatz eines Ordners in Bytes (inkl. versteckter Dateien).
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

    /// Liefert den Paketmanager, falls `project` ein Projekt mit `vendor/`-Abhängigkeiten ist.
    static func vendorEcosystem(of project: URL) -> String? {
        let fm = FileManager.default
        return vendorMarkers.first { fm.fileExists(atPath: project.appendingPathComponent($0.file).path) }?.ecosystem
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
