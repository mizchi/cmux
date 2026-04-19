# browserCDP Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a Debug-menu entry that locates Chromium, spawns it with a remote-debugging port, parses `DevToolsActivePort`, and surfaces the `ws://127.0.0.1:<port>/devtools/browser/<id>` URL (via debug log + NSPasteboard). This is the first ship-able slice of the browserCDP panel spec.

**Architecture:** Three focused files under `Sources/Panels/BrowserCDPLaunch/` — a binary locator (no IO in logic, pure path resolution over a stubable filesystem), a port watcher (DispatchSource over a file), a launch manager that composes them with `Process`. Swift XCTest coverage with real temp dirs + fake filesystems. Chromium itself is NOT launched during tests — it's invoked only from the Debug menu handler. A `ChromiumFileSystem` protocol lets us fake the filesystem in unit tests without touching real Playwright caches.

**Tech Stack:** Swift, AppKit, XCTest. No new dependencies. macOS only.

---

## Files

- Create: `Sources/Panels/BrowserCDPLaunch/ChromiumFileSystem.swift` — tiny filesystem protocol for testability
- Create: `Sources/Panels/BrowserCDPLaunch/ChromiumBinaryLocator.swift` — pure path resolution
- Create: `Sources/Panels/BrowserCDPLaunch/ChromiumDevToolsPortWatcher.swift` — tail `DevToolsActivePort`
- Create: `Sources/Panels/BrowserCDPLaunch/ChromiumLaunchManager.swift` — spawn + lifecycle
- Create: `cmuxTests/ChromiumBinaryLocatorTests.swift`
- Create: `cmuxTests/ChromiumDevToolsPortWatcherTests.swift`
- Create: `cmuxTests/ChromiumLaunchManagerTests.swift`
- Modify: `Sources/cmuxApp.swift` near line 523 (end of the "Debug Windows" menu) — add a "Launch Chromium (CDP)…" button
- Modify: `GhosttyTabs.xcodeproj/project.pbxproj` — add the four new Sources files and three test files to their targets

After adding files, run `./scripts/reload.sh --tag browser-cdp-phase1` to verify the Debug build compiles end-to-end.

---

## Task 1: ChromiumFileSystem protocol

**Files:**
- Create: `Sources/Panels/BrowserCDPLaunch/ChromiumFileSystem.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation

protocol ChromiumFileSystem {
    func fileExists(atPath path: String) -> Bool
    func isExecutableFile(atPath path: String) -> Bool
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func homeDirectory() -> URL
}

struct RealChromiumFileSystem: ChromiumFileSystem {
    func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func isExecutableFile(atPath path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
    }

    func homeDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/Panels/BrowserCDPLaunch/ChromiumFileSystem.swift
git commit -m "Add ChromiumFileSystem protocol for locator testability"
```

Note: No tests for this task on its own — it's a thin wrapper. Tests cover it through `ChromiumBinaryLocatorTests`.

---

## Task 2: ChromiumBinaryLocator — failing tests first

**Files:**
- Test: `cmuxTests/ChromiumBinaryLocatorTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
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
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run (CI only per CLAUDE.md — do not run locally; this step is for documentation):

```bash
xcodebuild -scheme cmux-unit -destination 'platform=macOS' \
  -only-testing:cmuxTests/ChromiumBinaryLocatorTests test
```

Expected: compile failure — `ChromiumBinaryLocator` unresolved.

- [ ] **Step 3: Commit the failing test**

```bash
git add cmuxTests/ChromiumBinaryLocatorTests.swift
git commit -m "Add failing ChromiumBinaryLocator tests"
```

---

## Task 3: ChromiumBinaryLocator implementation

**Files:**
- Create: `Sources/Panels/BrowserCDPLaunch/ChromiumBinaryLocator.swift`

- [ ] **Step 1: Write implementation**

```swift
import Foundation

struct ChromiumBinary: Equatable {
    enum Source: String {
        case envOverride
        case playwrightCache
        case systemChrome
        case systemChromium
    }
    let path: String
    let source: Source
}

struct ChromiumBinaryLocator {
    enum LocateError: Error, CustomStringConvertible {
        case notFound
        var description: String {
            "No Chromium binary found. Set CMUX_CHROMIUM_PATH or run `npx playwright install chromium`."
        }
    }

    let fs: ChromiumFileSystem
    let env: [String: String]

    init(fs: ChromiumFileSystem = RealChromiumFileSystem(), env: [String: String] = ProcessInfo.processInfo.environment) {
        self.fs = fs
        self.env = env
    }

    func locate() throws -> ChromiumBinary {
        if let path = env["CMUX_CHROMIUM_PATH"], isValid(path) {
            return ChromiumBinary(path: path, source: .envOverride)
        }
        if let playwright = highestPlaywrightChromium() {
            return ChromiumBinary(path: playwright, source: .playwrightCache)
        }
        let systemChrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        if isValid(systemChrome) {
            return ChromiumBinary(path: systemChrome, source: .systemChrome)
        }
        let systemChromium = "/Applications/Chromium.app/Contents/MacOS/Chromium"
        if isValid(systemChromium) {
            return ChromiumBinary(path: systemChromium, source: .systemChromium)
        }
        throw LocateError.notFound
    }

    private func isValid(_ path: String) -> Bool {
        fs.fileExists(atPath: path) && fs.isExecutableFile(atPath: path)
    }

    private func highestPlaywrightChromium() -> String? {
        let root = fs.homeDirectory()
            .appendingPathComponent("Library/Caches/ms-playwright")
        let entries: [URL]
        do {
            entries = try fs.contentsOfDirectory(at: root)
        } catch {
            return nil
        }

        struct Candidate { let revision: Int; let path: String }
        var candidates: [Candidate] = []
        for entry in entries {
            let name = entry.lastPathComponent
            // Exclude headless-shell builds (CDP requires real Chromium).
            guard name.hasPrefix("chromium-") else { continue }
            let revisionPart = name.dropFirst("chromium-".count)
            guard let revision = Int(revisionPart) else { continue }
            let binary = entry
                .appendingPathComponent("chrome-mac/Chromium.app/Contents/MacOS/Chromium")
                .path
            if isValid(binary) {
                candidates.append(Candidate(revision: revision, path: binary))
            }
        }
        return candidates.max(by: { $0.revision < $1.revision })?.path
    }
}
```

- [ ] **Step 2: Run tests to verify they pass**

Expected: All 5 tests PASS. (CI run — not local.)

- [ ] **Step 3: Commit**

```bash
git add Sources/Panels/BrowserCDPLaunch/ChromiumBinaryLocator.swift
git commit -m "Add ChromiumBinaryLocator with env override + Playwright cache + system fallback"
```

---

## Task 4: ChromiumDevToolsPortWatcher — failing tests

**Files:**
- Test: `cmuxTests/ChromiumDevToolsPortWatcherTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import cmux

final class ChromiumDevToolsPortWatcherTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func test_resolvesWhenFilePresentAlready() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("DevToolsActivePort")
        try "54321\n/devtools/browser/abc-123\n".write(to: file, atomically: true, encoding: .utf8)

        let watcher = ChromiumDevToolsPortWatcher(userDataDir: dir)
        let expectation = XCTestExpectation(description: "resolved")
        var received: ChromiumDevToolsEndpoint?
        watcher.start(timeout: 2) { result in
            if case .success(let endpoint) = result {
                received = endpoint
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3)
        XCTAssertEqual(received?.port, 54321)
        XCTAssertEqual(received?.browserPath, "/devtools/browser/abc-123")
        XCTAssertEqual(received?.webSocketURL.absoluteString, "ws://127.0.0.1:54321/devtools/browser/abc-123")
    }

    func test_resolvesWhenFileAppearsLater() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("DevToolsActivePort")

        let watcher = ChromiumDevToolsPortWatcher(userDataDir: dir)
        let expectation = XCTestExpectation(description: "resolved")
        var received: ChromiumDevToolsEndpoint?
        watcher.start(timeout: 5) { result in
            if case .success(let endpoint) = result {
                received = endpoint
            }
            expectation.fulfill()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            try? "41234\n/devtools/browser/xyz-9\n".write(to: file, atomically: true, encoding: .utf8)
        }
        wait(for: [expectation], timeout: 6)
        XCTAssertEqual(received?.port, 41234)
    }

    func test_timeoutProducesError() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let watcher = ChromiumDevToolsPortWatcher(userDataDir: dir)
        let expectation = XCTestExpectation(description: "timed out")
        var receivedError: Error?
        watcher.start(timeout: 0.3) { result in
            if case .failure(let error) = result {
                receivedError = error
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        XCTAssertTrue(receivedError is ChromiumDevToolsPortWatcher.WatcherError)
    }

    func test_rejectsMalformedFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("DevToolsActivePort")
        try "not a port\n".write(to: file, atomically: true, encoding: .utf8)

        let watcher = ChromiumDevToolsPortWatcher(userDataDir: dir)
        let expectation = XCTestExpectation(description: "error")
        var receivedError: Error?
        watcher.start(timeout: 1) { result in
            if case .failure(let error) = result {
                receivedError = error
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        XCTAssertTrue(receivedError is ChromiumDevToolsPortWatcher.WatcherError)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: compile failure — `ChromiumDevToolsPortWatcher` unresolved.

- [ ] **Step 3: Commit**

```bash
git add cmuxTests/ChromiumDevToolsPortWatcherTests.swift
git commit -m "Add failing ChromiumDevToolsPortWatcher tests"
```

---

## Task 5: ChromiumDevToolsPortWatcher implementation

**Files:**
- Create: `Sources/Panels/BrowserCDPLaunch/ChromiumDevToolsPortWatcher.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation

struct ChromiumDevToolsEndpoint: Equatable {
    let port: UInt16
    let browserPath: String
    var webSocketURL: URL {
        URL(string: "ws://127.0.0.1:\(port)\(browserPath)")!
    }
}

final class ChromiumDevToolsPortWatcher {
    enum WatcherError: Error, CustomStringConvertible {
        case timedOut
        case malformedFile(String)
        var description: String {
            switch self {
            case .timedOut: return "Timed out waiting for DevToolsActivePort"
            case .malformedFile(let raw): return "DevToolsActivePort malformed: \(raw)"
            }
        }
    }

    private let userDataDir: URL
    private let queue = DispatchQueue(label: "cmux.chromium.portwatcher")
    private var dispatchSource: DispatchSourceFileSystemObject?
    private var timeoutSource: DispatchSourceTimer?
    private var didFire = false

    init(userDataDir: URL) {
        self.userDataDir = userDataDir
    }

    func start(timeout: TimeInterval, completion: @escaping (Result<ChromiumDevToolsEndpoint, Error>) -> Void) {
        let file = userDataDir.appendingPathComponent("DevToolsActivePort")

        queue.async { [weak self] in
            guard let self else { return }
            if self.tryRead(file: file, completion: completion) { return }
            self.installDirectoryWatch(file: file, timeout: timeout, completion: completion)
        }
    }

    func cancel() {
        queue.async { [weak self] in
            self?.tearDown()
        }
    }

    private func installDirectoryWatch(file: URL, timeout: TimeInterval, completion: @escaping (Result<ChromiumDevToolsEndpoint, Error>) -> Void) {
        let fd = open(userDataDir.path, O_EVTONLY)
        if fd < 0 {
            fire(.failure(WatcherError.malformedFile("cannot watch \(userDataDir.path)")), completion: completion)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            _ = self.tryRead(file: file, completion: completion)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        dispatchSource = source

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in
            self?.fire(.failure(WatcherError.timedOut), completion: completion)
        }
        timer.resume()
        timeoutSource = timer
    }

    private func tryRead(file: URL, completion: @escaping (Result<ChromiumDevToolsEndpoint, Error>) -> Void) -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return false }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= 2,
              let port = UInt16(lines[0]),
              lines[1].hasPrefix("/devtools/") else {
            // Might be a partial write; wait for the next event unless clearly invalid.
            if lines.count == 1 && UInt16(lines[0]) == nil {
                fire(.failure(WatcherError.malformedFile(raw)), completion: completion)
                return true
            }
            return false
        }
        let endpoint = ChromiumDevToolsEndpoint(port: port, browserPath: String(lines[1]))
        fire(.success(endpoint), completion: completion)
        return true
    }

    private func fire(_ result: Result<ChromiumDevToolsEndpoint, Error>, completion: @escaping (Result<ChromiumDevToolsEndpoint, Error>) -> Void) {
        guard !didFire else { return }
        didFire = true
        tearDown()
        DispatchQueue.main.async { completion(result) }
    }

    private func tearDown() {
        dispatchSource?.cancel()
        dispatchSource = nil
        timeoutSource?.cancel()
        timeoutSource = nil
    }
}
```

- [ ] **Step 2: Run tests to verify they pass**

Expected: 4 tests PASS.

- [ ] **Step 3: Commit**

```bash
git add Sources/Panels/BrowserCDPLaunch/ChromiumDevToolsPortWatcher.swift
git commit -m "Add ChromiumDevToolsPortWatcher tailing DevToolsActivePort"
```

---

## Task 6: ChromiumLaunchManager — failing tests

**Files:**
- Test: `cmuxTests/ChromiumLaunchManagerTests.swift`

The launch manager drives a real subprocess, so its tests use a stand-in shell script that writes a valid `DevToolsActivePort` and then waits — mirroring the Chromium behavior we care about for port discovery, without launching Chromium.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import cmux

final class ChromiumLaunchManagerTests: XCTestCase {

    // Fake "chromium" script: writes DevToolsActivePort to the dir passed as --user-data-dir=, then sleeps until killed.
    private func makeFakeChromium(dir: URL) throws -> URL {
        let script = dir.appendingPathComponent("fake-chromium.sh")
        let body = """
        #!/bin/bash
        set -eu
        USER_DATA=""
        for arg in "$@"; do
          case "$arg" in
            --user-data-dir=*) USER_DATA="${arg#--user-data-dir=}";;
          esac
        done
        if [ -z "$USER_DATA" ]; then exit 2; fi
        mkdir -p "$USER_DATA"
        printf '48123\\n/devtools/browser/fake-id\\n' > "$USER_DATA/DevToolsActivePort"
        # `exec sleep` so SIGTERM from Process.terminate() kills the real foreground
        # process instead of waiting for bash's current `sleep` child to return.
        exec sleep 3600
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        var attrs = try FileManager.default.attributesOfItem(atPath: script.path)
        attrs[.posixPermissions] = 0o755
        try FileManager.default.setAttributes(attrs, ofItemAtPath: script.path)
        return script
    }

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-launch-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func test_launchResolvesWithCDPEndpoint() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = try makeFakeChromium(dir: dir)
        let binary = ChromiumBinary(path: fake.path, source: .envOverride)
        let manager = ChromiumLaunchManager(binary: binary)
        let exp = XCTestExpectation(description: "launched")
        var endpoint: ChromiumDevToolsEndpoint?
        manager.launch(initialURL: nil, timeout: 3) { result in
            if case .success(let e) = result { endpoint = e }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        manager.terminate()
        XCTAssertEqual(endpoint?.port, 48123)
        XCTAssertEqual(endpoint?.webSocketURL.absoluteString, "ws://127.0.0.1:48123/devtools/browser/fake-id")
    }

    func test_terminateKillsProcessAndCleansUserDataDir() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = try makeFakeChromium(dir: dir)
        let binary = ChromiumBinary(path: fake.path, source: .envOverride)
        let manager = ChromiumLaunchManager(binary: binary)
        let exp = XCTestExpectation(description: "launched")
        manager.launch(initialURL: nil, timeout: 3) { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)

        guard let userDataDir = manager.userDataDirForTesting else {
            return XCTFail("user-data-dir not recorded")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: userDataDir.path))
        manager.terminate()
        // Terminate is async; poll briefly.
        let deadline = Date().addingTimeInterval(3)
        while FileManager.default.fileExists(atPath: userDataDir.path) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: userDataDir.path))
    }
}
```

- [ ] **Step 2: Run tests — expect compile failure**

Expected: `ChromiumLaunchManager` unresolved.

- [ ] **Step 3: Commit**

```bash
git add cmuxTests/ChromiumLaunchManagerTests.swift
git commit -m "Add failing ChromiumLaunchManager tests with fake-chromium script"
```

---

## Task 7: ChromiumLaunchManager implementation

**Files:**
- Create: `Sources/Panels/BrowserCDPLaunch/ChromiumLaunchManager.swift`

- [ ] **Step 1: Write implementation**

```swift
import Foundation

final class ChromiumLaunchManager {
    private let binary: ChromiumBinary
    private var process: Process?
    private var watcher: ChromiumDevToolsPortWatcher?
    private(set) var userDataDir: URL?

    // Test-only accessor
    var userDataDirForTesting: URL? { userDataDir }

    init(binary: ChromiumBinary) {
        self.binary = binary
    }

    func launch(initialURL: URL?, timeout: TimeInterval, completion: @escaping (Result<ChromiumDevToolsEndpoint, Error>) -> Void) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-chromium-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return DispatchQueue.main.async { completion(.failure(error)) }
        }
        userDataDir = dir

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary.path)
        var args = [
            "--remote-debugging-port=0",
            "--user-data-dir=\(dir.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--remote-allow-origins=*",
        ]
        if let initialURL { args.append(initialURL.absoluteString) }
        proc.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do {
            try proc.run()
        } catch {
            cleanupUserDataDir()
            return DispatchQueue.main.async { completion(.failure(error)) }
        }
        self.process = proc

        let w = ChromiumDevToolsPortWatcher(userDataDir: dir)
        self.watcher = w
        w.start(timeout: timeout) { [weak self] result in
            if case .failure = result {
                self?.terminate()
            }
            completion(result)
        }
    }

    func terminate() {
        if let proc = process, proc.isRunning {
            proc.terminate()
            proc.waitUntilExit()
        }
        process = nil
        watcher?.cancel()
        watcher = nil
        cleanupUserDataDir()
    }

    private func cleanupUserDataDir() {
        if let dir = userDataDir {
            try? FileManager.default.removeItem(at: dir)
        }
        userDataDir = nil
    }
}
```

- [ ] **Step 2: Run tests**

Expected: both pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/Panels/BrowserCDPLaunch/ChromiumLaunchManager.swift
git commit -m "Add ChromiumLaunchManager spawning real chromium process"
```

---

## Task 8: Xcode project wiring

**Files:**
- Modify: `GhosttyTabs.xcodeproj/project.pbxproj`

The four Sources files and three test files must be added to targets `cmux` and `cmuxTests` respectively. Do this via Xcode GUI (File → Add Files to "cmux"…) because hand-editing `project.pbxproj` is error-prone. The alternative is XcodeGen / Tuist, neither of which this repo uses.

- [ ] **Step 1: Add sources to `cmux` target**

Open `GhosttyTabs.xcodeproj` in Xcode. Right-click the `Panels` group, choose "Add Files to cmux…", and add:
- `Sources/Panels/BrowserCDPLaunch/ChromiumFileSystem.swift`
- `Sources/Panels/BrowserCDPLaunch/ChromiumBinaryLocator.swift`
- `Sources/Panels/BrowserCDPLaunch/ChromiumDevToolsPortWatcher.swift`
- `Sources/Panels/BrowserCDPLaunch/ChromiumLaunchManager.swift`

Ensure "Create groups" is selected and only the `cmux` target is ticked.

- [ ] **Step 2: Add tests to `cmuxTests` target**

Right-click `cmuxTests` group, "Add Files to cmux…":
- `cmuxTests/ChromiumBinaryLocatorTests.swift`
- `cmuxTests/ChromiumDevToolsPortWatcherTests.swift`
- `cmuxTests/ChromiumLaunchManagerTests.swift`

Only the `cmuxTests` target should be ticked.

- [ ] **Step 3: Verify build**

```bash
./scripts/reload.sh --tag browser-cdp-phase1
```

Expected: build succeeds, app path printed, app is terminated (no launch).

- [ ] **Step 4: Commit the pbxproj diff**

```bash
git add GhosttyTabs.xcodeproj/project.pbxproj
git commit -m "Wire browserCDP phase1 files into cmux + cmuxTests targets"
```

---

## Task 9: Debug menu entry

**Files:**
- Modify: `Sources/cmuxApp.swift` around line 522 (inside the "Debug Windows" `Menu` block)

The button is placed alphabetically; "Launch Chromium (CDP)…" goes after "File Explorer Style Debug…" and before "Menu Bar Extra Debug…" — wait, current order has "Menu Bar Extra" earlier. Re-read the block and insert in correct alphabetical position. Current block (lines ~487-522) shows order: Background, Browser Import Hint, Browser Profile Popover, Debug Window Controls, Menu Bar Extra, Settings/About Titlebar, Sidebar, Split Button Layout, File Explorer Style, Open All. This list is not strictly alphabetical today (CLAUDE.md says entries should be alphabetical; File Explorer is out of order). Insert the new item alphabetically — i.e., between "Debug Window Controls…" and "Menu Bar Extra Debug…".

- [ ] **Step 1: Insert the button**

Find (Sources/cmuxApp.swift around line 502):
```swift
                    Button("Debug Window Controls…") {
                        DebugWindowControlsWindowController.shared.show()
                    }
                    Button("Menu Bar Extra Debug…") {
```

Replace with:
```swift
                    Button("Debug Window Controls…") {
                        DebugWindowControlsWindowController.shared.show()
                    }
                    Button("Launch Chromium (CDP)…") {
                        Task.detached { await BrowserCDPDebugLauncher.launchAndReportURL() }
                    }
                    Button("Menu Bar Extra Debug…") {
```

- [ ] **Step 2: Add the BrowserCDPDebugLauncher helper**

Create: `Sources/Panels/BrowserCDPLaunch/BrowserCDPDebugLauncher.swift`

```swift
#if DEBUG
import AppKit
import Bonsplit

enum BrowserCDPDebugLauncher {
    private static var manager: ChromiumLaunchManager?

    static func launchAndReportURL() async {
        let locator = ChromiumBinaryLocator()
        let binary: ChromiumBinary
        do {
            binary = try locator.locate()
        } catch {
            dlog("browserCDP: locate failed: \(error)")
            await presentAlert(title: "Chromium not found",
                               body: "Set CMUX_CHROMIUM_PATH or run `npx playwright install chromium`.")
            return
        }
        dlog("browserCDP: using \(binary.source.rawValue) at \(binary.path)")

        let mgr = ChromiumLaunchManager(binary: binary)
        manager = mgr
        mgr.launch(initialURL: URL(string: "about:blank"), timeout: 15) { result in
            switch result {
            case .success(let endpoint):
                let url = endpoint.webSocketURL.absoluteString
                dlog("browserCDP: \(url)")
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(url, forType: .string)
                Task { await presentAlert(title: "Chromium launched",
                                          body: "CDP URL copied to clipboard:\n\(url)") }
            case .failure(let error):
                dlog("browserCDP: launch failed: \(error)")
                Task { await presentAlert(title: "Chromium launch failed",
                                          body: "\(error)") }
            }
        }
    }

    @MainActor
    private static func presentAlert(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.runModal()
    }
}
#endif
```

- [ ] **Step 3: Add the new file to the Xcode target**

Add `Sources/Panels/BrowserCDPLaunch/BrowserCDPDebugLauncher.swift` to target `cmux` only.

- [ ] **Step 4: Reload + manual verification**

```bash
./scripts/reload.sh --tag browser-cdp-phase1 --launch
```

Cmd-click the `App path:` URL. In the running app:
1. Menu `Debug → Debug Windows → Launch Chromium (CDP)…`.
2. Expected: native Chromium window opens (separately from cmux), and an alert in cmux shows `ws://127.0.0.1:<port>/devtools/browser/<id>`.
3. Verify clipboard contains the same URL.
4. From any terminal:

```bash
node -e 'const {chromium}=require("playwright"); (async()=>{const b=await chromium.connectOverCDP(process.argv[1]); const c=b.contexts()[0]; const p=c.pages()[0] || await c.newPage(); await p.goto("https://example.com"); console.log(await p.title()); await b.close();})()' "<URL from clipboard>"
```

Expected: prints `Example Domain`. (Requires `npm i -g playwright` or a local install.)

5. Quit the tagged Debug app. Verify the Chromium child window closes too (process is killed by `ChromiumLaunchManager.terminate()` on app teardown — see Task 10).

- [ ] **Step 5: Commit**

```bash
git add Sources/cmuxApp.swift Sources/Panels/BrowserCDPLaunch/BrowserCDPDebugLauncher.swift GhosttyTabs.xcodeproj/project.pbxproj
git commit -m "Add Debug menu entry to launch Chromium and copy its CDP URL"
```

---

## Task 10: App-terminate cleanup

**Files:**
- Modify: `Sources/Panels/BrowserCDPLaunch/BrowserCDPDebugLauncher.swift`

Orphaned Chromium processes after cmux quits are a surprise. Register a terminate observer that kills any manager we created.

- [ ] **Step 1: Extend launcher with cleanup**

Replace the `enum BrowserCDPDebugLauncher` body to include:

```swift
#if DEBUG
import AppKit
import Bonsplit

enum BrowserCDPDebugLauncher {
    private static var manager: ChromiumLaunchManager?
    private static var observerInstalled = false

    static func launchAndReportURL() async {
        installTerminateObserverIfNeeded()
        // ...unchanged body below (same as Task 9)
        let locator = ChromiumBinaryLocator()
        let binary: ChromiumBinary
        do {
            binary = try locator.locate()
        } catch {
            dlog("browserCDP: locate failed: \(error)")
            await presentAlert(title: "Chromium not found",
                               body: "Set CMUX_CHROMIUM_PATH or run `npx playwright install chromium`.")
            return
        }
        dlog("browserCDP: using \(binary.source.rawValue) at \(binary.path)")

        manager?.terminate()
        let mgr = ChromiumLaunchManager(binary: binary)
        manager = mgr
        mgr.launch(initialURL: URL(string: "about:blank"), timeout: 15) { result in
            switch result {
            case .success(let endpoint):
                let url = endpoint.webSocketURL.absoluteString
                dlog("browserCDP: \(url)")
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(url, forType: .string)
                Task { await presentAlert(title: "Chromium launched",
                                          body: "CDP URL copied to clipboard:\n\(url)") }
            case .failure(let error):
                dlog("browserCDP: launch failed: \(error)")
                Task { await presentAlert(title: "Chromium launch failed",
                                          body: "\(error)") }
            }
        }
    }

    private static func installTerminateObserverIfNeeded() {
        guard !observerInstalled else { return }
        observerInstalled = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            manager?.terminate()
            manager = nil
        }
    }

    @MainActor
    private static func presentAlert(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.runModal()
    }
}
#endif
```

- [ ] **Step 2: Manual verification**

Build and launch via `reload.sh --tag browser-cdp-phase1 --launch`. Launch Chromium from the Debug menu. Quit cmux. Verify there is no stray Chromium process:

```bash
pgrep -fa "remote-debugging-port"
```

Expected: no match.

- [ ] **Step 3: Commit**

```bash
git add Sources/Panels/BrowserCDPLaunch/BrowserCDPDebugLauncher.swift
git commit -m "Clean up Chromium subprocess on cmux terminate"
```

---

## Task 11: README / docs stub

**Files:**
- Create: `docs/playwright-headful.md`

- [ ] **Step 1: Write the doc**

```markdown
# Playwright headful against cmux's Chromium (phase 1)

> Phase 1 status: cmux launches Chromium and hands you its CDP URL. The
> Chromium window is separate from the cmux window. Phase 2 will embed it
> into a cmux panel.

## Launch

In a DEBUG build:

1. `Debug → Debug Windows → Launch Chromium (CDP)…`
2. An alert shows `ws://127.0.0.1:<port>/devtools/browser/<id>`. The same
   URL is on the clipboard.

## Connect from Playwright

```ts
import { chromium } from "@playwright/test";

const cdp = process.env.CMUX_CDP_URL!; // paste from clipboard into env
const browser = await chromium.connectOverCDP(cdp);
const context = browser.contexts()[0] ?? (await browser.newContext());
const page = context.pages()[0] ?? (await context.newPage());
await page.goto("https://example.com");
console.log(await page.title());
await browser.close();
```

## Chromium binary resolution

`ChromiumBinaryLocator` searches in this order:

1. `$CMUX_CHROMIUM_PATH`
2. Highest revision under `~/Library/Caches/ms-playwright/chromium-*/chrome-mac/Chromium.app/Contents/MacOS/Chromium`
3. `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`
4. `/Applications/Chromium.app/Contents/MacOS/Chromium`

`chromium_headless_shell-*` builds are skipped — they don't have a window
and can't be driven via CDP for headful tests.

## Known limitations (phase 1)

- The Chromium window is a separate OS window, not a cmux panel.
- Only one launch at a time (the Debug button replaces the previous one).
- No socket or CLI surface yet; use the Debug menu.

Phase 2 adds the embedded panel; phase 3 adds the `cmux browser cdp-url`
CLI and `browser.cdp.*` socket commands.
```

- [ ] **Step 2: Commit**

```bash
git add docs/playwright-headful.md
git commit -m "Document phase1 Chromium CDP Debug-menu workflow"
```

---

## Verification summary

After all tasks:
- [ ] `xcodebuild ... -scheme cmux-unit` runs the three new test files in CI and passes.
- [ ] `./scripts/reload.sh --tag browser-cdp-phase1 --launch` builds.
- [ ] Debug menu entry launches Chromium; alert shows a valid WS URL; clipboard matches.
- [ ] `playwright.chromium.connectOverCDP(url)` from a Node script connects and can `page.goto()`.
- [ ] Quitting cmux leaves no stray Chromium process and no `/tmp/cmux-chromium-*` directories.

## Deferred to phase 2

- Adopting Chromium's NSWindow into a cmux panel (CGS SPI).
- SCStream capture fallback.
- New `browserCDP` panel type / session persistence.
- `browser.cdp.*` socket commands.
- `cmux browser cdp-url` CLI.
- End-to-end socket test in `tests_v2/`.
