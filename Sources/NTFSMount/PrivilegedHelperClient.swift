import Foundation
import NTFSMountShared
import ServiceManagement

enum PrivilegedHelperStatus: Equatable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
    case developmentBuild

    var description: String {
        switch self {
        case .enabled: return "后台自动助手已启用"
        case .requiresApproval: return "后台助手等待批准"
        case .notRegistered: return "启用无密码自动挂载…"
        case .notFound: return "后台助手未打包"
        case .developmentBuild: return "开发版：挂载时需管理员授权"
        }
    }

    var canConfigure: Bool {
        self != .enabled && self != .notFound && self != .developmentBuild
    }
}

final class PrivilegedHelperClient {
    private var service: SMAppService {
        SMAppService.daemon(plistName: HelperConstants.daemonPlistName)
    }

    var status: PrivilegedHelperStatus {
        guard CodeSigningIdentity.supportsPrivilegedHelper else {
            return .developmentBuild
        }
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        default: return .notRegistered
        }
    }

    func register() throws {
        guard CodeSigningIdentity.supportsPrivilegedHelper else {
            throw OperationError(message: "当前是 ad-hoc 签名开发版，macOS 不允许注册特权后台助手。")
        }
        guard service.status != .enabled else { return }
        if service.status == .requiresApproval { return }
        try service.register()
    }

    func cleanUpUnsupportedRegistration() {
        guard !CodeSigningIdentity.supportsPrivilegedHelper,
              service.status == .enabled || service.status == .requiresApproval else { return }
        DispatchQueue.global(qos: .utility).async { [service] in
            try? service.unregister()
        }
    }

    func mount(
        bsdName: String,
        discardWindowsHibernation: Bool,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        withProxy(completion: completion) { proxy, connection in
            proxy.mountNTFS(
                bsdName: bsdName,
                discardWindowsHibernation: discardWindowsHibernation
            ) { succeeded, message in
                connection.invalidate()
                DispatchQueue.main.async {
                    if succeeded {
                        completion(.success(message))
                    } else {
                        completion(.failure(OperationError(message: message)))
                    }
                }
            }
        }
    }

    func healthCheck(completion: @escaping (Result<Void, Error>) -> Void) {
        withProxy(completion: { result in completion(result.map { _ in () }) }) { proxy, connection in
            proxy.ping { version in
                connection.invalidate()
                DispatchQueue.main.async {
                    if version == 3 {
                        completion(.success(()))
                    } else {
                        completion(.failure(OperationError(message: "后台助手版本不兼容。")))
                    }
                }
            }
        }
    }

    func refreshRegistration(completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if self.service.status == .enabled {
                    try self.service.unregister()
                    Thread.sleep(forTimeInterval: 0.5)
                }
                try self.service.register()
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func withProxy(
        completion: @escaping (Result<String, Error>) -> Void,
        operation: (NTFSMountHelperProtocol, NSXPCConnection) -> Void
    ) {
        let connection = NSXPCConnection(
            machServiceName: HelperConstants.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: NTFSMountHelperProtocol.self)
        connection.resume()

        let errorHandler: (Error) -> Void = { error in
            connection.invalidate()
            DispatchQueue.main.async {
                completion(.failure(OperationError(message: "无法连接后台助手：\(error.localizedDescription)")))
            }
        }

        guard let proxy = connection.remoteObjectProxyWithErrorHandler(errorHandler) as? NTFSMountHelperProtocol else {
            connection.invalidate()
            completion(.failure(OperationError(message: "后台助手接口不可用。")))
            return
        }

        operation(proxy, connection)
    }
}
