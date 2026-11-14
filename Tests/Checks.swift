// ClearHub checks (scripts/check.sh): scan, size, deletion and Docker classification (images and volumes).
// Works only in temporary folders and never calls the docker CLI.
import Foundation

@main
enum Checks {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passed = 0

    static func check(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        if condition {
            passed += 1
        } else {
            failures += 1
            let extra = detail()
            print("✗ \(label)" + (extra.isEmpty ? "" : " – \(extra)"))
        }
    }

    static func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        check(actual == expected, label, "\(actual) ≠ \(expected)")
    }

    static func main() {
        scanner()
        vendorRules()
        deletionSafety()
        docker()
        dockerCalls()
        print("\(passed) Prüfungen bestanden, \(failures) fehlgeschlagen.")
        exit(failures == 0 ? 0 : 1)
    }

    static func temp(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clearhub-check-\(name)-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ root: URL, _ path: String, _ data: Data) {
        let url = root.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    // MARK: Scanner and Deleter

    static func scanner() {
        let root = temp("scan")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = { (path: String, bytes: Int) in write(root, path, Data(count: bytes)) }
        file("web/package.json", 1)
        file("web/yarn.lock", 1)
        file("web/node_modules/lodash/index.js", 10_000)
        file("web/node_modules/a/node_modules/b/x.js", 1)
        file("shop/composer.json", 1)
        file("shop/vendor/symfony/x.php", 5_000)
        file("shop/vendor/composer/installed.json", 1)
        file("site/assets/vendor/jquery.js", 1)   // no project file → no match
        file(".hidden/node_modules/x.js", 1)      // hidden folders are skipped

        func scan(_ kinds: Set<FolderKind>) -> [FoundFolder] {
            var found: [FoundFolder] = []
            var projects = DockerProjectIndex()
            Scanner.scan(roots: [root], kinds: kinds, dockerProjects: &projects, token: CancelToken(),
                         onFound: { found.append($0) }, onProgress: { _, _ in })
            return found.sorted { $0.url.path < $1.url.path }
        }

        var found = scan([.nodeModules, .vendor])
        equal(found.map(\.projectName), ["shop", "web"], "Only top-level folders")
        equal(found.map(\.kind), [.vendor, .nodeModules], "Kinds")
        equal(found.map(\.ecosystem), ["Composer", "Yarn"], "Package managers")
        equal(scan([.nodeModules]).map(\.kind), [.nodeModules], "Only node_modules")
        equal(scan([.vendor]).map(\.kind), [.vendor], "Only vendor")

        for i in found.indices {
            found[i].size = Scanner.size(of: found[i].url, token: CancelToken())
            check((found[i].size ?? 0) > 0, "Size of \(found[i].projectName)")
        }
        let result = Deleter.delete(found, mode: .permanent)
        equal(result.deleted.count, 2, "Deleted folders")
        check(result.failures.isEmpty, "No deletion failures", "\(result.failures)")
        let exists = { (path: String) in FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) }
        check(!exists("web/node_modules"), "node_modules is gone")
        check(exists("web/package.json") && exists("shop/composer.json"), "Project files stay")
        check(exists("site/assets/vendor/jquery.js"), "Unrelated vendor folder stays")
    }

    /// `vendor/` counts only if the package manager created it.
    static func vendorRules() {
        let root = temp("vendor")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = { (path: String) in write(root, path, Data(count: 1)) }
        file("rails/Gemfile")
        file("rails/vendor/bundle/ruby/3.3.0/gems/rack/lib/rack.rb")
        file("rails/vendor/javascript/stimulus.js")   // committed importmap pin
        file("gems/Gemfile")
        file("gems/vendor/bundle/ruby/3.3.0/gems/rack/lib/rack.rb")
        file("gems/vendor/.keep")
        file("goapp/go.mod")
        file("goapp/vendor/modules.txt")
        file("goapp/vendor/github.com/pkg/errors/errors.go")
        file("goold/go.mod")
        file("goold/vendor/lib.go")
        file("php/composer.json")
        file("php/vendor/handmade/lib.php")

        var found: [FoundFolder] = []
        var projects = DockerProjectIndex()
        Scanner.scan(roots: [root], kinds: [.vendor], dockerProjects: &projects, token: CancelToken(),
                     onFound: { found.append($0) }, onProgress: { _, _ in })
        found.sort { $0.url.path < $1.url.path }
        equal(found.map(\.projectName), ["gems", "goapp"], "vendor/ only where the package manager created it")
        equal(found.map(\.ecosystem), ["Bundler", "Go"], "vendor/ package managers")
    }

    /// Deletion never reaches beyond the folder itself.
    static func deletionSafety() {
        let root = temp("delete")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let outside = root.appendingPathComponent("outside")
        write(root, "outside/keep.txt", Data("keep".utf8))
        write(root, "web/package.json", Data())
        write(root, "web/node_modules/lodash/index.js", Data(count: 10))
        write(root, "swap/package.json", Data())
        write(root, "swap/node_modules/x/index.js", Data(count: 10))
        // npm/pnpm workspaces link packages into node_modules.
        let workspace = root.appendingPathComponent("web/node_modules/my-lib")
        try? fm.createSymbolicLink(at: workspace, withDestinationURL: outside)
        try? fm.createSymbolicLink(at: root.appendingPathComponent("web/node_modules/keep.txt"),
                                   withDestinationURL: outside.appendingPathComponent("keep.txt"))

        var found: [FoundFolder] = []
        var projects = DockerProjectIndex()
        Scanner.scan(roots: [root], kinds: [.nodeModules], dockerProjects: &projects, token: CancelToken(),
                     onFound: { found.append($0) }, onProgress: { _, _ in })
        found.sort { $0.url.path < $1.url.path }
        equal(found.map(\.projectName), ["swap", "web"], "Found before deletion")

        // swap/node_modules turns into a link after the scan.
        let swapped = root.appendingPathComponent("swap/node_modules")
        try? fm.removeItem(at: swapped)
        try? fm.createSymbolicLink(at: swapped, withDestinationURL: outside)

        let result = Deleter.delete(found, mode: .permanent)
        equal(result.deleted.map(\.lastPathComponent), ["node_modules"], "Only the real folder is deleted")
        equal(result.failures.count, 1, "A folder replaced by a link is skipped")
        check(!fm.fileExists(atPath: root.appendingPathComponent("web/node_modules").path), "Folder with links inside is gone")
        check(fm.fileExists(atPath: outside.appendingPathComponent("keep.txt").path), "Link targets outside survive")
        check((try? fm.destinationOfSymbolicLink(atPath: swapped.path)) != nil, "The link itself stays")

        let wrongName = FoundFolder(url: outside, kind: .nodeModules, ecosystem: "npm", modified: nil)
        let renamed = Deleter.delete([wrongName], mode: .permanent)
        check(renamed.deleted.isEmpty && renamed.failures.count == 1 && fm.fileExists(atPath: outside.path),
              "A folder with another name is never deleted")
    }

    // MARK: Docker

    static func docker() {
        let root = temp("docker")
        defer { try? FileManager.default.removeItem(at: root) }
        let text = { (path: String, content: String) in write(root, path, Data(content.utf8)) }
        // Compose project with its own build (shop-php) and registry images.
        text("Shop/compose.yaml", """
            services:
              php:
                build: .
              db:
                image: "mariadb:10.11" # database
              cache:
                image: redis
              app:
                image: ${APP_IMAGE}
            """)
        // DDEV project with its own site name.
        text("typo3-site/composer.json", "{}")
        text("typo3-site/.ddev/config.yaml", "name: sha-v13-spike\ntype: typo3\n")

        var projects = DockerProjectIndex()
        Scanner.scan(roots: [root], kinds: [], collectDockerProjects: true, dockerProjects: &projects,
                     token: CancelToken(), onFound: { _ in }, onProgress: { _, _ in })
        let ddevList = temp("ddev")
        defer { try? FileManager.default.removeItem(at: ddevList) }
        write(ddevList, "elsewhere/.ddev/config.yaml", Data("name: elsewhere\n".utf8))
        write(ddevList, "gone/README.md", Data())
        write(ddevList, "project_list.yaml", Data("""
            elsewhere:
                approot: \(ddevList.path)/elsewhere
            gone:
                approot: \(ddevList.path)/gone
            missing:
                approot: \(ddevList.path)/missing
            """.utf8))
        var withList = projects
        withList.addDDEVProjectList(ddevList.appendingPathComponent("project_list.yaml"))
        equal(withList.ddevSites.keys.sorted(), ["elsewhere", "sha-v13-spike"], "DDEV project list (only with config)")
        equal(projects.composeProjects.keys.sorted(), ["shop"], "Compose projects")
        equal(projects.imageRefs.keys.sorted(), ["mariadb:10.11", "redis:latest"], "Image references")
        equal(projects.ddevSites.keys.sorted(), ["sha-v13-spike"], "DDEV sites")

        equal(DockerProjectIndex.normalizedReference("nginx"), "nginx:latest", "Reference without tag")
        equal(DockerProjectIndex.normalizedReference("docker.io/library/nginx:1.27"), "nginx:1.27", "Reference with registry")
        equal(DockerProjectIndex.normalizedReference("localhost:5000/app"), "localhost:5000/app:latest", "Reference with port")

        equal(Docker.parseSize("408.2MB"), 408_200_000, "Size MB")
        equal(Docker.parseSize("9.557kB"), 9_557, "Size kB")
        equal(Docker.parseSize("1.325GB"), 1_325_000_000, "Size GB")
        equal(Docker.parseSize("512.3MB"), 512_300_000, "Size without float truncation")
        equal(Docker.parseSize("0B"), 0, "Size 0B")
        equal(Docker.parseSize("N/A"), 0, "Size N/A")

        let json = """
        {"Images":[
          {"Containers":"1","CreatedAt":"2026-10-22 17:06:28 +0200 CEST","ID":"sha256:aaaa111122223333","Repository":"ddev/ddev-webserver","Tag":"v1.25.2-other-built","SharedSize":"1GB","UniqueSize":"400MB","Size":"1.4GB"},
          {"Containers":"0","CreatedAt":"2026-10-22 16:19:05 +0200 CEST","ID":"sha256:bbbb111122223333","Repository":"<none>","Tag":"<none>","SharedSize":"1GB","UniqueSize":"394.3MB","Size":"1.4GB"},
          {"Containers":"0","CreatedAt":"2026-01-01 10:00:00 +0100 CET","ID":"sha256:cccc111122223333","Repository":"shop-php","Tag":"latest","SharedSize":"0B","UniqueSize":"200MB","Size":"200MB"},
          {"Containers":"0","CreatedAt":"2026-01-01 10:00:00 +0100 CET","ID":"sha256:dddd111122223333","Repository":"mariadb","Tag":"10.11","SharedSize":"0B","UniqueSize":"300MB","Size":"300MB"},
          {"Containers":"0","CreatedAt":"2026-01-01 10:00:00 +0100 CET","ID":"sha256:eeee111122223333","Repository":"ddev/ddev-webserver","Tag":"v1.25.2-sha-v13-spike-built","SharedSize":"1GB","UniqueSize":"10MB","Size":"1GB"},
          {"Containers":"0","CreatedAt":"2025-01-01 10:00:00 +0100 CET","ID":"sha256:ffff111122223333","Repository":"node","Tag":"18","SharedSize":"0B","UniqueSize":"1.1GB","Size":"1.1GB"}
        ],
        "Containers":[
          {"Image":"ddev/ddev-webserver:v1.25.2-other-built","State":"exited","Labels":"com.docker.compose.project=ddev-other,com.ddev.site-name=other","Mounts":"other-mariadb"},
          {"Image":"postgres:16","State":"running","Labels":"","Mounts":"bb01db83eb0d759a9b3982f7408cf0caedb91370197e8043e9fab7d74fb5046c,uploads"}
        ],
        "Volumes":[
          {"Name":"other-mariadb","Driver":"local","Labels":"com.docker.compose.project=ddev-other","Links":"1","Size":"100MB"},
          {"Name":"bb01db83eb0d759a9b3982f7408cf0caedb91370197e8043e9fab7d74fb5046c","Driver":"local","Labels":"","Links":"0","Size":"353.4MB"},
          {"Name":"uploads","Driver":"local","Labels":"","Links":"0","Size":"1MB"},
          {"Name":"aea140c231b40ecd783c8cc88490d3b7374c31f59b63787060a1b2c3d4e5f6a7","Driver":"local","Labels":"","Links":"0","Size":"260.3MB"},
          {"Name":"shop_db-data","Driver":"local","Labels":"com.docker.compose.project=shop,com.docker.compose.volume=db-data","Links":"0","Size":"512.3MB"},
          {"Name":"shop_legacy","Driver":"local","Labels":"","Links":"0","Size":"1kB"},
          {"Name":"sha-v13-spike-mariadb","Driver":"local","Labels":"com.docker.compose.project=ddev-sha-v13-spike","Links":"0","Size":"484.3MB"},
          {"Name":"sha-v13-spike_project_mutagen","Driver":"local","Labels":"","Links":"0","Size":"1.497GB"},
          {"Name":"ddev-global-cache","Driver":"local","Labels":"","Links":"0","Size":"643.8MB"},
          {"Name":"ddev-ssh-agent_dot_ssh","Driver":"local","Labels":"com.docker.compose.project=ddev-ssh-agent","Links":"0","Size":"0B"},
          {"Name":"partyausfall_db-data","Driver":"local","Labels":"com.docker.compose.project=partyausfall","Links":"0","Size":"512.3MB"},
          {"Name":"gone-mariadb","Driver":"local","Labels":"com.docker.compose.project=ddev-gone","Links":"0","Size":"5MB"},
          {"Name":"elsewhere-mariadb","Driver":"local","Labels":"com.docker.compose.project=ddev-elsewhere","Links":"0","Size":"5MB"},
          {"Name":"shop_project_mutagen","Driver":"local","Labels":"com.docker.compose.project=ddev-shop","Links":"0","Size":"1GB"},
          {"Name":"old-data","Driver":"local","Labels":"","Links":"0","Size":"N/A"}
        ],
        "BuildCache":[
          {"InUse":"false","Size":"2GB"},
          {"InUse":"true","Size":"5GB"}
        ]}
        """
        guard let inventory = try? Docker.parse(systemDF: Data(json.utf8), projects: withList) else {
            return check(false, "Parse docker system df")
        }
        let images = inventory.images
        let status = Dictionary(uniqueKeysWithValues: images.map { ($0.displayName, $0.status) })
        equal(status["ddev/ddev-webserver:v1.25.2-other-built"], .inUse(containers: 1, running: false, project: "ddev-other"), "In use")
        equal(status["<none>"], .dangling, "Dangling")
        equal(status["node:18"], .orphan, "Orphaned")
        if case .project(let shop, _) = status["shop-php:latest"],
           case .project(let db, _) = status["mariadb:10.11"],
           case .project(let ddev, _) = status["ddev/ddev-webserver:v1.25.2-sha-v13-spike-built"] {
            equal([shop, db, ddev], ["shop", "shop", "sha-v13-spike"], "Project images")
        } else {
            check(false, "Project images assigned", "\(status)")
        }
        equal(images.first { $0.status == .buildCache }?.uniqueSize, 2_000_000_000, "Only unused build cache counts")
        check(images.first?.created != nil, "Creation date parsed")

        let inUse = DockerImage(imageID: "sha256:x", repository: "a", tag: "b", created: nil, uniqueSize: 1, sharedSize: 0,
                                status: .inUse(containers: 1, running: true, project: nil))
        let result = Docker.delete([inUse])
        check(result.deletedImages.isEmpty && result.failures.isEmpty, "Images in use are never deleted (not even tried)")

        // Volumes
        let volumes = Dictionary(uniqueKeysWithValues: inventory.volumes.map { ($0.name, $0.status) })
        equal(volumes["other-mariadb"], .inUse(containers: 1, running: false, project: "ddev-other"), "Volume in use (Links)")
        equal(volumes["bb01db83eb0d759a9b3982f7408cf0caedb91370197e8043e9fab7d74fb5046c"], .inUse(containers: 1, running: true, project: nil),
              "Anonymous volume in use (Mounts)")
        equal(volumes["uploads"], .inUse(containers: 1, running: true, project: nil), "Named volume in use (Mounts only)")
        equal(volumes["aea140c231b40ecd783c8cc88490d3b7374c31f59b63787060a1b2c3d4e5f6a7"], .anonymous, "Anonymous volume without container")
        if case .project(let shopData, _) = volumes["shop_db-data"],
           case .project(let shopLegacy, _) = volumes["shop_legacy"],
           case .project(let ddevDB, _) = volumes["sha-v13-spike-mariadb"],
           case .project(let mutagen, _) = volumes["sha-v13-spike_project_mutagen"] {
            equal([shopData, shopLegacy, ddevDB, mutagen], ["shop", "shop", "sha-v13-spike", "sha-v13-spike"], "Project volumes")
        } else {
            check(false, "Project volumes assigned", "\(volumes)")
        }
        equal(volumes["ddev-global-cache"], .tool(name: "DDEV"), "DDEV global cache")
        equal(volumes["ddev-ssh-agent_dot_ssh"], .tool(name: "DDEV"), "DDEV SSH agent")
        equal(volumes["partyausfall_db-data"], .missingProject(name: "partyausfall"), "Volume of a Compose project not found")
        equal(volumes["gone-mariadb"], .orphan(ddevSite: "gone"), "Volume of a DDEV project DDEV no longer knows")
        equal(volumes["old-data"], .orphan(ddevSite: nil), "Orphaned volume")
        equal(volumes["shop_project_mutagen"], .orphan(ddevSite: "shop"), "Label wins over a similar Compose project name")
        equal(inventory.volumes.first { $0.name == "old-data" }?.size, 0, "Volume size N/A")
        equal(inventory.volumes.first { $0.name == "shop_db-data" }?.size, 512_300_000, "Volume size")
        equal(inventory.volumes.filter(\.status.isOrphaned).map(\.name).sorted(),
              ["aea140c231b40ecd783c8cc88490d3b7374c31f59b63787060a1b2c3d4e5f6a7", "gone-mariadb", "old-data", "shop_project_mutagen"],
              "Mark orphaned picks only anonymous and orphaned volumes")
        if case .project(let elsewhere, _) = volumes["elsewhere-mariadb"] {
            equal(elsewhere, "elsewhere", "DDEV project outside the search locations")
        } else {
            check(false, "DDEV project list read", "\(String(describing: volumes["elsewhere-mariadb"]))")
        }

        let locked = inventory.volumes.filter { !$0.status.isDeletable }
        equal(locked.count, 8, "Volumes in use or owned by a project are locked")
        let volumeResult = Docker.delete(locked)
        check(volumeResult.deletedVolumes.isEmpty && volumeResult.failures.isEmpty, "Locked volumes are never deleted (not even tried)")
    }

    /// Process handling, error texts and values from Docker output – with /bin tools instead of docker.
    static func dockerCalls() {
        let refusal = "Error response from daemon: remove uploads: volume is in use - [4f2a]"
        equal(DockerError.failed(refusal).errorDescription, refusal, "A daemon refusal is shown as it is")
        let down = [
            "Cannot connect to the Docker daemon at unix:///Users/x/.docker/run/docker.sock. Is the docker daemon running?",
            "failed to connect to the docker API at unix:///var/run/docker.sock; check if the path is correct and if the daemon is running",
        ]
        check(down.allSatisfy { DockerError.failed($0).errorDescription?.hasPrefix("Docker läuft nicht") == true }, "Daemon not running")

        equal([Docker.parseSize("infMB"), Docker.parseSize("nanGB"), Docker.parseSize("-5MB"), Docker.parseSize("1e30TB")],
              [0, 0, 0, 0], "Unreal sizes count as 0 instead of trapping")
        equal(["sha256:4f2a", "nginx:1.27", "shop_db-data", "-f", "--force", "", "a b"].map(Docker.isSafeArgument),
              [true, true, true, false, false, false, false], "Only plain names reach the docker CLI")

        let start = Date()
        do {
            _ = try Docker.execute(URL(fileURLWithPath: "/bin/sleep"), ["30"], timeout: 0.5)
            check(false, "A hanging call is stopped")
        } catch {
            check({ if case DockerError.timedOut = error { true } else { false } }(), "A hanging call is stopped", "\(error)")
        }
        check(Date().timeIntervalSince(start) < 5, "… after its time limit")

        // 300 kB on both pipes: reading them one after the other would block for good.
        let both = try? Docker.execute(URL(fileURLWithPath: "/bin/sh"),
                                       ["-c", "head -c 300000 /dev/zero >&2; head -c 300000 /dev/zero"], timeout: 20)
        equal(both?.count, 300_000, "Large output on stdout and stderr")

        do {
            _ = try Docker.execute(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo '\(refusal)' >&2; exit 1"], timeout: 20)
            check(false, "Failure reported")
        } catch {
            equal(error.localizedDescription, refusal, "Failure reported with its message")
        }
    }
}
