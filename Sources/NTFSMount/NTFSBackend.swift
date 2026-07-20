import Foundation

enum NTFSBackend: Equatable, Sendable {
    case ntfs3g(executablePath: String)
    case unavailable

    static let candidatePaths = [
        "/opt/homebrew/bin/ntfs-3g",
        "/opt/homebrew/opt/ntfs-3g-mac/bin/ntfs-3g",
        "/usr/local/bin/ntfs-3g",
        "/usr/local/opt/ntfs-3g-mac/bin/ntfs-3g",
        "/opt/local/bin/ntfs-3g"
    ]

    static func detect(fileManager: FileManager = .default) -> NTFSBackend {
        if let path = candidatePaths.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return .ntfs3g(executablePath: path)
        }
        return .unavailable
    }

    var isAvailable: Bool {
        if case .ntfs3g = self { return true }
        return false
    }

    var displayName: String {
        switch self {
        case .ntfs3g: return "NTFS-3G（可读写）"
        case .unavailable: return "未安装 NTFS 写入驱动"
        }
    }

    var probeExecutablePath: String? {
        guard case let .ntfs3g(executablePath) = self else { return nil }
        let candidate = URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent()
            .appendingPathComponent("ntfs-3g.probe")
            .path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }
}
