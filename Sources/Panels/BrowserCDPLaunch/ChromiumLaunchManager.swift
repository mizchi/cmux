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
