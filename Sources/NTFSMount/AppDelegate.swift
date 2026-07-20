import AppKit
import NTFSMountShared
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenuController: StatusMenuController!
    private var diskMonitor: DiskMonitor?
    private let mountService = NTFSMountService()
    private var volumes: [String: NTFSVolume] = [:]
    private var operations: [String: OperationKind] = [:]
    private var attemptedAutomaticMounts = Set<String>()
    private var isRefreshingHelper = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.registerDefaults()
        statusMenuController = StatusMenuController()
        connectMenuActions()
        ApplicationRegistration.registerCurrentBundle()
        mountService.cleanUpUnsupportedHelperRegistration()
        refreshInstalledHelperIfNeeded()

        diskMonitor = DiskMonitor { [weak self] event in
            DispatchQueue.main.async {
                self?.handle(event)
            }
        }
        diskMonitor?.start()
        refreshMenu()

        if diskMonitor == nil {
            showError(title: "无法监听磁盘", message: "Disk Arbitration 会话创建失败，请重新启动应用。")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        diskMonitor?.stop()
    }

    private func connectMenuActions() {
        statusMenuController.onMount = { [weak self] in self?.mountVolume(bsdName: $0, automatic: false) }
        statusMenuController.onForceMount = { [weak self] in self?.confirmAndDiscardHibernation(bsdName: $0) }
        statusMenuController.onOpen = { [weak self] in self?.openVolume(bsdName: $0) }
        statusMenuController.onEject = { [weak self] in self?.ejectVolume(bsdName: $0) }
        statusMenuController.onRefresh = { [weak self] in self?.refreshAllVolumes() }
        statusMenuController.onShowDriverHelp = { [weak self] in self?.showDriverHelp() }
        statusMenuController.onSetupHelper = { [weak self] in self?.setupPrivilegedHelper() }
        statusMenuController.onToggleAutoMount = { [weak self] in
            AppSettings.autoMount.toggle()
            self?.refreshMenu()
        }
        statusMenuController.onToggleOpenFinder = { [weak self] in
            AppSettings.openFinderAfterMount.toggle()
            self?.refreshMenu()
        }
        statusMenuController.onToggleLaunchAtLogin = { [weak self] in self?.toggleLaunchAtLogin() }
    }

    private func handle(_ event: DiskEvent) {
        switch event {
        case let .appearedOrChanged(volume):
            volumes[volume.bsdName] = volume
            refreshMenu()
            scheduleAutomaticMountIfNeeded(volume)

        case let .disappeared(bsdName):
            if let volume = volumes.removeValue(forKey: bsdName) {
                attemptedAutomaticMounts.remove(volume.identity)
            }
            operations.removeValue(forKey: bsdName)
            refreshMenu()
        }
    }

    private func scheduleAutomaticMountIfNeeded(_ volume: NTFSVolume) {
        guard AppSettings.autoMount,
              ProcessInfo.processInfo.environment["NTFSMOUNT_DISABLE_AUTOMOUNT"] != "1",
              !isRefreshingHelper,
              mountService.backend.isAvailable,
              !volume.isWritable,
              operations[volume.bsdName] == nil,
              !attemptedAutomaticMounts.contains(volume.identity)
        else { return }

        attemptedAutomaticMounts.insert(volume.identity)
        let identity = volume.identity

        // Give Disk Arbitration time to finish the system's initial read-only mount.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self,
                  let current = self.volumes[volume.bsdName],
                  current.identity == identity,
                  !current.isWritable,
                  self.operations[current.bsdName] == nil
            else { return }
            self.mountVolume(bsdName: current.bsdName, automatic: true)
        }
    }

    private func mountVolume(
        bsdName: String,
        automatic: Bool,
        discardWindowsHibernation: Bool = false
    ) {
        guard let volume = volumes[bsdName], operations[bsdName] == nil else { return }
        guard mountService.backend.isAvailable else {
            showDriverHelp()
            return
        }

        attemptedAutomaticMounts.insert(volume.identity)
        operations[bsdName] = .mounting
        refreshMenu()

        mountService.mountReadWrite(
            volume,
            discardWindowsHibernation: discardWindowsHibernation
        ) { [weak self] result in
            guard let self else { return }
            self.operations.removeValue(forKey: bsdName)

            switch result {
            case let .success(mountPath):
                self.diskMonitor?.refresh(bsdName: bsdName)
                if AppSettings.openFinderAfterMount {
                    NSWorkspace.shared.open(URL(fileURLWithPath: mountPath, isDirectory: true))
                }
            case let .failure(error):
                self.diskMonitor?.refresh(bsdName: bsdName)
                if !discardWindowsHibernation,
                   NTFSFailureInterpreter.isWindowsHibernationError(error.localizedDescription) {
                    self.showHibernationRecoveryPrompt(
                        bsdName: bsdName,
                        volumeName: volume.name,
                        automatic: automatic,
                        message: error.localizedDescription
                    )
                } else {
                    self.showError(
                        title: discardWindowsHibernation ? "强制挂载失败" : (automatic ? "自动挂载失败" : "挂载失败"),
                        message: error.localizedDescription
                    )
                }
            }
            self.refreshMenu()
        }
    }

    private func confirmAndDiscardHibernation(bsdName: String) {
        guard let volume = volumes[bsdName], operations[bsdName] == nil else { return }
        showHibernationRecoveryPrompt(
            bsdName: bsdName,
            volumeName: volume.name,
            automatic: false,
            message: nil
        )
    }

    private func showHibernationRecoveryPrompt(
        bsdName: String,
        volumeName: String,
        automatic: Bool,
        message: String?
    ) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "丢弃“\(volumeName)”的 Windows 休眠状态？"
        let consequence = "这会永久删除 hiberfil.sys 中的 Windows 休眠会话。休眠时尚未写回磁盘的文档、系统状态和缓存将无法恢复，并可能导致 Windows 下次启动执行磁盘检查。此操作无法撤销。"
        if let message {
            alert.informativeText = "\(message)\n\n\(consequence)"
        } else {
            alert.informativeText = consequence
        }
        alert.addButton(withTitle: "丢弃休眠并挂载")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        NSApplication.shared.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        mountVolume(
            bsdName: bsdName,
            automatic: automatic,
            discardWindowsHibernation: true
        )
    }

    private func ejectVolume(bsdName: String) {
        guard let volume = volumes[bsdName], operations[bsdName] == nil else { return }

        operations[bsdName] = .ejecting
        refreshMenu()
        mountService.eject(volume) { [weak self] result in
            guard let self else { return }
            self.operations.removeValue(forKey: bsdName)

            switch result {
            case .success:
                self.volumes.removeValue(forKey: bsdName)
                self.attemptedAutomaticMounts.remove(volume.identity)
            case let .failure(error):
                self.showError(title: "弹出失败", message: error.localizedDescription)
                self.diskMonitor?.refresh(bsdName: bsdName)
            }
            self.refreshMenu()
        }
    }

    private func openVolume(bsdName: String) {
        guard let path = volumes[bsdName]?.mountPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    private func refreshAllVolumes() {
        for bsdName in volumes.keys {
            diskMonitor?.refresh(bsdName: bsdName)
        }
        refreshMenu()
    }

    private func toggleLaunchAtLogin() {
        do {
            try LaunchAtLoginManager.setEnabled(!LaunchAtLoginManager.isEnabled)
        } catch {
            showError(
                title: "无法更改登录启动设置",
                message: "请先把 NTFSMount.app 移到“应用程序”文件夹后再试。\n\n\(error.localizedDescription)"
            )
        }
        refreshMenu()
    }

    private func showDriverHelp() {
        let command = "brew install --cask macfuse && brew install gromgit/fuse/ntfs-3g-mac"
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "需要 NTFS 写入驱动"
        alert.informativeText = "macOS 自带的 NTFS 驱动仅支持读取。安装 macFUSE 与 NTFS-3G 后，本应用才能安全地提供写入能力。首次安装 macFUSE 后，可能需要在“系统设置 → 隐私与安全性”中允许它并重启 Mac。\n\nHomebrew 命令：\n\(command)"
        alert.addButton(withTitle: "复制安装命令")
        alert.addButton(withTitle: "打开项目主页")
        alert.addButton(withTitle: "取消")
        NSApplication.shared.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        case .alertSecondButtonReturn:
            if let url = URL(string: "https://github.com/gromgit/homebrew-fuse") {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }

    private func setupPrivilegedHelper() {
        if mountService.helperStatus == .enabled {
            let confirmation = NSAlert()
            confirmation.alertStyle = .informational
            confirmation.messageText = "重新安装后台助手？"
            confirmation.informativeText = "这会刷新后台助手到当前应用版本，可修复更新后无法通信的问题。"
            confirmation.addButton(withTitle: "重新安装")
            confirmation.addButton(withTitle: "取消")
            NSApplication.shared.activate(ignoringOtherApps: true)
            guard confirmation.runModal() == .alertFirstButtonReturn else { return }

            mountService.refreshHelperRegistration { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    AppSettings.registeredHelperBuildIdentity = AppSettings.bundledHelperBuildIdentity
                    self.presentHelperStatus()
                case let .failure(error):
                    self.showError(title: "无法重新安装后台助手", message: error.localizedDescription)
                }
                self.refreshMenu()
            }
            return
        }

        do {
            try mountService.registerHelper()
            if mountService.helperStatus == .enabled {
                AppSettings.registeredHelperBuildIdentity = AppSettings.bundledHelperBuildIdentity
            }
            presentHelperStatus()
        } catch {
            showError(
                title: "无法启用后台助手",
                message: "后台助手要求应用位于“应用程序”文件夹，并使用 Developer ID 签名及 Apple 公证。\n\n\(error.localizedDescription)"
            )
        }
        refreshMenu()
    }

    private func refreshInstalledHelperIfNeeded() {
        guard mountService.helperStatus == .enabled else { return }
        guard let bundledIdentity = AppSettings.bundledHelperBuildIdentity,
              bundledIdentity != AppSettings.registeredHelperBuildIdentity else {
            verifyHelperConnection()
            return
        }

        isRefreshingHelper = true
        mountService.refreshHelperRegistration { [weak self] result in
            guard let self else { return }
            self.isRefreshingHelper = false
            switch result {
            case .success:
                self.verifyHelperConnection(afterRepair: true, bundledIdentity: bundledIdentity)
                for volume in self.volumes.values {
                    self.scheduleAutomaticMountIfNeeded(volume)
                }
            case let .failure(error):
                self.showError(
                    title: "后台助手更新失败",
                    message: "请从菜单选择“后台自动助手已启用（重新安装…）”。\n\n\(error.localizedDescription)"
                )
            }
            self.refreshMenu()
        }
    }

    private func verifyHelperConnection(
        afterRepair: Bool = false,
        bundledIdentity: String? = AppSettings.bundledHelperBuildIdentity
    ) {
        mountService.checkHelperConnection { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                AppSettings.registeredHelperBuildIdentity = bundledIdentity

            case .failure where !afterRepair:
                self.isRefreshingHelper = true
                ApplicationRegistration.registerCurrentBundle()
                self.mountService.refreshHelperRegistration { [weak self] refreshResult in
                    guard let self else { return }
                    self.isRefreshingHelper = false
                    switch refreshResult {
                    case .success:
                        self.verifyHelperConnection(afterRepair: true, bundledIdentity: bundledIdentity)
                    case let .failure(refreshError):
                        self.showHelperConnectionError(refreshError)
                    }
                    self.refreshMenu()
                }

            case let .failure(error):
                self.showHelperConnectionError(error)
            }
        }
    }

    private func showHelperConnectionError(_ error: Error) {
        showError(
            title: "后台助手连接失败",
            message: "请从菜单选择“后台自动助手已启用（重新安装…）”。\n\n\(error.localizedDescription)"
        )
    }

    private func presentHelperStatus() {
        switch mountService.helperStatus {
        case .enabled:
            let alert = NSAlert()
            alert.messageText = "后台自动助手已启用"
            alert.informativeText = "以后插入 NTFS 磁盘时，应用可以自动完成读写挂载，无需每次输入管理员密码。"
            alert.addButton(withTitle: "好")
            NSApplication.shared.activate(ignoringOtherApps: true)
            alert.runModal()

        case .requiresApproval:
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "还需要批准后台助手"
            alert.informativeText = "请在“系统设置 → 通用 → 登录项与扩展”中允许 NTFSMount 的后台项目，然后返回应用刷新磁盘。"
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "稍后")
            NSApplication.shared.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                SMAppService.openSystemSettingsLoginItems()
            }

        case .notFound:
            showError(title: "后台助手缺失", message: "当前应用包不包含后台助手，请重新下载完整发布包。")

        case .notRegistered:
            showError(title: "后台助手未注册", message: "系统没有完成注册，请确认应用位于“应用程序”文件夹后重试。")

        case .developmentBuild:
            showError(
                title: "开发版不支持后台助手",
                message: "当前应用使用 ad-hoc 签名。挂载仍可用，但 macOS 会在每次需要写入时显示管理员授权对话框。Developer ID 签名并公证的正式版可启用无密码助手。"
            )
        }
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func refreshMenu() {
        statusMenuController.update(
            volumes: volumes,
            operations: operations,
            backend: mountService.backend,
            helperStatus: mountService.helperStatus
        )
    }
}
