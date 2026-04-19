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
