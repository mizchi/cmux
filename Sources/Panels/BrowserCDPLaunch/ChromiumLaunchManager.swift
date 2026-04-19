import Foundation

final class ChromiumLaunchManager {
    private let binary: ChromiumBinary
    private var process: Process?
    private var watcher: ChromiumDevToolsPortWatcher?
    private(set) var userDataDir: URL?

    /// PID of the launched Chromium process, or nil before launch() has
    /// returned success / after terminate().
    var pid: pid_t? {
        guard let proc = process, proc.isRunning else { return nil }
        return proc.processIdentifier
    }

    /// Called on the main queue when the subprocess exits for any reason
    /// (user ⌘Q on Chromium, renderer crash, SIGKILL, explicit terminate).
    /// Fires exactly once per launch() call.
    var onProcessExit: (() -> Void)?
    private var terminationReported = false

    #if DEBUG
    var userDataDirForTesting: URL? { userDataDir }
    #endif

    init(binary: ChromiumBinary) {
        self.binary = binary
    }

    func launch(initialURL: URL?, timeout: TimeInterval, completion: @escaping (Result<ChromiumDevToolsEndpoint, Error>) -> Void) {
        precondition(process == nil, "ChromiumLaunchManager.launch called twice; call terminate() first")
        terminationReported = false

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
        // Drain the pipes so Chromium never blocks on full buffers. We discard
        // the bytes for now; phase 2 will tee them to /tmp/cmux-chromium-<id>.log.
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.terminationReported else { return }
                self.terminationReported = true
                self.onProcessExit?()
            }
        }

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
        // Move ownership of the subprocess + user-data-dir out of the instance
        // synchronously, then do the slow kill+wait off the calling thread.
        // Chromium can take seconds to unwind; the app-terminate handler runs
        // this on main at quit time, so we must not block the main run loop.
        let proc = self.process
        self.process = nil
        watcher?.cancel()
        watcher = nil
        let dirToRemove = self.userDataDir
        self.userDataDir = nil

        DispatchQueue.global(qos: .utility).async {
            if let proc, proc.isRunning {
                proc.terminate()
                proc.waitUntilExit()
            }
            if let dirToRemove {
                try? FileManager.default.removeItem(at: dirToRemove)
            }
        }
    }

    private func cleanupUserDataDir() {
        if let dir = userDataDir {
            try? FileManager.default.removeItem(at: dir)
        }
        userDataDir = nil
    }
}
