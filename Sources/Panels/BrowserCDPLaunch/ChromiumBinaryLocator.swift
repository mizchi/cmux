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
