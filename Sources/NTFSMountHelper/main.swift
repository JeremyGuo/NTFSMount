import Darwin
import CryptoKit
import Foundation
import NTFSMountShared
import Security

private struct HelperCommandResult {
    let status: Int32
    let output: String
    let outputData: Data
}

private enum HelperCommandRunner {
    static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil
    ) throws -> HelperCommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return HelperCommandResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            outputData: data
        )
    }
}

private enum HelperValidation {
    static func safeMountPoint(existing: String?, volumeName: String, bsdName: String) -> String {
        if let existing {
            let standardized = URL(fileURLWithPath: existing).standardized.path
            if standardized.hasPrefix("/Volumes/") && standardized != "/Volumes" {
                return standardized
            }
        }
        return "/Volumes/\(ShellUtilities.safeVolumeName(volumeName)) [\(bsdName)]"
    }
}

private enum HelperBundle {
    static var appURL: URL? {
        guard let executable = currentExecutablePath() else { return nil }
        return URL(fileURLWithPath: executable)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .deletingLastPathComponent() // LaunchServices
            .deletingLastPathComponent() // Library
            .deletingLastPathComponent() // Contents
    }

    static func currentExecutablePath() -> String? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return String(cString: buffer)
    }
}

private struct DriverRuntime {
    let executable: String
    let probe: String
    let environment: [String: String]
}

private enum DriverRuntimeManager {
    private static let fileManager = FileManager.default
    private static let baseURL = URL(fileURLWithPath: "/Library/Application Support/NTFSMount", isDirectory: true)
    private static let sourceCandidates: [String: [String]] = [
        "ntfs-3g": [
            "/opt/homebrew/opt/ntfs-3g-mac/bin/ntfs-3g",
            "/usr/local/opt/ntfs-3g-mac/bin/ntfs-3g"
        ],
        "ntfs-3g.probe": [
            "/opt/homebrew/opt/ntfs-3g-mac/bin/ntfs-3g.probe",
            "/usr/local/opt/ntfs-3g-mac/bin/ntfs-3g.probe"
        ],
        "libntfs-3g.90.dylib": [
            "/opt/homebrew/opt/ntfs-3g-mac/lib/libntfs-3g.90.dylib",
            "/usr/local/opt/ntfs-3g-mac/lib/libntfs-3g.90.dylib"
        ],
        "libintl.8.dylib": [
            "/opt/homebrew/opt/gettext/lib/libintl.8.dylib",
            "/usr/local/opt/gettext/lib/libintl.8.dylib"
        ],
        "libfuse.2.dylib": [
            "/usr/local/lib/libfuse.2.dylib"
        ]
    ]

    static func prepare() throws -> DriverRuntime {
        let allowlist = try loadAllowlist()
        let files = allowlist.files
        let identity = SHA256.hash(data: Data(
            files.sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "\n")
                .utf8
        )).map { String(format: "%02x", $0) }.joined()
        let runtimeURL = baseURL.appendingPathComponent("Runtime-\(identity.prefix(16))", isDirectory: true)

        try ensureSecureDirectory(baseURL)
        if fileManager.fileExists(atPath: runtimeURL.path) {
            try verifyRuntime(at: runtimeURL, hashes: files)
        } else {
            try installRuntime(at: runtimeURL, hashes: files)
        }

        return DriverRuntime(
            executable: runtimeURL.appendingPathComponent("ntfs-3g").path,
            probe: runtimeURL.appendingPathComponent("ntfs-3g.probe").path,
            environment: [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "DYLD_LIBRARY_PATH": runtimeURL.path
            ]
        )
    }

    private static func loadAllowlist() throws -> (version: String, files: [String: String]) {
        guard let appURL = HelperBundle.appURL else { throw runtimeError("无法定位 NTFSMount.app。") }
        let url = appURL.appendingPathComponent("Contents/Resources/DriverAllowlist.plist")
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = plist["DriverVersion"] as? String,
              let architecture = plist["Architecture"] as? String,
              let files = plist["Files"] as? [String: String],
              Set(files.keys) == Set(sourceCandidates.keys) else {
            throw runtimeError("驱动安全白名单无效。")
        }

        #if arch(arm64)
        guard architecture == "arm64" else { throw runtimeError("驱动运行时不支持当前 Mac 架构。") }
        #else
        guard architecture == "x86_64" else { throw runtimeError("驱动运行时不支持当前 Mac 架构。") }
        #endif

        return (version, files)
    }

    private static func installRuntime(at runtimeURL: URL, hashes: [String: String]) throws {
        let temporaryURL = baseURL.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try ensureSecureDirectory(temporaryURL)
        var shouldRemoveTemporary = true
        defer {
            if shouldRemoveTemporary {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        for (name, expectedHash) in hashes {
            guard let sourcePath = sourceCandidates[name]?.first(where: fileManager.isReadableFile(atPath:)) else {
                throw runtimeError("未找到受支持的 NTFS-3G \(name)。请重新安装 ntfs-3g-mac。")
            }
            let sourceURL = URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath()
            guard try sha256(of: sourceURL) == expectedHash else {
                throw runtimeError("已安装的 NTFS-3G 版本与应用安全白名单不匹配。请更新 NTFSMount 或重新安装受支持的 2026.7.7 版本。")
            }

            let destinationURL = temporaryURL.appendingPathComponent(name)
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            guard try sha256(of: destinationURL) == expectedHash else {
                throw runtimeError("复制 NTFS-3G 运行时后校验失败。")
            }
            _ = chown(destinationURL.path, 0, 0)
            _ = chmod(destinationURL.path, name.hasSuffix(".dylib") ? 0o644 : 0o755)
        }

        do {
            try fileManager.moveItem(at: temporaryURL, to: runtimeURL)
            shouldRemoveTemporary = false
        } catch CocoaError.fileWriteFileExists {
            try verifyRuntime(at: runtimeURL, hashes: hashes)
        }
    }

    private static func verifyRuntime(at url: URL, hashes: [String: String]) throws {
        try verifySecureDirectory(url)
        for (name, expectedHash) in hashes {
            let fileURL = url.appendingPathComponent(name)
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o777
            guard (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  permissions & 0o022 == 0,
                  try sha256(of: fileURL) == expectedHash else {
                throw runtimeError("受保护的 NTFS-3G 运行时校验失败。")
            }
        }
    }

    private static func ensureSecureDirectory(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try verifySecureDirectory(url)
            return
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        _ = chown(url.path, 0, 0)
        _ = chmod(url.path, 0o755)
        try verifySecureDirectory(url)
    }

    private static func verifySecureDirectory(_ url: URL) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o777
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
              permissions & 0o022 == 0 else {
            throw runtimeError("NTFSMount 安全运行目录无效。")
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func runtimeError(_ message: String) -> NSError {
        NSError(domain: "NTFSMountHelper.Runtime", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private final class HelperService: NSObject, NTFSMountHelperProtocol {
    private let operationQueue = DispatchQueue(label: "com.gjy.NTFSMount.Helper.operations")

    func ping(reply: @escaping (Int) -> Void) {
        reply(3)
    }

    func mountNTFS(
        bsdName: String,
        discardWindowsHibernation: Bool,
        reply: @escaping (Bool, String) -> Void
    ) {
        operationQueue.async {
            do {
                reply(true, try self.performMount(
                    bsdName: bsdName,
                    discardWindowsHibernation: discardWindowsHibernation
                ))
            } catch {
                reply(false, error.localizedDescription)
            }
        }
    }

    private func performMount(
        bsdName: String,
        discardWindowsHibernation: Bool
    ) throws -> String {
        let runtime = try DriverRuntimeManager.prepare()
        let info = try validateExternalNTFSPartition(bsdName: bsdName)
        let device = "/dev/\(bsdName)"
        let volumeName = ShellUtilities.safeVolumeName((info["VolumeName"] as? String) ?? "NTFS Volume")
        let existingMount = (info["MountPoint"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let mountPoint = HelperValidation.safeMountPoint(
            existing: existingMount,
            volumeName: volumeName,
            bsdName: bsdName
        )
        var shouldRestoreSystemMount = false

        do {
            if existingMount != nil {
                let unmount = try HelperCommandRunner.run("/usr/sbin/diskutil", ["unmount", device])
                guard unmount.status == 0 else {
                    throw helperError(unmount.output.isEmpty ? "无法卸载当前只读卷。" : unmount.output)
                }
                shouldRestoreSystemMount = true
            }

            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: mountPoint, isDirectory: true),
                withIntermediateDirectories: true
            )
            let consoleAttributes = try FileManager.default.attributesOfItem(atPath: "/dev/console")
            guard let uid = consoleAttributes[.ownerAccountID] as? NSNumber,
                  let gid = consoleAttributes[.groupOwnerAccountID] as? NSNumber,
                  uid.intValue > 0 else {
                throw helperError("无法确定当前登录用户。")
            }

            let probe = try HelperCommandRunner.run(
                runtime.probe,
                ["--readwrite", device],
                environment: runtime.environment
            )
            if let message = NTFSFailureInterpreter.probeMessage(exitCode: probe.status),
               !(discardWindowsHibernation && probe.status == 14) {
                throw helperError(message)
            }

            let options = [
                "volname=\(volumeName)", "local", "negative_vncache", "auto_xattr",
                "auto_cache", "noatime", "windows_names", "streams_interface=openxattr",
                "inherit", "uid=\(uid)", "gid=\(gid)", "allow_other", "big_writes"
            ]
            var effectiveOptions = options
            if discardWindowsHibernation {
                effectiveOptions.append("remove_hiberfile")
            }
            var arguments = effectiveOptions.flatMap { ["-o", $0] }
            arguments.append(contentsOf: [device, mountPoint])
            let mount = try HelperCommandRunner.run(
                runtime.executable,
                arguments,
                environment: runtime.environment
            )
            guard mount.status == 0 else {
                throw helperError(NTFSFailureInterpreter.message(for: mount.output))
            }

            var stats = statfs()
            guard statfs(mountPoint, &stats) == 0,
                  (stats.f_flags & UInt32(MNT_RDONLY)) == 0 else {
                throw helperError("卷没有进入可写状态，请检查 macFUSE 授权或磁盘健康状态。")
            }
            shouldRestoreSystemMount = false
            return mountPoint
        } catch {
            if shouldRestoreSystemMount {
                restoreSystemMount(device: device)
            }
            throw error
        }
    }

    private func validateExternalNTFSPartition(bsdName: String) throws -> [String: Any] {
        guard ShellUtilities.isSafePartitionBSDName(bsdName) else {
            throw helperError("磁盘标识无效。")
        }
        let info = try diskInfo(device: "/dev/\(bsdName)")
        guard (info["FilesystemType"] as? String)?.lowercased() == "ntfs",
              (info["Internal"] as? Bool) == false,
              (info["WholeDisk"] as? Bool) == false else {
            throw helperError("只允许处理外置 NTFS 分区。")
        }
        return info
    }

    private func restoreSystemMount(device: String) {
        _ = try? HelperCommandRunner.run("/usr/sbin/diskutil", ["unmount", device])
        _ = try? HelperCommandRunner.run("/usr/sbin/diskutil", ["mount", device])
    }

    private func diskInfo(device: String) throws -> [String: Any] {
        let result = try HelperCommandRunner.run("/usr/sbin/diskutil", ["info", "-plist", device])
        guard result.status == 0,
              let propertyList = try PropertyListSerialization.propertyList(
                from: result.outputData,
                format: nil
              ) as? [String: Any] else {
            throw helperError("无法读取磁盘信息。")
        }
        return propertyList
    }

    private func helperError(_ message: String) -> NSError {
        NSError(domain: "NTFSMountHelper", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private struct SigningInfo {
    let identifier: String?
    let teamIdentifier: String?
    let path: String?
}

private enum ClientCodeValidator {
    static func isTrusted(connection: NSXPCConnection) -> Bool {
        guard connection.processIdentifier > 0,
              let guestCode = code(forPID: connection.processIdentifier),
              let guestInfo = signingInfo(for: guestCode),
              let selfInfo = ownSigningInfo(),
              guestInfo.identifier == HelperConstants.appBundleIdentifier,
              SecCodeCheckValidity(guestCode, SecCSFlags(), nil) == errSecSuccess,
              isExpectedMainExecutable(guestInfo.path) else {
            return false
        }

        guard let ownTeam = selfInfo.teamIdentifier, !ownTeam.isEmpty else {
            // Local ad-hoc builds have no Team ID. The exact app-bundle path,
            // expected identifier and dynamic code validity still restrict access.
            return guestInfo.teamIdentifier == nil
        }
        guard guestInfo.teamIdentifier == ownTeam else { return false }

        let requirementText = "identifier \"\(HelperConstants.appBundleIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(ownTeam)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementText as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess, let requirement else {
            return false
        }
        return SecCodeCheckValidity(guestCode, SecCSFlags(), requirement) == errSecSuccess
    }

    private static func code(forPID pid: pid_t) -> SecCode? {
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code) == errSecSuccess else {
            return nil
        }
        return code
    }

    private static func ownSigningInfo() -> SigningInfo? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        return signingInfo(for: code)
    }

    private static func signingInfo(for code: SecCode) -> SigningInfo? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return nil }

        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }

        var codeURL: CFURL?
        _ = SecCodeCopyPath(staticCode, SecCSFlags(), &codeURL)
        return SigningInfo(
            identifier: dictionary[kSecCodeInfoIdentifier as String] as? String,
            teamIdentifier: dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
            path: (codeURL as URL?)?.standardizedFileURL.resolvingSymlinksInPath().path
        )
    }

    private static func isExpectedMainExecutable(_ guestPath: String?) -> Bool {
        guard let guestPath,
              let helperPath = currentExecutablePath() else { return false }

        let helperURL = URL(fileURLWithPath: helperPath).standardizedFileURL.resolvingSymlinksInPath()
        let appURL = helperURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let expected = appURL
            .appendingPathComponent("Contents/MacOS/NTFSMount")
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return guestPath == expected
    }

    private static func currentExecutablePath() -> String? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return String(cString: buffer)
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = HelperService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard ClientCodeValidator.isTrusted(connection: connection) else { return false }
        connection.exportedInterface = NSXPCInterface(with: NTFSMountHelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

private let delegate = ListenerDelegate()
private let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
