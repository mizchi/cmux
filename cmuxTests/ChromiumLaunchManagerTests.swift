import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

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
