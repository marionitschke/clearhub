import XCTest
@testable import ClearHubCore

final class DockerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("clearhub-docker-\(UUID().uuidString)")
        // Compose-Projekt: eigener Build (shop-php) und ein Registry-Image
        try write("Shop/compose.yaml", """
            services:
              php:
                build: .
              db:
                image: "mariadb:10.11" # Datenbank
              cache:
                image: redis
              app:
                image: ${APP_IMAGE}
            """)
        // DDEV-Projekt mit eigenem Sitenamen
        try write("typo3-site/composer.json", "{}")
        try write("typo3-site/.ddev/config.yaml", "name: sha-v13-spike\ntype: typo3\n")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func scanProjects() -> DockerProjectIndex {
        var projects = DockerProjectIndex()
        Scanner.scan(roots: [root], kinds: [], collectDockerProjects: true, dockerProjects: &projects,
                     token: CancelToken(), onFound: { _ in }, onProgress: { _, _ in })
        return projects
    }

    func testScannerCollectsComposeAndDDEV() {
        let projects = scanProjects()
        XCTAssertEqual(projects.composeProjects.keys.sorted(), ["shop"])
        XCTAssertEqual(projects.imageRefs.keys.sorted(), ["mariadb:10.11", "redis:latest"])
        XCTAssertEqual(projects.ddevSites.keys.sorted(), ["sha-v13-spike"])
    }

    func testNormalizedReference() {
        XCTAssertEqual(DockerProjectIndex.normalizedReference("nginx"), "nginx:latest")
        XCTAssertEqual(DockerProjectIndex.normalizedReference("docker.io/library/nginx:1.27"), "nginx:1.27")
        XCTAssertEqual(DockerProjectIndex.normalizedReference("localhost:5000/app"), "localhost:5000/app:latest")
    }

    func testParseSize() {
        XCTAssertEqual(Docker.parseSize("408.2MB"), 408_200_000)
        XCTAssertEqual(Docker.parseSize("9.557kB"), 9_557)
        XCTAssertEqual(Docker.parseSize("1.325GB"), 1_325_000_000)
        XCTAssertEqual(Docker.parseSize("0B"), 0)
        XCTAssertEqual(Docker.parseSize("N/A"), 0)
    }

    func testClassification() throws {
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
          {"Image":"ddev/ddev-webserver:v1.25.2-other-built","State":"exited","Labels":"com.docker.compose.project=ddev-other,com.ddev.site-name=other"}
        ],
        "BuildCache":[
          {"InUse":"false","Size":"2GB"},
          {"InUse":"true","Size":"5GB"}
        ]}
        """
        let images = try Docker.parse(systemDF: Data(json.utf8), projects: scanProjects())
        let status = Dictionary(uniqueKeysWithValues: images.map { ($0.displayName, $0.status) })

        XCTAssertEqual(status["ddev/ddev-webserver:v1.25.2-other-built"], .inUse(containers: 1, running: false, project: "ddev-other"))
        XCTAssertEqual(status["<none>"], .dangling)
        XCTAssertEqual(status["node:18"], .orphan)
        guard case .project(let shop, _) = status["shop-php:latest"],
              case .project(let db, _) = status["mariadb:10.11"],
              case .project(let ddev, _) = status["ddev/ddev-webserver:v1.25.2-sha-v13-spike-built"]
        else { return XCTFail("Projekt-Images nicht zugeordnet: \(status)") }
        XCTAssertEqual([shop, db, ddev], ["shop", "shop", "sha-v13-spike"])

        let cache = try XCTUnwrap(images.first { $0.status == .buildCache })
        XCTAssertEqual(cache.uniqueSize, 2_000_000_000, "Nur ungenutzter Cache zählt")
        XCTAssertNotNil(images.first?.created)
    }

    func testInUseImagesAreNeverDeleted() {
        let image = DockerImage(imageID: "sha256:x", repository: "a", tag: "b", created: nil, uniqueSize: 1, sharedSize: 0,
                                status: .inUse(containers: 1, running: true, project: nil))
        let result = Docker.delete([image])
        XCTAssertTrue(result.deletedImages.isEmpty)
        XCTAssertTrue(result.failures.isEmpty, "Gar nicht erst versucht")
    }
}
