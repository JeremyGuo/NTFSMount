import Foundation
import NTFSMountShared

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("Validation failed: \(message)\n".utf8))
        exit(1)
    }
}

expect(ShellUtilities.quote("My Disk") == "'My Disk'", "shell quoting with spaces")
expect(ShellUtilities.quote("Sam's Disk") == "'Sam'\\''s Disk'", "shell quoting with apostrophe")
expect(
    ShellUtilities.appleScriptString("say \"hello\" \\ path") == "say \\\"hello\\\" \\\\ path",
    "AppleScript escaping"
)
expect(ShellUtilities.isSafeBSDName("disk6s1"), "valid partition BSD name")
expect(ShellUtilities.isSafeBSDName("disk12"), "valid whole-disk BSD name")
expect(ShellUtilities.isSafePartitionBSDName("disk6s1"), "valid partition-only BSD name")
expect(!ShellUtilities.isSafePartitionBSDName("disk6"), "reject whole disk as partition")
expect(!ShellUtilities.isSafeBSDName("disk6s1; rm -rf /"), "reject shell injection")
expect(!ShellUtilities.isSafeBSDName("/dev/disk6s1"), "reject device path")
expect(ShellUtilities.safeVolumeName("Work/Windows:Data") == "Work-Windows-Data", "volume name sanitization")
expect(ShellUtilities.mountPoint(for: "Work/Windows") == "/Volumes/Work-Windows", "mount path sanitization")
expect(ShellUtilities.safeVolumeName("\n") == "NTFS Volume", "empty volume name fallback")
expect(
    NTFSFailureInterpreter.message(for: "The NTFS partition is in an unsafe state. (14)")
        .contains("Windows 休眠"),
    "hibernated partition error"
)
expect(
    NTFSFailureInterpreter.isWindowsHibernationError("The NTFS partition is in an unsafe state. (14)"),
    "hibernated partition recovery detection"
)
expect(
    NTFSFailureInterpreter.message(for: "NTFSMOUNT_PROBE_EXIT=15")
        .contains("没有被 Windows 正常卸载"),
    "unclean partition error"
)
expect(
    NTFSFailureInterpreter.message(for: "NTFSMOUNT_PROBE_EXIT=19")
        .contains("macOS 拒绝访问"),
    "privilege error"
)

print("NTFSMount validation passed")
