import Foundation

public enum HelperConstants {
    public static let machServiceName = "com.gjy.NTFSMount.Helper"
    public static let daemonPlistName = "com.gjy.NTFSMount.Helper.plist"
    public static let appBundleIdentifier = "com.gjy.NTFSMount"
}

@objc public protocol NTFSMountHelperProtocol {
    func ping(reply: @escaping (_ protocolVersion: Int) -> Void)

    func mountNTFS(
        bsdName: String,
        discardWindowsHibernation: Bool,
        reply: @escaping (_ succeeded: Bool, _ messageOrMountPath: String) -> Void
    )
}
