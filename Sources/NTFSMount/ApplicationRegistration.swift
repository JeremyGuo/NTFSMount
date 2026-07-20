import CoreServices
import Foundation

enum ApplicationRegistration {
    @discardableResult
    static func registerCurrentBundle() -> OSStatus {
        LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
    }
}
