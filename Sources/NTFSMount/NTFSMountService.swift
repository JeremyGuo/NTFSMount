import Darwin
import Foundation
import NTFSMountShared

final class NTFSMountService {
    private let queue = DispatchQueue(label: "com.gjy.NTFSMount.operations", qos: .userInitiated)
    private let helperClient = PrivilegedHelperClient()

    var backend: NTFSBackend {
        NTFSBackend.detect()
    }

    var helperStatus: PrivilegedHelperStatus {
        helperClient.status
    }

    func registerHelper() throws {
        try helperClient.register()
    }

    func refreshHelperRegistration(completion: @escaping (Result<Void, Error>) -> Void) {
        helperClient.refreshRegistration(completion: completion)
    }

    func checkHelperConnection(completion: @escaping (Result<Void, Error>) -> Void) {
        helperClient.healthCheck(completion: completion)
    }

    func cleanUpUnsupportedHelperRegistration() {
        helperClient.cleanUpUnsupportedRegistration()
    }

    func mountReadWrite(
        _ volume: NTFSVolume,
        discardWindowsHibernation: Bool = false,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard ShellUtilities.isSafeBSDName(volume.bsdName) else {
            completion(.failure(OperationError(message: "磁盘标识无效。")))
            return
        }
        guard !volume.isInternal else {
            completion(.failure(OperationError(message: "为安全起见，不会重挂载内置磁盘。")))
            return
        }
        guard case let .ntfs3g(executablePath) = backend else {
            completion(.failure(OperationError(message: "未检测到 NTFS-3G 写入驱动。请先安装 macFUSE 和 ntfs-3g-mac。")))
            return
        }

        if helperClient.status == .enabled {
            helperClient.mount(
                bsdName: volume.bsdName,
                discardWindowsHibernation: discardWindowsHibernation,
                completion: completion
            )
            return
        }

        let mountPoint = safeMountPoint(for: volume)
        let device = volume.devicePath

        queue.async {
            do {
                let command = self.mountCommand(
                    executablePath: executablePath,
                    probeExecutablePath: self.backend.probeExecutablePath,
                    device: device,
                    mountPoint: mountPoint,
                    volumeName: volume.name,
                    shouldUnmount: volume.isMounted,
                    discardWindowsHibernation: discardWindowsHibernation
                )
                let result = try CommandRunner.runAsAdministrator(shellCommand: command)
                guard result.status == 0 else {
                    let detail = self.friendlyError(from: result)
                    throw OperationError(message: "无法以读写方式挂载“\(volume.name)”。\n\n\(detail)")
                }
                guard VolumeInspector.isWritableMount(at: mountPoint) else {
                    throw OperationError(message: "驱动已返回成功，但卷仍不是可写状态。请检查 macFUSE 是否已在“系统设置 → 隐私与安全性”中获准运行。")
                }
                DispatchQueue.main.async { completion(.success(mountPoint)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func safeMountPoint(for volume: NTFSVolume) -> String {
        if let existing = volume.mountPath {
            let standardized = URL(fileURLWithPath: existing).standardized.path
            if standardized.hasPrefix("/Volumes/") && standardized != "/Volumes" {
                return standardized
            }
        }
        return ShellUtilities.mountPoint(for: "\(volume.name) [\(volume.bsdName)]")
    }

    func eject(_ volume: NTFSVolume, completion: @escaping (Result<Void, Error>) -> Void) {
        guard ShellUtilities.isSafeBSDName(volume.wholeDiskBSDName) else {
            completion(.failure(OperationError(message: "磁盘标识无效。")))
            return
        }

        queue.async {
            do {
                let result = try CommandRunner.run(
                    executable: "/usr/sbin/diskutil",
                    arguments: ["eject", volume.wholeDiskDevicePath]
                )
                guard result.status == 0 else {
                    let detail = self.friendlyError(from: result)
                    throw OperationError(message: "无法安全弹出“\(volume.name)”。可能仍有文件正在使用。\n\n\(detail)")
                }
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func mountCommand(
        executablePath: String,
        probeExecutablePath: String?,
        device: String,
        mountPoint: String,
        volumeName: String,
        shouldUnmount: Bool,
        discardWindowsHibernation: Bool
    ) -> String {
        let q = ShellUtilities.quote
        var options = mountOptions(volumeName: volumeName)
        if discardWindowsHibernation {
            options.append("remove_hiberfile")
        }
        let optionArguments = options.map { "-o \(q($0))" }.joined(separator: " ")

        let prepare = shouldUnmount
            ? "/usr/sbin/diskutil unmount \(q(device)) && /bin/mkdir -p \(q(mountPoint))"
            : "/bin/mkdir -p \(q(mountPoint))"
        let mount = "\(q(executablePath)) \(optionArguments) \(q(device)) \(q(mountPoint))"
        let restore = "status=$?; /usr/sbin/diskutil mount \(q(device)) >/dev/null 2>&1 || true; exit $status"
        let preflight: String
        if let probeExecutablePath {
            let allowHibernation = discardWindowsHibernation
                ? "if [ $status -eq 14 ]; then /usr/bin/true; else /bin/echo NTFSMOUNT_PROBE_EXIT=$status >&2; /usr/sbin/diskutil mount \(q(device)) >/dev/null 2>&1 || true; exit $status; fi"
                : "/bin/echo NTFSMOUNT_PROBE_EXIT=$status >&2; /usr/sbin/diskutil mount \(q(device)) >/dev/null 2>&1 || true; exit $status"
            preflight = "\(q(probeExecutablePath)) --readwrite \(q(device)) || { status=$?; \(allowHibernation); }"
        } else {
            preflight = "/usr/bin/true"
        }
        return "\(prepare) && (\(preflight)) && (\(mount) || { \(restore); })"
    }

    private func mountOptions(volumeName: String) -> [String] {
        [
            "volname=\(ShellUtilities.safeVolumeName(volumeName))",
            "local",
            "negative_vncache",
            "auto_xattr",
            "auto_cache",
            "noatime",
            "windows_names",
            "streams_interface=openxattr",
            "inherit",
            "uid=\(getuid())",
            "gid=\(getgid())", "allow_other",
            "big_writes"
        ]
    }

    private func friendlyError(from result: CommandResult) -> String {
        let output = result.combinedOutput
        return output.isEmpty
            ? "命令退出码：\(result.status)"
            : NTFSFailureInterpreter.message(for: output)
    }
}
