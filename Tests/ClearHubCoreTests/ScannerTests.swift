import XCTest
@testable import ClearHubCore

final class ScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("clearhub-\(UUID().uuidString)")
        // web: Node-Projekt mit verschachteltem node_modules
        try make("web/package.json")
        try make("web/yarn.lock")
        try make("web/node_modules/lodash/index.js", bytes: 10_000)
        try make("web/node_modules/a/node_modules/b/x.js")
        // shop: Composer-Projekt mit vendor
        try make("shop/composer.json")
        try make("shop/vendor/symfony/x.php", bytes: 5_000)
        // assets/vendor ohne Projektdatei → kein Treffer
        try make("site/assets/vendor/jquery.js")
        // versteckte Ordner werden ignoriert
        try make(".hidden/node_modules/x.js")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func make(_ path: String, bytes: Int = 1) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    private func scan(_ kinds: Set<FolderKind>) -> [FoundFolder] {
        var found: [FoundFolder] = []
        var projects = DockerProjectIndex()
        Scanner.scan(roots: [root], kinds: kinds, dockerProjects: &projects, token: CancelToken(), onFound: { found.append($0) }, onProgress: { _, _ in })
        return found.sorted { $0.url.path < $1.url.path }
    }

    func testFindsTopLevelFoldersOnly() {
        let found = scan([.nodeModules, .vendor])
        XCTAssertEqual(found.map(\.projectName), ["shop", "web"])
        XCTAssertEqual(found.map(\.kind), [.vendor, .nodeModules])
        XCTAssertEqual(found.map(\.ecosystem), ["Composer", "Yarn"])
    }

    func testRespectsKindSelection() {
        XCTAssertEqual(scan([.nodeModules]).map(\.kind), [.nodeModules])
        XCTAssertEqual(scan([.vendor]).map(\.kind), [.vendor])
    }

    func testSizeAndDelete() throws {
        var folders = scan([.nodeModules, .vendor])
        for i in folders.indices {
            folders[i].size = Scanner.size(of: folders[i].url, token: CancelToken())
            XCTAssertGreaterThan(folders[i].size ?? 0, 0)
        }

        let result = Deleter.delete(folders, mode: .permanent)
        XCTAssertEqual(result.deleted.count, 2)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("web/node_modules").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("web/package.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("shop/composer.json").path))
    }
}
