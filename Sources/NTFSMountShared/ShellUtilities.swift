import Foundation

public enum ShellUtilities {
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func appleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    public static func isSafeBSDName(_ value: String) -> Bool {
        value.range(of: #"^disk[0-9]+(?:s[0-9]+)?$"#, options: .regularExpression) != nil
    }

    public static func isSafePartitionBSDName(_ value: String) -> Bool {
        value.range(of: #"^disk[0-9]+s[0-9]+$"#, options: .regularExpression) != nil
    }

    public static func safeVolumeName(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:")
            .union(.controlCharacters)
            .union(.newlines)
        let pieces = value.components(separatedBy: forbidden)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let cleaned = pieces.joined(separator: "-")
        return String((cleaned.isEmpty ? "NTFS Volume" : cleaned).prefix(80))
    }

    public static func mountPoint(for volumeName: String) -> String {
        "/Volumes/\(safeVolumeName(volumeName))"
    }
}
