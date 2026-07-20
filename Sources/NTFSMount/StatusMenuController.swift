import AppKit

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    var onMount: ((String) -> Void)?
    var onForceMount: ((String) -> Void)?
    var onOpen: ((String) -> Void)?
    var onEject: ((String) -> Void)?
    var onRefresh: (() -> Void)?
    var onShowDriverHelp: (() -> Void)?
    var onSetupHelper: (() -> Void)?
    var onToggleAutoMount: (() -> Void)?
    var onToggleOpenFinder: (() -> Void)?
    var onToggleLaunchAtLogin: (() -> Void)?

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var volumes: [String: NTFSVolume] = [:]
    private var operations: [String: OperationKind] = [:]
    private var backend: NTFSBackend = .unavailable
    private var helperStatus: PrivilegedHelperStatus = .notFound

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "externaldrive.fill",
                accessibilityDescription: "NTFSMount"
            )
            image?.isTemplate = true
            button.image = image
            button.toolTip = "NTFSMount"
        }
        rebuildMenu()
    }

    func update(
        volumes: [String: NTFSVolume],
        operations: [String: OperationKind],
        backend: NTFSBackend,
        helperStatus: PrivilegedHelperStatus
    ) {
        self.volumes = volumes
        self.operations = operations
        self.backend = backend
        self.helperStatus = helperStatus
        updateStatusIcon()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func updateStatusIcon() {
        let symbol: String
        if !operations.isEmpty {
            symbol = "externaldrive.fill.badge.timemachine"
        } else if volumes.values.contains(where: { $0.isWritable }) {
            symbol = "externaldrive.fill.badge.checkmark"
        } else {
            symbol = "externaldrive.fill"
        }

        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "NTFSMount")
            ?? NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: "NTFSMount")
        image?.isTemplate = true
        button.image = image
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let title = NSMenuItem(title: "NTFSMount", action: nil, keyEquivalent: "")
        title.image = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: nil)
        title.isEnabled = false
        menu.addItem(title)

        let driver = NSMenuItem(
            title: backend.displayName,
            action: backend.isAvailable ? nil : #selector(showDriverHelp),
            keyEquivalent: ""
        )
        driver.target = self
        driver.image = NSImage(
            systemSymbolName: backend.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            accessibilityDescription: nil
        )
        driver.isEnabled = !backend.isAvailable
        menu.addItem(driver)

        if backend.isAvailable {
            let helper = NSMenuItem(
                title: helperStatus == .enabled
                    ? "后台自动助手已启用（重新安装…）"
                    : helperStatus.description,
                action: #selector(setupHelper),
                keyEquivalent: ""
            )
            helper.target = self
            helper.image = NSImage(
                systemSymbolName: helperStatus == .enabled ? "lock.shield.fill" : "lock.open.trianglebadge.exclamationmark",
                accessibilityDescription: nil
            )
            helper.isEnabled = helperStatus.canConfigure || helperStatus == .enabled
            menu.addItem(helper)
        }
        menu.addItem(.separator())

        if volumes.isEmpty {
            let empty = NSMenuItem(title: "未发现外置 NTFS 磁盘", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for volume in volumes.values.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                menu.addItem(makeVolumeItem(volume))
            }
        }

        menu.addItem(.separator())
        let autoMount = NSMenuItem(title: "自动读写挂载", action: #selector(toggleAutoMount), keyEquivalent: "")
        autoMount.target = self
        autoMount.state = AppSettings.autoMount ? .on : .off
        autoMount.isEnabled = true
        menu.addItem(autoMount)

        let openFinder = NSMenuItem(title: "挂载后打开 Finder", action: #selector(toggleOpenFinder), keyEquivalent: "")
        openFinder.target = self
        openFinder.state = AppSettings.openFinderAfterMount ? .on : .off
        openFinder.isEnabled = true
        menu.addItem(openFinder)

        let launchAtLogin = NSMenuItem(title: "登录时启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLogin.target = self
        launchAtLogin.state = LaunchAtLoginManager.isEnabled ? .on : .off
        launchAtLogin.isEnabled = true
        menu.addItem(launchAtLogin)

        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "刷新磁盘", action: #selector(refreshDisks), keyEquivalent: "r")
        refresh.target = self
        refresh.isEnabled = true
        menu.addItem(refresh)

        let about = NSMenuItem(title: "关于 NTFSMount", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        about.isEnabled = true
        menu.addItem(about)

        let quit = NSMenuItem(title: "退出 NTFSMount", action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        quit.isEnabled = true
        menu.addItem(quit)
    }

    private func makeVolumeItem(_ volume: NTFSVolume) -> NSMenuItem {
        let operation = operations[volume.bsdName]
        let title = operation.map { "\(volume.name) · \($0.description)" } ?? volume.name
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: volume.isWritable ? "externaldrive.fill.badge.checkmark" : "externaldrive.fill", accessibilityDescription: nil)

        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let state = NSMenuItem(title: operation?.description ?? volume.stateDescription, action: nil, keyEquivalent: "")
        state.isEnabled = false
        submenu.addItem(state)

        let sizeText = volume.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .decimal) }
        let details = [volume.bsdName, sizeText].compactMap { $0 }.joined(separator: " · ")
        let detailItem = NSMenuItem(title: details, action: nil, keyEquivalent: "")
        detailItem.isEnabled = false
        submenu.addItem(detailItem)
        submenu.addItem(.separator())

        let mount = NSMenuItem(
            title: volume.isMounted ? "重新挂载为读写" : "以读写方式挂载",
            action: #selector(mountVolume(_:)),
            keyEquivalent: ""
        )
        mount.target = self
        mount.representedObject = volume.bsdName
        mount.isEnabled = operation == nil && backend.isAvailable && !volume.isWritable
        submenu.addItem(mount)

        let forceMount = NSMenuItem(
            title: "强制丢弃 Windows 休眠并读写挂载…",
            action: #selector(forceMountVolume(_:)),
            keyEquivalent: ""
        )
        forceMount.target = self
        forceMount.representedObject = volume.bsdName
        forceMount.image = NSImage(
            systemSymbolName: "exclamationmark.triangle",
            accessibilityDescription: nil
        )
        forceMount.isEnabled = operation == nil && backend.isAvailable && !volume.isWritable
        submenu.addItem(forceMount)

        let open = NSMenuItem(title: "在 Finder 中打开", action: #selector(openVolume(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = volume.bsdName
        open.isEnabled = operation == nil && volume.isMounted
        submenu.addItem(open)

        let eject = NSMenuItem(title: "安全弹出", action: #selector(ejectVolume(_:)), keyEquivalent: "")
        eject.target = self
        eject.representedObject = volume.bsdName
        eject.isEnabled = operation == nil
        submenu.addItem(eject)

        item.submenu = submenu
        return item
    }

    @objc private func mountVolume(_ sender: NSMenuItem) {
        guard let bsdName = sender.representedObject as? String else { return }
        onMount?(bsdName)
    }

    @objc private func forceMountVolume(_ sender: NSMenuItem) {
        guard let bsdName = sender.representedObject as? String else { return }
        onForceMount?(bsdName)
    }

    @objc private func openVolume(_ sender: NSMenuItem) {
        guard let bsdName = sender.representedObject as? String else { return }
        onOpen?(bsdName)
    }

    @objc private func ejectVolume(_ sender: NSMenuItem) {
        guard let bsdName = sender.representedObject as? String else { return }
        onEject?(bsdName)
    }

    @objc private func refreshDisks() { onRefresh?() }
    @objc private func showDriverHelp() { onShowDriverHelp?() }
    @objc private func setupHelper() { onSetupHelper?() }
    @objc private func toggleAutoMount() { onToggleAutoMount?() }
    @objc private func toggleOpenFinder() { onToggleOpenFinder?() }
    @objc private func toggleLaunchAtLogin() { onToggleLaunchAtLogin?() }

    @objc private func showAbout() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "NTFSMount",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版",
            .credits: NSAttributedString(string: "自动将外置 NTFS 卷挂载为可读写，并支持 Finder 访问和安全弹出。")
        ])
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func quitApplication() {
        NSApplication.shared.terminate(nil)
    }
}
