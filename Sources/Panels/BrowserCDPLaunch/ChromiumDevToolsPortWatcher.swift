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
