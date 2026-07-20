import Foundation
import Security

enum CodeSigningIdentity {
    static var teamIdentifier: String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess,
              let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return nil }

        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let teamID = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              !teamID.isEmpty else { return nil }
        return teamID
    }

    static var supportsPrivilegedHelper: Bool {
        teamIdentifier != nil && DriverAllowlistSupport.supportsCurrentArchitecture
    }
}

private enum DriverAllowlistSupport {
    static var supportsCurrentArchitecture: Bool {
        guard let url = Bundle.main.url(forResource: "DriverAllowlist", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let architecture = plist["Architecture"] as? String else { return false }

        #if arch(arm64)
        return architecture == "arm64"
        #else
        return architecture == "x86_64"
        #endif
    }
}
