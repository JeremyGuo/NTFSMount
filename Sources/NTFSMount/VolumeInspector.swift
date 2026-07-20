import Darwin
import Foundation

enum VolumeInspector {
    static func isWritableMount(at path: String) -> Bool {
        var fileSystem = statfs()
        guard statfs(path, &fileSystem) == 0 else { return false }
        return (fileSystem.f_flags & UInt32(MNT_RDONLY)) == 0
    }
}
