import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

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
