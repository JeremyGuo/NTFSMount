import Foundation

struct NTFSVolume: Equatable, Sendable {
    let bsdName: String
    let wholeDiskBSDName: String
    let name: String
    let mountPath: String?
    let volumeUUID: String?
    let isWritable: Bool
    let isInternal: Bool
    let size: Int64?

    var devicePath: String { "/dev/\(bsdName)" }
    var wholeDiskDevicePath: String { "/dev/\(wholeDiskBSDName)" }
    var isMounted: Bool { mountPath != nil }

    var identity: String {
        volumeUUID ?? bsdName
    }

    var stateDescription: String {
        guard isMounted else { return "尚未挂载" }
        return isWritable ? "已读写挂载" : "已只读挂载"
    }
}

enum DiskEvent {
    case appearedOrChanged(NTFSVolume)
    case disappeared(bsdName: String)
}

enum OperationKind: Equatable {
    case mounting
    case ejecting

    var description: String {
        switch self {
        case .mounting: return "正在挂载…"
        case .ejecting: return "正在弹出…"
        }
    }
}

struct OperationError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}
