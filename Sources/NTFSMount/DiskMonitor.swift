import DiskArbitration
import Foundation
import NTFSMountShared

final class DiskMonitor {
    private let callback: (DiskEvent) -> Void
    private let session: DASession
    private var knownNTFSDisks = Set<String>()
    private var isStarted = false

    init?(callback: @escaping (DiskEvent) -> Void) {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return nil }
        self.session = session
        self.callback = callback
    }

    deinit {
        stop()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, diskAppearedCallback, context)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, diskDescriptionChangedCallback, context)
        DARegisterDiskDisappearedCallback(session, nil, diskDisappearedCallback, context)
        DASessionSetDispatchQueue(session, .main)
    }

    func stop() {
        guard isStarted else { return }
        DASessionSetDispatchQueue(session, nil)
        isStarted = false
    }

    func refresh(bsdName: String) {
        guard ShellUtilities.isSafeBSDName(bsdName) else { return }
        bsdName.withCString { pointer in
            guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, pointer) else { return }
            handleAppearedOrChanged(disk)
        }
    }

    fileprivate func handleAppearedOrChanged(_ disk: DADisk) {
        guard let bsdPointer = DADiskGetBSDName(disk) else { return }
        let bsdName = String(cString: bsdPointer)
        guard let description = DADiskCopyDescription(disk) as NSDictionary? else { return }

        let volumeKind = (description[kDADiskDescriptionVolumeKindKey] as? String) ?? ""
        let volumeType = (description[kDADiskDescriptionVolumeTypeKey] as? String) ?? ""
        let isNTFS = volumeKind.localizedCaseInsensitiveContains("ntfs")
            || volumeType.localizedCaseInsensitiveContains("ntfs")
            || knownNTFSDisks.contains(bsdName)

        guard isNTFS else { return }

        let isWholeDisk = (description[kDADiskDescriptionMediaWholeKey] as? Bool) ?? false
        guard !isWholeDisk else { return }

        let isInternal = (description[kDADiskDescriptionDeviceInternalKey] as? Bool) ?? true
        guard !isInternal else { return }

        knownNTFSDisks.insert(bsdName)

        let volumeName = (description[kDADiskDescriptionVolumeNameKey] as? String)
            ?? (description[kDADiskDescriptionMediaNameKey] as? String)
            ?? "NTFS Volume"
        let mountURL = description[kDADiskDescriptionVolumePathKey] as? URL
        let mountPath = mountURL?.path
        let isWritable = mountPath.map(VolumeInspector.isWritableMount(at:)) ?? false
        let volumeUUID = (description[kDADiskDescriptionVolumeUUIDKey] as? NSUUID)?.uuidString
        let mediaSize = (description[kDADiskDescriptionMediaSizeKey] as? NSNumber)?.int64Value

        var wholeDiskBSDName = bsdName
        if let wholeDisk = DADiskCopyWholeDisk(disk),
           let wholeBSDPointer = DADiskGetBSDName(wholeDisk) {
            wholeDiskBSDName = String(cString: wholeBSDPointer)
        }

        callback(.appearedOrChanged(NTFSVolume(
            bsdName: bsdName,
            wholeDiskBSDName: wholeDiskBSDName,
            name: volumeName,
            mountPath: mountPath,
            volumeUUID: volumeUUID,
            isWritable: isWritable,
            isInternal: isInternal,
            size: mediaSize
        )))
    }

    fileprivate func handleDisappeared(_ disk: DADisk) {
        guard let bsdPointer = DADiskGetBSDName(disk) else { return }
        let bsdName = String(cString: bsdPointer)
        guard knownNTFSDisks.remove(bsdName) != nil else { return }
        callback(.disappeared(bsdName: bsdName))
    }
}

private func diskAppearedCallback(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<DiskMonitor>.fromOpaque(context).takeUnretainedValue().handleAppearedOrChanged(disk)
}

private func diskDescriptionChangedCallback(
    _ disk: DADisk,
    _ keys: CFArray,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    Unmanaged<DiskMonitor>.fromOpaque(context).takeUnretainedValue().handleAppearedOrChanged(disk)
}

private func diskDisappearedCallback(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<DiskMonitor>.fromOpaque(context).takeUnretainedValue().handleDisappeared(disk)
}
