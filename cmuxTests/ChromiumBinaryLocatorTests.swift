import XCTest
@testable import cmux

final class ChromiumBinaryLocatorTests: XCTestCase {

    private struct FakeFS: ChromiumFileSystem {
        var files: Set<String> = []
        var executables: Set<String> = []
        var directoryContents: [URL: [URL]] = [:]
        var home: URL = URL(fileURLWithPath: "/Users/fake")

        func fileExists(atPath path: String) -> Bool { files.contains(path) }
        func isExecutableFile(atPath path: String) -> Bool { executables.contains(path) }
        func contentsOfDirectory(at url: URL) throws -> [URL] {
            directoryContents[url] ?? []
        }
        func homeDirectory() -> URL { home }
    }

    func test_envOverrideTakesPrecedence() throws {
        var fs = FakeFS()
        let override = "/opt/custom/Chromium"
        fs.files.insert(override)
        fs.executables.insert(override)

        let locator = ChromiumBinaryLocator(fs: fs, env: ["CMUX_CHROMIUM_PATH": override])
        let found = try locator.locate()
        XCTAssertEqual(found.path, override)
        XCTAssertEqual(found.source, .envOverride)
    }

    func test_envOverrideMissingFallsThrough() throws {
        var fs = FakeFS()
        let playwright = "/Users/fake/Library/Caches/ms-playwright/chromium-1134/chrome-mac/Chromium.app/Contents/MacOS/Chromium"
        fs.files.insert(playwright)
        fs.executables.insert(playwright)
        fs.directoryContents[URL(fileURLWithPath: "/Users/fake/Library/Caches/ms-playwright")] = [
            URL(fileURLWithPath: "/Users/fake/Library/Caches/ms-playwright/chromium-1134")
        ]

        let locator = ChromiumBinaryLocator(fs: fs, env: ["CMUX_CHROMIUM_PATH": "/nope"])
        let found = try locator.locate()
        XCTAssertEqual(found.path, playwright)
        XCTAssertEqual(found.source, .playwrightCache)
    }

    func test_picksHighestPlaywrightRevision() throws {
        var fs = FakeFS()
        let older = "/Users/fake/Library/Caches/ms-playwright/chromium-900/chrome-mac/Chromium.app/Contents/MacOS/Chromium"
        let newer = "/Users/fake/Library/Caches/ms-playwright/chromium-1134/chrome-mac/Chromium.app/Contents/MacOS/Chromium"
        fs.files = [older, newer]
        fs.executables = [older, newer]
        fs.directoryContents[URL(fileURLWithPath: "/Users/fake/Library/Caches/ms-playwright")] = [
            URL(fileURLWithPath: "/Users/fake/Library/Caches/ms-playwright/chromium-900"),
            URL(fileURLWithPath: "/Users/fake/Library/Caches/ms-playwright/chromium-1134"),
        ]

        let locator = ChromiumBinaryLocator(fs: fs, env: [:])
        let found = try locator.locate()
        XCTAssertEqual(found.path, newer)
    }

    func test_skipsHeadlessShell() throws {
        var fs = FakeFS()
        let shell = "/Users/fake/Library/Caches/ms-playwright/chromium_headless_shell-1134/chrome-mac/headless_shell"
        fs.files.insert(shell)
        fs.executables.insert(shell)
        fs.directoryContents[URL(fileURLWithPath: "/Users/fake/Library/Caches/ms-playwright")] = [
            URL(fileURLWithPath: "/Users/fake/Library/Caches/ms-playwright/chromium_headless_shell-1134")
        ]

        let locator = ChromiumBinaryLocator(fs: fs, env: [:])
        XCTAssertThrowsError(try locator.locate()) { error in
            guard case ChromiumBinaryLocator.LocateError.notFound = error else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
    }

    func test_fallsBackToSystemChrome() throws {
        var fs = FakeFS()
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        fs.files.insert(chrome)
        fs.executables.insert(chrome)
        let locator = ChromiumBinaryLocator(fs: fs, env: [:])
        let found = try locator.locate()
        XCTAssertEqual(found.path, chrome)
        XCTAssertEqual(found.source, .systemChrome)
    }

    func test_envOverrideExistsButNotExecutableFallsThrough() throws {
        var fs = FakeFS()
        let overridePath = "/opt/not-executable/Chromium"
        fs.files.insert(overridePath)
        // Deliberately omit from `executables`.
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        fs.files.insert(chrome)
        fs.executables.insert(chrome)

        let locator = ChromiumBinaryLocator(fs: fs, env: ["CMUX_CHROMIUM_PATH": overridePath])
        let found = try locator.locate()
        XCTAssertEqual(found.source, .systemChrome)
    }

    func test_playwrightCacheListingThrowsFallsThroughToSystem() throws {
        struct ThrowingFS: ChromiumFileSystem {
            let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
            func fileExists(atPath path: String) -> Bool { path == chrome }
            func isExecutableFile(atPath path: String) -> Bool { path == chrome }
            func contentsOfDirectory(at url: URL) throws -> [URL] {
                throw CocoaError(.fileReadUnknown)
            }
            func homeDirectory() -> URL { URL(fileURLWithPath: "/Users/fake") }
        }
        let locator = ChromiumBinaryLocator(fs: ThrowingFS(), env: [:])
        let found = try locator.locate()
        XCTAssertEqual(found.source, .systemChrome)
    }

    func test_fallsBackToSystemChromiumWhenChromeMissing() throws {
        var fs = FakeFS()
        let chromium = "/Applications/Chromium.app/Contents/MacOS/Chromium"
        fs.files.insert(chromium)
        fs.executables.insert(chromium)
        let locator = ChromiumBinaryLocator(fs: fs, env: [:])
        let found = try locator.locate()
        XCTAssertEqual(found.path, chromium)
        XCTAssertEqual(found.source, .systemChromium)
    }
}
