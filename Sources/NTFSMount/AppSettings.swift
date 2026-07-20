import Foundation
import ServiceManagement
import CryptoKit

enum AppSettings {
    static let autoMountKey = "autoMountNTFSVolumes"
    static let openFinderAfterMountKey = "openFinderAfterMount"
    static let helperBuildIdentityKey = "registeredHelperBuildIdentity"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            autoMountKey: true,
            openFinderAfterMountKey: false
        ])
    }

    static var autoMount: Bool {
        get { UserDefaults.standard.bool(forKey: autoMountKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoMountKey) }
    }

    static var openFinderAfterMount: Bool {
        get { UserDefaults.standard.bool(forKey: openFinderAfterMountKey) }
        set { UserDefaults.standard.set(newValue, forKey: openFinderAfterMountKey) }
    }

    static var registeredHelperBuildIdentity: String? {
        get { UserDefaults.standard.string(forKey: helperBuildIdentityKey) }
        set { UserDefaults.standard.set(newValue, forKey: helperBuildIdentityKey) }
    }

    static var bundledHelperBuildIdentity: String? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchServices/com.gjy.NTFSMount.Helper")
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

@available(macOS 13.0, *)
enum LaunchAtLoginManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            } else if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}
