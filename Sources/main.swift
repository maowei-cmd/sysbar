import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum MenuBarStyle: String {
        case labeled
        case compact
    }

    private enum MenuBarMetric: Int, CaseIterable {
        case cpu
        case memory
        case disk
        case network

        var title: String {
            switch self {
            case .cpu: return "CPU 温度/使用率"
            case .memory: return "内存占用"
            case .disk: return "硬盘温度"
            case .network: return "网络速度"
            }
        }

        var defaultsKey: String {
            switch self {
            case .cpu: return "showCPU"
            case .memory: return "showMemory"
            case .disk: return "showDisk"
            case .network: return "showNetwork"
            }
        }

        var isVisible: Bool {
            UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
        }
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let cpuSampler = CPUSampler()
    private let memorySampler = MemorySampler()
    private let temperatureReader = TemperatureReader()
    private let networkSampler = NetworkSampler()
    private var timer: Timer?

    private var cpuSample = CPUSample()
    private var memorySample = MemorySample()
    private var networkSample = NetworkSample()
    private var temperatures: [TemperatureReading] = []

    private var interval: TimeInterval = {
        let stored = UserDefaults.standard.double(forKey: "refreshInterval")
        return stored > 0 ? stored : 1.0
    }()

    private var menuBarStyle: MenuBarStyle {
        MenuBarStyle(rawValue: UserDefaults.standard.string(forKey: "menuBarStyle") ?? "") ?? .labeled
    }

    private var highContrastBackground: Bool {
        UserDefaults.standard.object(forKey: "highContrastBackground") as? Bool ?? true
    }

    private let launchAgentLabel = "com.denny.sysbar"
    private let startedAt = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.setAccessibilityLabel("系统监控")
        applyStatusItemBackground()

        _ = cpuSampler.sample()
        tick()
        scheduleTimer()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func tick() {
        cpuSample = cpuSampler.sample()
        memorySample = memorySampler.sample()
        temperatures = temperatureReader.read(scope: .primary)
        networkSample = networkSampler.sample()
        updateStatusItem()
    }

    @objc private func handleWake() {
        _ = cpuSampler.sample()
        _ = networkSampler.sample()
        tick()
    }

    // MARK: - Status item

    private var cpuPrimaryTemperatures: [TemperatureReading] {
        temperatures.filter(\.isCPU)
    }

    private var cpuFallbackTemperatures: [TemperatureReading] {
        temperatures.filter(\.isCPUFallback)
    }

    private var cpuTemperatures: [TemperatureReading] {
        let primary = cpuPrimaryTemperatures
        return primary.isEmpty ? cpuFallbackTemperatures : primary
    }

    private var cpuTemperature: Double? {
        cpuTemperatures.map(\.celsius).max()
    }

    private var cpuUnavailableReason: String {
        if let issue = temperatureReader.initializationIssue { return issue }
        if temperatureReader.totalSensorCount == 0 { return "未发现温度传感器" }
        return "未发现 CPU 温度传感器"
    }

    private var cpuTemperatureSource: String {
        if cpuTemperature != nil {
            if !cpuPrimaryTemperatures.isEmpty { return "PMU tdie" }
            if !cpuFallbackTemperatures.isEmpty { return "备用 CPU 传感器" }
        }
        return cpuUnavailableReason
    }

    private var diskTemperatures: [TemperatureReading] {
        temperatures.filter(\.isDisk)
    }

    private var diskTemperature: Double? {
        diskTemperatures.map(\.celsius).max()
    }

    private var diskUnavailableReason: String {
        if let issue = temperatureReader.initializationIssue { return issue }
        if temperatureReader.totalSensorCount == 0 { return "未发现温度传感器" }
        return "未发现 NAND 温度传感器"
    }

    private var thermalStateDescription: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "正常（nominal）"
        case .fair: return "偏热（fair）"
        case .serious: return "较热（serious）"
        case .critical: return "临界（critical）"
        @unknown default: return "未知"
        }
    }

    private var temperatureColor: NSColor {
        guard let temperature = cpuTemperature else { return .white }
        if temperature >= 100 { return .systemRed }
        if temperature >= 90 { return .systemOrange }
        return .white
    }

    private var diskColor: NSColor {
        guard let temperature = diskTemperature else { return .white }
        if temperature >= 80 { return .systemRed }
        if temperature >= 70 { return .systemOrange }
        return .white
    }

    private var memoryColor: NSColor {
        if memorySample.percent >= 95 { return .systemRed }
        if memorySample.percent >= 90 { return .systemOrange }
        return .white
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let style = menuBarStyle
        let labelFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        var baseAttributes: [NSAttributedString.Key: Any] = [:]
        if !highContrastBackground {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
            shadow.shadowBlurRadius = 1.5
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            baseAttributes[.shadow] = shadow
            baseAttributes[.strokeColor] = NSColor.black.withAlphaComponent(0.25)
            baseAttributes[.strokeWidth] = -1.0
        }

        func attributed(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
            var attributes = baseAttributes
            attributes[.font] = font
            attributes[.foregroundColor] = color
            return NSAttributedString(string: text, attributes: attributes)
        }
        func label(_ text: String) -> NSAttributedString {
            attributed(text, font: labelFont, color: .white)
        }
        func value(_ text: String, color: NSColor = .white) -> NSAttributedString {
            attributed(text, font: valueFont, color: color)
        }

        let temperatureText = cpuTemperature.map { "\(Int($0.rounded()))°" } ?? "--°"
        let cpuText = "\(Int(cpuSample.total.rounded()))%"
        let memoryText = "\(Int(memorySample.percent.rounded()))%"
        let diskText = diskTemperature.map { "\(Int($0.rounded()))°" } ?? "--°"
        let downloadText = "↓\(Self.compactRate(networkSample.downloadPerSecond))"
        let uploadText = "↑\(Self.compactRate(networkSample.uploadPerSecond))"

        var segments: [NSAttributedString] = []

        if MenuBarMetric.cpu.isVisible {
            let segment = NSMutableAttributedString()
            if style == .labeled { segment.append(label("CPU ")) }
            segment.append(value(temperatureText, color: temperatureColor))
            segment.append(attributed("/", font: valueFont, color: .white))
            segment.append(value(cpuText))
            segments.append(segment)
        }

        if MenuBarMetric.memory.isVisible {
            let segment = NSMutableAttributedString()
            if style == .labeled { segment.append(label("RAM ")) }
            segment.append(value(memoryText, color: memoryColor))
            segments.append(segment)
        }

        if MenuBarMetric.disk.isVisible {
            let segment = NSMutableAttributedString()
            if style == .labeled { segment.append(label("SSD ")) }
            segment.append(value(diskText, color: diskColor))
            segments.append(segment)
        }

        if MenuBarMetric.network.isVisible {
            let segment = NSMutableAttributedString()
            segment.append(value(downloadText))
            segment.append(value(uploadText))
            segments.append(segment)
        }

        if segments.isEmpty {
            segments.append(label("系统监控"))
        }

        let title = NSMutableAttributedString()
        let separator = attributed(style == .labeled ? " · " : " ", font: labelFont, color: .white)
        for (index, segment) in segments.enumerated() {
            if index > 0 { title.append(separator) }
            title.append(segment)
        }
        if highContrastBackground {
            let padding = attributed("\u{2009}", font: labelFont, color: .white)
            title.insert(padding, at: 0)
            title.append(padding)
        }
        button.attributedTitle = title

        var tooltip: [String] = []
        if let temperature = cpuTemperature {
            tooltip.append("CPU 温度 \(Self.oneDecimal(temperature))°C（\(cpuTemperatureSource)）")
        } else {
            tooltip.append("CPU 温度 不可用（\(cpuUnavailableReason)）")
        }
        tooltip.append("CPU 使用率 \(Self.oneDecimal(cpuSample.total))%")
        tooltip.append("内存占用 \(Self.oneDecimal(memorySample.percent))%（\(gigabytes(memorySample.used)) / \(gigabytes(memorySample.total)) GB）")
        if let temperature = diskTemperature {
            tooltip.append("硬盘温度 \(Self.oneDecimal(temperature))°C")
        } else {
            tooltip.append("硬盘温度 不可用（\(diskUnavailableReason)）")
        }
        tooltip.append("网络 ↓ \(Self.rateText(networkSample.downloadPerSecond)) ↑ \(Self.rateText(networkSample.uploadPerSecond))")
        button.toolTip = tooltip.joined(separator: " ｜ ") + "\n点击查看详情"
    }

    private func applyStatusItemBackground() {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        button.layer?.masksToBounds = true
        button.layer?.backgroundColor = highContrastBackground
            ? NSColor.black.withAlphaComponent(0.45).cgColor
            : NSColor.clear.cgColor
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        temperatures = temperatureReader.read()

        let totalGigabytes = Int((Double(memorySample.total) / 1_073_741_824).rounded())
        let header = NSMenuItem(
            title: "\(chipName) · \(cpuSample.cores.count) 核 · \(totalGigabytes) GB",
            action: nil,
            keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let temperatureValue: String
        if let temperature = cpuTemperature {
            temperatureValue = "\(Self.oneDecimal(temperature)) °C"
        } else {
            temperatureValue = "不可用"
        }
        menu.addItem(metricItem(
            label: "CPU 温度",
            value: temperatureValue,
            note: cpuTemperature == nil ? nil : (cpuPrimaryTemperatures.isEmpty ? "备用传感器" : "最高核心"),
            valueColor: temperatureColor,
            submenu: makeTemperatureMenu()
        ))

        menu.addItem(metricItem(
            label: "CPU 使用率",
            value: "\(Self.oneDecimal(cpuSample.total))%",
            note: "\(cpuSample.cores.count) 核",
            submenu: makeCoreMenu()
        ))

        menu.addItem(metricItem(
            label: "内存占用",
            value: "\(Self.oneDecimal(memorySample.percent))%",
            note: "\(gigabytes(memorySample.used)) / \(gigabytes(memorySample.total)) GB",
            valueColor: memoryColor,
            submenu: makeMemoryMenu()
        ))

        let diskValue = diskTemperature.map { "\(Self.oneDecimal($0)) °C" } ?? "不可用"
        menu.addItem(metricItem(
            label: "硬盘温度",
            value: diskValue,
            note: diskTemperature == nil ? nil : "内置 SSD",
            valueColor: diskColor,
            submenu: makeDiskTemperatureMenu()
        ))

        let networkNote: String? = {
            guard let primary = networkSample.interfaces.first else { return nil }
            return networkSample.interfaces.count > 1
                ? "\(primary.name) 等 \(networkSample.interfaces.count) 个"
                : primary.name
        }()
        menu.addItem(metricItem(
            label: "网络速度",
            value: "↓ \(Self.rateText(networkSample.downloadPerSecond))  ↑ \(Self.rateText(networkSample.uploadPerSecond))",
            note: networkNote,
            submenu: makeNetworkMenu()
        ))

        menu.addItem(.separator())

        let displayItem = NSMenuItem(title: "菜单栏显示", action: nil, keyEquivalent: "")
        displayItem.submenu = makeDisplayMenu()
        menu.addItem(displayItem)

        let refreshMenu = NSMenu()
        refreshMenu.autoenablesItems = false
        for seconds in [1, 2, 5] {
            let item = NSMenuItem(
                title: "\(seconds) 秒",
                action: #selector(setRefreshInterval(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = seconds
            item.state = abs(interval - Double(seconds)) < 0.01 ? .on : .off
            refreshMenu.addItem(item)
        }
        let refreshItem = NSMenuItem(title: "刷新间隔：\(Int(interval)) 秒", action: nil, keyEquivalent: "")
        refreshItem.submenu = refreshMenu
        menu.addItem(refreshItem)

        let autoStartItem = NSMenuItem(
            title: "开机自动启动",
            action: #selector(toggleAutoStart),
            keyEquivalent: ""
        )
        autoStartItem.target = self
        autoStartItem.state = autoStartEnabled ? .on : .off
        menu.addItem(autoStartItem)

        let diagnosticsItem = NSMenuItem(title: "诊断信息…", action: #selector(showDiagnostics), keyEquivalent: "")
        diagnosticsItem.target = self
        menu.addItem(diagnosticsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出系统监控", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func makeDisplayMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for metric in MenuBarMetric.allCases {
            let item = NSMenuItem(title: metric.title, action: #selector(toggleMetric(_:)), keyEquivalent: "")
            item.target = self
            item.tag = metric.rawValue
            item.state = metric.isVisible ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let labeledItem = NSMenuItem(title: "带标签", action: #selector(setMenuBarStyle(_:)), keyEquivalent: "")
        labeledItem.target = self
        labeledItem.tag = 0
        labeledItem.state = menuBarStyle == .labeled ? .on : .off
        menu.addItem(labeledItem)

        let compactItem = NSMenuItem(title: "紧凑数字", action: #selector(setMenuBarStyle(_:)), keyEquivalent: "")
        compactItem.target = self
        compactItem.tag = 1
        compactItem.state = menuBarStyle == .compact ? .on : .off
        menu.addItem(compactItem)

        menu.addItem(.separator())
        let contrastItem = NSMenuItem(title: "高对比底色", action: #selector(toggleHighContrastBackground), keyEquivalent: "")
        contrastItem.target = self
        contrastItem.state = highContrastBackground ? .on : .off
        menu.addItem(contrastItem)
        return menu
    }

    private func makeTemperatureMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let primary = cpuPrimaryTemperatures.sorted { $0.celsius > $1.celsius }
        let fallback = cpuFallbackTemperatures.sorted { $0.celsius > $1.celsius }
        let active = primary.isEmpty ? fallback : primary
        let otherReadings = temperatures
            .filter { !$0.isCPU && !$0.isCPUFallback && !$0.isDisk }
            .sorted { $0.celsius > $1.celsius }

        if active.isEmpty {
            menu.addItem(disabledItem("CPU 温度不可用：\(cpuUnavailableReason)"))
            menu.addItem(disabledItem("系统热状态：\(thermalStateDescription)"))
        } else {
            menu.addItem(disabledItem(primary.isEmpty ? "CPU 温度（备用传感器）" : "CPU 核心（PMU tdie）"))
            for reading in active {
                menu.addItem(sensorItem(reading))
            }
        }

        if !otherReadings.isEmpty {
            menu.addItem(.separator())
            menu.addItem(disabledItem("其他传感器"))
            for reading in otherReadings.prefix(30) {
                menu.addItem(sensorItem(reading))
            }
        }
        return menu
    }

    private func makeCoreMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(disabledItem("总体：\(Self.oneDecimal(cpuSample.total))%"))
        if !cpuSample.cores.isEmpty {
            menu.addItem(.separator())
            for (index, usage) in cpuSample.cores.enumerated() {
                menu.addItem(disabledItem("核心 \(index + 1)：\(Self.oneDecimal(usage))%", monospaced: true))
            }
        }
        return menu
    }

    private func makeMemoryMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(disabledItem("已用合计：\(Self.oneDecimal(memorySample.percent))%（\(gigabytes(memorySample.used)) GB）"))
        menu.addItem(disabledItem("App 内存：\(gigabytes(memorySample.app)) GB"))
        menu.addItem(disabledItem("常驻内存：\(gigabytes(memorySample.wired)) GB"))
        menu.addItem(disabledItem("压缩内存：\(gigabytes(memorySample.compressed)) GB"))
        menu.addItem(disabledItem("可清除：\(gigabytes(memorySample.purgeable)) GB"))
        menu.addItem(disabledItem("空闲：\(gigabytes(memorySample.free)) GB"))
        menu.addItem(.separator())
        menu.addItem(disabledItem("物理内存：\(gigabytes(memorySample.total)) GB"))
        return menu
    }

    private func makeDiskTemperatureMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let readings = diskTemperatures.sorted { $0.celsius > $1.celsius }
        guard !readings.isEmpty else {
            menu.addItem(disabledItem("硬盘温度不可用：\(diskUnavailableReason)"))
            menu.addItem(disabledItem("内置 SSD 可能不暴露 NAND 温度传感器"))
            menu.addItem(disabledItem("系统热状态：\(thermalStateDescription)"))
            return menu
        }
        menu.addItem(disabledItem("内置 SSD（NAND）"))
        for reading in readings {
            menu.addItem(sensorItem(reading))
        }
        return menu
    }

    private func makeNetworkMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(disabledItem("总计：↓ \(Self.rateText(networkSample.downloadPerSecond))  ↑ \(Self.rateText(networkSample.uploadPerSecond))"))
        menu.addItem(disabledItem("累计：↓ \(Self.trafficText(networkSample.receivedTotal))  ↑ \(Self.trafficText(networkSample.sentTotal))"))
        guard !networkSample.interfaces.isEmpty else {
            menu.addItem(.separator())
            menu.addItem(disabledItem("没有活动网卡"))
            return menu
        }
        for interface in networkSample.interfaces {
            menu.addItem(.separator())
            if let address = interface.ipAddress {
                menu.addItem(disabledItem("\(interface.name) · \(address)"))
            } else {
                menu.addItem(disabledItem(interface.name))
            }
            menu.addItem(disabledItem(
                "下载：\(Self.rateText(interface.downloadPerSecond))　累计 \(Self.trafficText(interface.receivedTotal))",
                monospaced: true
            ))
            menu.addItem(disabledItem(
                "上传：\(Self.rateText(interface.uploadPerSecond))　累计 \(Self.trafficText(interface.sentTotal))",
                monospaced: true
            ))
        }
        return menu
    }

    private func metricItem(
        label: String,
        value: String,
        note: String? = nil,
        valueColor: NSColor = .labelColor,
        submenu: NSMenu?
    ) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let title = NSMutableAttributedString()
        title.append(NSAttributedString(
            string: label + "：",
            attributes: [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        ))
        title.append(NSAttributedString(
            string: value,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: valueColor
            ]
        ))
        if let note {
            title.append(NSAttributedString(
                string: "  " + note,
                attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            ))
        }
        item.attributedTitle = title
        item.submenu = submenu
        item.isEnabled = true
        return item
    }

    private func sensorItem(_ reading: TemperatureReading) -> NSMenuItem {
        let item = disabledItem(
            String(format: "%@   %.1f °C", reading.name, reading.celsius),
            monospaced: true
        )
        return item
    }

    private func disabledItem(_ title: String, monospaced: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if monospaced {
            item.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)]
            )
        }
        return item
    }

    // MARK: - Preferences

    @objc private func toggleMetric(_ sender: NSMenuItem) {
        guard let metric = MenuBarMetric(rawValue: sender.tag) else { return }
        if metric.isVisible && MenuBarMetric.allCases.filter({ $0.isVisible }).count <= 1 {
            NSSound.beep()
            return
        }
        UserDefaults.standard.set(!metric.isVisible, forKey: metric.defaultsKey)
        updateStatusItem()
    }

    @objc private func setMenuBarStyle(_ sender: NSMenuItem) {
        let style: MenuBarStyle = sender.tag == 1 ? .compact : .labeled
        UserDefaults.standard.set(style.rawValue, forKey: "menuBarStyle")
        updateStatusItem()
    }

    @objc private func toggleHighContrastBackground() {
        UserDefaults.standard.set(!highContrastBackground, forKey: "highContrastBackground")
        applyStatusItemBackground()
        updateStatusItem()
    }

    @objc private func setRefreshInterval(_ sender: NSMenuItem) {
        interval = Double(sender.tag)
        UserDefaults.standard.set(interval, forKey: "refreshInterval")
        scheduleTimer()
    }

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(launchAgentLabel).plist")
    }

    private var autoStartEnabled: Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    @objc private func toggleAutoStart() {
        if !autoStartEnabled && Bundle.main.bundlePath.hasPrefix("/Volumes/") {
            presentError(
                "请先把应用安装到“应用程序”",
                detail: "从磁盘映像直接运行无法设置开机启动。请将「系统监控.app」拖到“应用程序”文件夹后再打开。"
            )
            return
        }

        let fileManager = FileManager.default
        if autoStartEnabled {
            do {
                try fileManager.removeItem(at: launchAgentURL)
            } catch {
                presentError("无法关闭开机自动启动", detail: error.localizedDescription)
            }
            return
        }

        guard let executablePath = Bundle.main.executablePath else { return }
        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua"
        ]
        do {
            try fileManager.createDirectory(
                at: launchAgentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: launchAgentURL, options: .atomic)
        } catch {
            presentError("无法开启开机自动启动", detail: error.localizedDescription)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func presentError(_ message: String, detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func showDiagnostics() {
        let report = diagnosticsReport()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "系统监控诊断"
        alert.informativeText = report
        alert.addButton(withTitle: "复制诊断")
        alert.addButton(withTitle: "关闭")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
        }
    }

    private func diagnosticsReport() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

        let cpuText: String
        if let temperature = cpuTemperature {
            cpuText = "\(Self.oneDecimal(temperature))°C（\(cpuTemperatureSource)）"
        } else {
            cpuText = "不可用（\(cpuUnavailableReason)）"
        }

        let diskText: String
        if let temperature = diskTemperature {
            diskText = "\(Self.oneDecimal(temperature))°C（\(diskTemperatures.map(\.name).joined(separator: "、"))）"
        } else {
            diskText = "不可用（\(diskUnavailableReason)）"
        }

        let sensorText: String
        if let issue = temperatureReader.initializationIssue {
            sensorText = issue
        } else {
            sensorText = "IOHID 可用｜共 \(temperatureReader.totalSensorCount) 个温度传感器（CPU \(temperatureReader.cpuPrimarySensorNames.count)、备用 \(temperatureReader.cpuFallbackSensorNames.count)、存储 \(temperatureReader.diskSensorNames.count)）"
        }

        let networkText: String
        if let primary = networkSample.interfaces.first {
            networkText = "\(primary.name) \(primary.ipAddress ?? "无 IPv4")｜↓ \(Self.rateText(networkSample.downloadPerSecond)) ↑ \(Self.rateText(networkSample.uploadPerSecond))"
        } else {
            networkText = "无活动网卡"
        }

        let visibleMetrics = MenuBarMetric.allCases.filter { $0.isVisible }.map(\.title).joined(separator: "、")
        let styleName = menuBarStyle == .labeled ? "带标签" : "紧凑数字"

        return [
            "版本 \(version)（\(build)）",
            "系统：\(ProcessInfo.processInfo.operatingSystemVersionString)｜\(hardwareModel)｜\(architectureName)",
            "运行时间 \(Self.durationText(Date().timeIntervalSince(startedAt)))",
            "CPU 温度：\(cpuText)",
            "硬盘温度：\(diskText)",
            "温度接口：\(sensorText)",
            "系统热状态：\(thermalStateDescription)",
            "网络：\(networkText)",
            "刷新间隔：\(Int(interval)) 秒",
            "菜单栏：\(styleName)｜高对比底色：\(highContrastBackground ? "开" : "关")",
            "显示项：\(visibleMetrics)",
            "开机自启：\(autoStartEnabled ? "已开启" : "已关闭")",
            "应用：\(Bundle.main.bundlePath)"
        ].joined(separator: "\n")
    }

    // MARK: - Helpers

    private lazy var chipName: String = {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "Mac" }
        return String(cString: buffer)
    }()

    private lazy var hardwareModel: String = {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "未知机型" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "未知机型" }
        return String(cString: buffer)
    }()

    private var architectureName: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }

    private static func compactRate(_ rate: Double) -> String {
        if rate < 1_000 { return "\(Int(rate.rounded()))B" }
        if rate < 10_000 { return String(format: "%.1fK", rate / 1_000) }
        if rate < 1_000_000 { return String(format: "%.0fK", rate / 1_000) }
        if rate < 10_000_000 { return String(format: "%.1fM", rate / 1_000_000) }
        if rate < 1_000_000_000 { return String(format: "%.0fM", rate / 1_000_000) }
        return String(format: "%.1fG", rate / 1_000_000_000)
    }

    private static func rateText(_ rate: Double) -> String {
        if rate < 1_000 { return String(format: "%.0f B/s", rate) }
        if rate < 1_000_000 { return String(format: "%.1f KB/s", rate / 1_000) }
        if rate < 1_000_000_000 { return String(format: "%.1f MB/s", rate / 1_000_000) }
        return String(format: "%.2f GB/s", rate / 1_000_000_000)
    }

    private static func trafficText(_ bytes: UInt64) -> String {
        let gigabytes = Double(bytes) / 1_000_000_000
        if gigabytes >= 1 { return String(format: "%.1f GB", gigabytes) }
        let megabytes = Double(bytes) / 1_000_000
        if megabytes >= 1 { return String(format: "%.1f MB", megabytes) }
        return String(format: "%.0f KB", Double(bytes) / 1_000)
    }

    private static func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        if minutes > 0 { return "\(minutes) 分" }
        return "\(total) 秒"
    }
}

// MARK: - Diagnostics

if CommandLine.arguments.contains("--dump") {
    let cpuSampler = CPUSampler()
    let networkSampler = NetworkSampler()
    _ = cpuSampler.sample()
    _ = networkSampler.sample()
    Thread.sleep(forTimeInterval: 1)
    let cpu = cpuSampler.sample()
    let network = networkSampler.sample()
    let memory = MemorySampler().sample()
    let reader = TemperatureReader()
    let temperatures = reader.read()
    let primaryCPU = temperatures.filter(\.isCPU)
    let fallbackCPU = temperatures.filter(\.isCPUFallback)
    let activeCPU = primaryCPU.isEmpty ? fallbackCPU : primaryCPU
    let diskTemperatures = temperatures.filter(\.isDisk)

    print("CPU_USAGE \(String(format: "%.1f", cpu.total))% (\(cpu.cores.count) cores)")
    if let maximum = activeCPU.map(\.celsius).max() {
        let source = primaryCPU.isEmpty ? "fallback" : "PMU tdie"
        print("CPU_TEMP \(String(format: "%.1f", maximum))°C (max of \(activeCPU.count) sensors, source=\(source))")
    } else {
        print("CPU_TEMP unavailable (\(reader.initializationIssue ?? "未发现 CPU 温度传感器"))")
    }
    print("MEMORY \(String(format: "%.1f", memory.percent))% (\(String(format: "%.1f", Double(memory.used) / 1_073_741_824)) / \(String(format: "%.1f", Double(memory.total) / 1_073_741_824)) GB)")
    if let maximum = diskTemperatures.map(\.celsius).max() {
        print("DISK_TEMP \(String(format: "%.1f", maximum))°C (\(diskTemperatures.map(\.name).joined(separator: ", ")))")
    } else {
        print("DISK_TEMP unavailable (\(reader.initializationIssue ?? "未发现 NAND 温度传感器"))")
    }
    let interfaces = network.interfaces.map { "\($0.name)\($0.ipAddress.map { "=\($0)" } ?? "")" }.joined(separator: ", ")
    print("NETWORK ↓\(Int(network.downloadPerSecond)) B/s ↑\(Int(network.uploadPerSecond)) B/s [\(interfaces)]")
    let thermal: String
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: thermal = "nominal"
    case .fair: thermal = "fair"
    case .serious: thermal = "serious"
    case .critical: thermal = "critical"
    @unknown default: thermal = "unknown"
    }
    print("THERMAL_STATE \(thermal)")
    if let issue = reader.initializationIssue {
        print("TEMP_ISSUE \(issue)")
    }
    print("SENSORS \(temperatures.count) total, \(primaryCPU.count) primary CPU, \(fallbackCPU.count) fallback CPU, \(diskTemperatures.count) storage")
    exit(0)
}

// MARK: - Single instance

if let bundleIdentifier = Bundle.main.bundleIdentifier {
    let otherInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        .filter { $0.processIdentifier != getpid() }
    if !otherInstances.isEmpty {
        exit(0)
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
