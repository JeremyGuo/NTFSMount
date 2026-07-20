import Foundation

public enum NTFSFailureInterpreter {
    public static func isWindowsHibernationError(_ rawOutput: String) -> Bool {
        let output = rawOutput.lowercased()
        return parseProbeCode(from: output) == 14
            || output.contains("windows is hibernated")
            || output.contains("hibernated non-system partition")
            || output.contains("windows 休眠")
    }

    public static func message(for rawOutput: String) -> String {
        let output = rawOutput.lowercased()
        let probeCode = parseProbeCode(from: output)

        if isWindowsHibernationError(rawOutput) {
            return "此 NTFS 分区仍处于 Windows 休眠或快速启动状态，NTFS-3G 为保护数据已拒绝写入。\n\n推荐把磁盘接回 Windows，以管理员身份运行：\nshutdown /s /f /t 0\n\n如果希望永久关闭快速启动，也可先运行 powercfg /h off。若确定不需要恢复该 Windows 会话，可选择“丢弃休眠并挂载”；休眠中尚未写回磁盘的数据将永久丢失。"
        }

        if probeCode == 15
            || output.contains("not cleanly unmounted")
            || output.contains("metadata kept in windows cache") {
            return "此 NTFS 分区上次没有被 Windows 正常卸载，NTFS-3G 为保护数据已拒绝写入。\n\n请在 Windows 中对对应盘符运行 chkdsk /f，然后执行完整关机：\nshutdown /s /f /t 0"
        }

        if probeCode == 19
            || (output.contains("operation not permitted") && !output.contains("unsafe state"))
            || output.contains("not enough privilege") {
            return "macOS 拒绝访问磁盘设备。请确认 macFUSE 已在“系统设置 → 隐私与安全性”中获准运行，并在首次批准后重启 Mac。"
        }

        if probeCode == 13
            || output.contains("ntfs is either inconsistent")
            || output.contains("hardware fault") {
            return "NTFS 文件系统不一致或磁盘可能存在故障。请先在 Windows 中备份重要数据并运行 chkdsk /f；在修复前不要强制读写挂载。"
        }

        if probeCode == 16 || output.contains("already exclusively opened") {
            return "磁盘仍被另一个程序占用。请关闭正在访问该磁盘的 Finder 窗口和应用，然后重试。"
        }

        if output.contains("user canceled") || output.contains("(-128)") {
            return "已取消管理员授权。"
        }

        let cleaned = rawOutput
            .replacingOccurrences(
                of: #"^\d+:\d+: execution error:\s*"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "未知挂载错误。" : cleaned
    }

    public static func probeMessage(exitCode: Int32) -> String? {
        switch exitCode {
        case 0: return nil
        case 12: return "目标不是有效的 NTFS 分区。"
        case 13: return message(for: "NTFSMOUNT_PROBE_EXIT=13")
        case 14: return message(for: "NTFSMOUNT_PROBE_EXIT=14")
        case 15: return message(for: "NTFSMOUNT_PROBE_EXIT=15")
        case 16: return message(for: "NTFSMOUNT_PROBE_EXIT=16")
        case 19: return message(for: "NTFSMOUNT_PROBE_EXIT=19")
        default: return "NTFS 写入预检失败（状态码 \(exitCode)）。"
        }
    }

    private static func parseProbeCode(from output: String) -> Int? {
        if let range = output.range(
            of: #"ntfsmount_probe_exit\s*=\s*([0-9]+)"#,
            options: .regularExpression
        ) {
            let match = String(output[range])
            return Int(match.components(separatedBy: "=").last?.trimmingCharacters(in: .whitespaces) ?? "")
        }

        // osascript appends the child shell's exit status in parentheses.
        if output.contains("unsafe state"),
           let range = output.range(of: #"\(14\)\s*$"#, options: .regularExpression) {
            return Int(output[range].filter(\.isNumber))
        }
        return nil
    }
}
