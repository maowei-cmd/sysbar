import AppKit

final class UpdateManager: NSObject, URLSessionDownloadDelegate {
    struct Release {
        let version: AppVersion
        let tag: String
        let notes: String
        let assetName: String
        let assetURL: URL
    }
    struct InstallPlan {
        let stagedApp: URL
        let targetApp: URL
        let scriptURL: URL
        let logURL: URL
        let workDirectory: URL
    }

    enum UpdateError: LocalizedError {
        case badResponse
        case http(Int, String)
        case invalidRelease
        case noDMG
        case emptyDownload
        case mountFailed(String)
        case missingApp
        case invalidBundle(String)
        case notWritable(String)
        case installFailed(String)
        case checkFailed(String)

        var errorDescription: String? {
            switch self {
            case .badResponse:
                return "GitHub 返回了无法识别的响应。"
            case .http(let code, let message):
                return "GitHub 请求失败（HTTP \(code)）。\(message)"
            case .invalidRelease:
                return "无法解析最新版本信息。"
            case .noDMG:
                return "最新版本没有提供 DMG 安装包。"
            case .emptyDownload:
                return "下载的安装包为空或无效。"
            case .mountFailed(let detail):
                return "无法打开下载的磁盘映像。\(detail)"
            case .missingApp:
                return "磁盘映像中未找到应用。"
            case .invalidBundle(let detail):
                return "更新包校验失败：\(detail)"
            case .notWritable(let path):
                return "没有权限写入 \(path)。请确认应用位于“应用程序”文件夹，且当前用户有管理员权限。"
            case .installFailed(let detail):
                return "无法启动更新安装：\(detail)"
            case .checkFailed(let detail):
                return detail
            }
        }
    }

    static let repository = "maowei-cmd/sysbar"
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    static let releasesAtomURL = URL(string: "https://github.com/\(repository)/releases.atom")!

    let currentVersion: AppVersion
    let bundleIdentifier: String

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private var checkTask: URLSessionDataTask?
    private var checkCancelled = false
    private var downloadTask: URLSessionDownloadTask?
    private var downloadHandler: ((Result<URL, Error>) -> Void)?
    private var progressHandler: ((Double) -> Void)?

    init(currentVersion: String, bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.denny.sysbar") {
        self.currentVersion = AppVersion(currentVersion) ?? AppVersion("0")!
        self.bundleIdentifier = bundleIdentifier
        super.init()
    }

    // MARK: - Checking

    func checkForUpdates(completion: @escaping (Result<Release?, Error>) -> Void) {
        checkCancelled = false
        checkViaAtom(completion: completion)
    }

    private func checkViaAtom(completion: @escaping (Result<Release?, Error>) -> Void) {
        var request = URLRequest(url: Self.releasesAtomURL)
        request.timeoutInterval = 12
        request.setValue(
            "application/atom+xml, application/xml;q=0.9, */*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("SysBar/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let currentVersion = currentVersion
        checkTask = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            DispatchQueue.main.async {
                guard !self.checkCancelled else { return }
                if let error {
                    self.checkViaAPI(completion: completion, atomError: error)
                    return
                }
                guard
                    let http = response as? HTTPURLResponse,
                    (200..<300).contains(http.statusCode),
                    let data,
                    let release = Self.decodeAtomRelease(from: data)
                else {
                    let atomError: Error
                    if let http = response as? HTTPURLResponse {
                        atomError = UpdateError.http(http.statusCode, "无法读取 Releases 源。")
                    } else {
                        atomError = UpdateError.badResponse
                    }
                    self.checkViaAPI(completion: completion, atomError: atomError)
                    return
                }
                let result: Release? = release.version > currentVersion ? release : nil
                completion(.success(result))
            }
        }
        checkTask?.resume()
    }

    private func checkViaAPI(completion: @escaping (Result<Release?, Error>) -> Void, atomError: Error?) {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.timeoutInterval = 12
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SysBar/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let currentVersion = currentVersion
        checkTask = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            DispatchQueue.main.async {
                guard !self.checkCancelled else { return }
                if let error {
                    completion(.failure(Self.combinedCheckError(atomError: atomError, apiError: error)))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    completion(.failure(Self.combinedCheckError(atomError: atomError, apiError: UpdateError.badResponse)))
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    let message: String
                    switch http.statusCode {
                    case 404:
                        message = "仓库还没有发布任何版本。"
                    case 403:
                        message = "请求过于频繁，请稍后再试。\(Self.apiMessage(from: data))"
                    default:
                        message = Self.apiMessage(from: data)
                    }
                    let apiError = UpdateError.http(http.statusCode, message)
                    completion(.failure(Self.combinedCheckError(atomError: atomError, apiError: apiError)))
                    return
                }
                do {
                    let release = try Self.decodeRelease(from: data)
                    let result: Release? = release.version > currentVersion ? release : nil
                    completion(.success(result))
                } catch {
                    completion(.failure(Self.combinedCheckError(atomError: atomError, apiError: error)))
                }
            }
        }
        checkTask?.resume()
    }

    private static func combinedCheckError(atomError: Error?, apiError: Error) -> Error {
        if let atomError {
            return UpdateError.checkFailed(
                "暂时无法检查更新。Releases 源：\(atomError.localizedDescription) GitHub API：\(apiError.localizedDescription)"
            )
        }
        return apiError
    }

    func cancelCheck() {
        checkCancelled = true
        checkTask?.cancel()
        checkTask = nil
    }

    private static func apiMessage(from data: Data?) -> String {
        guard
            let data,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = object["message"] as? String
        else { return "" }
        return message
    }

    private static func decodeRelease(from data: Data?) throws -> Release {
        guard let data else { throw UpdateError.invalidRelease }
        let payload: GitHubRelease
        do {
            payload = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateError.invalidRelease
        }
        guard let version = AppVersion(payload.tagName) else {
            throw UpdateError.invalidRelease
        }

        let dmgAssets = payload.assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        guard !dmgAssets.isEmpty else { throw UpdateError.noDMG }
        let asset = dmgAssets.first(where: {
            $0.name.range(of: "AppleSilicon", options: .caseInsensitive) != nil
        }) ?? dmgAssets[0]

        guard let assetURL = URL(string: "https://api.github.com/repos/\(repository)/releases/assets/\(asset.id)") else {
            throw UpdateError.badResponse
        }

        return Release(
            version: version,
            tag: payload.tagName,
            notes: payload.body ?? "",
            assetName: asset.name,
            assetURL: assetURL
        )
    }

    private static func decodeAtomRelease(from data: Data) -> Release? {
        let atom = ReleasesAtomParser()
        let parser = XMLParser(data: data)
        parser.delegate = atom
        guard parser.parse(), let entry = atom.firstEntry else { return nil }
        guard
            let link = URL(string: entry.link),
            link.host?.lowercased() == "github.com"
        else { return nil }

        let tag = link.lastPathComponent
        guard !tag.isEmpty, let version = AppVersion(tag) else { return nil }

        let assetName = "SysBar-\(version)-AppleSilicon.dmg"
        guard let assetURL = URL(string: "https://github.com/\(repository)/releases/download/\(tag)/\(assetName)") else {
            return nil
        }

        let notes = plainText(fromHTML: entry.content)
        return Release(
            version: version,
            tag: tag,
            notes: notes.isEmpty ? entry.title : notes,
            assetName: assetName,
            assetURL: assetURL
        )
    }

    private static func plainText(fromHTML html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<li>", with: "• ", options: .regularExpression)
        text = text.replacingOccurrences(of: "</li>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "</p>|</h[1-6]>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Downloading

    func download(_ release: Release, progress: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        cancelDownload()
        progressHandler = progress
        downloadHandler = completion
        var request = URLRequest(url: release.assetURL)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("SysBar/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        downloadTask = task
        task.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadHandler = nil
        progressHandler = nil
    }

    func cancelAll() {
        cancelCheck()
        cancelDownload()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let fraction: Double
        if totalBytesExpectedToWrite > 0 {
            fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        } else {
            fraction = 0
        }
        DispatchQueue.main.async { [weak self] in
            self?.progressHandler?(min(max(fraction, 0), 1))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let handler = downloadHandler else { return }
        downloadHandler = nil
        self.downloadTask = nil
        progressHandler = nil

        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            DispatchQueue.main.async {
                handler(.failure(UpdateError.http(http.statusCode, "")))
            }
            return
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("SysBar-\(UUID().uuidString).dmg")
        do {
            let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else { throw UpdateError.emptyDownload }
            try FileManager.default.moveItem(at: location, to: destination)
            DispatchQueue.main.async { handler(.success(destination)) }
        } catch {
            DispatchQueue.main.async { handler(.failure(error)) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let handler = downloadHandler else { return }
        downloadHandler = nil
        downloadTask = nil
        progressHandler = nil
        DispatchQueue.main.async { handler(.failure(error)) }
    }

    // MARK: - Installing

    func prepareInstall(dmgURL: URL, release: Release, targetApp: URL? = nil) throws -> InstallPlan {
        let target = (targetApp ?? URL(fileURLWithPath: Bundle.main.bundlePath)).standardizedFileURL
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.notWritable(parent.path)
        }

        let fileManager = FileManager.default
        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("SysBarUpdate-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: dmgURL) }

        do {
            let stagedApp = try stageApplication(from: dmgURL, release: release, workDirectory: workDirectory)
            let logURL = workDirectory.appendingPathComponent("install.log")
            let scriptURL = workDirectory.appendingPathComponent("install.sh")
            try Self.installerScript.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            return InstallPlan(
                stagedApp: stagedApp,
                targetApp: target,
                scriptURL: scriptURL,
                logURL: logURL,
                workDirectory: workDirectory
            )
        } catch {
            try? fileManager.removeItem(at: workDirectory)
            throw error
        }
    }

    func launchInstaller(_ plan: InstallPlan) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            plan.scriptURL.path,
            plan.stagedApp.path,
            plan.targetApp.path,
            String(getpid()),
            plan.logURL.path
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdateError.installFailed(error.localizedDescription)
        }
    }

    func cleanup(_ plan: InstallPlan) {
        try? FileManager.default.removeItem(at: plan.workDirectory)
    }

    private func stageApplication(from dmgURL: URL, release: Release, workDirectory: URL) throws -> URL {
        let fileManager = FileManager.default
        let mountPoint = workDirectory.appendingPathComponent("mount", isDirectory: true)
        try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        let attach = try runProcess("/usr/bin/hdiutil", [
            "attach", "-nobrowse", "-readonly", "-mountpoint", mountPoint.path, dmgURL.path
        ])
        guard attach.status == 0 else {
            throw UpdateError.mountFailed(attach.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        defer { _ = try? runProcess("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"]) }

        let contents = try fileManager.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)
        guard let sourceApp = contents.first(where: { $0.pathExtension.lowercased() == "app" }) else {
            throw UpdateError.missingApp
        }

        let stagedApp = workDirectory.appendingPathComponent(sourceApp.lastPathComponent, isDirectory: true)
        let copy = try runProcess("/usr/bin/ditto", [sourceApp.path, stagedApp.path])
        guard copy.status == 0 else {
            throw UpdateError.invalidBundle(copy.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        try verifyApplication(at: stagedApp, release: release)
        let signature = try runProcess("/usr/bin/codesign", ["--verify", "--deep", "--strict", stagedApp.path])
        guard signature.status == 0 else {
            throw UpdateError.invalidBundle(signature.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return stagedApp
    }

    private func verifyApplication(at appURL: URL, release: Release) throws {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard
            let data = try? Data(contentsOf: infoURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            throw UpdateError.invalidBundle("缺少 Info.plist")
        }
        guard plist["CFBundleIdentifier"] as? String == bundleIdentifier else {
            throw UpdateError.invalidBundle("Bundle ID 不匹配")
        }
        guard
            let versionString = plist["CFBundleShortVersionString"] as? String,
            let version = AppVersion(versionString),
            version >= release.version
        else {
            throw UpdateError.invalidBundle("版本号不匹配")
        }
    }

    private func runProcess(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static let installerScript = """
    #!/bin/bash
    set -u
    stage="$1"
    target="$2"
    pid="$3"
    log="$4"
    exec >"$log" 2>&1
    echo "SysBar update started at $(date)"
    echo "stage=$stage"
    echo "target=$target"
    echo "old pid=$pid"

    for _ in $(seq 1 150); do
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        sleep 0.1
    done

    if kill -0 "$pid" 2>/dev/null; then
        echo "old process is still running; aborting"
        exit 1
    fi

    new="$target.new"
    backup="$target.old"
    rm -rf "$new"
    if ! /usr/bin/ditto "$stage" "$new"; then
        echo "copy failed"
        exit 1
    fi
    /usr/bin/xattr -dr com.apple.quarantine "$new" 2>/dev/null || true
    if ! /usr/bin/codesign --verify --deep --strict "$new"; then
        echo "signature verification failed"
        rm -rf "$new"
        exit 1
    fi

    rm -rf "$backup"
    if [ -e "$target" ] && ! mv "$target" "$backup"; then
        echo "could not move current app"
        rm -rf "$new"
        exit 1
    fi
    if ! mv "$new" "$target"; then
        echo "could not install new app; restoring"
        if [ -e "$backup" ]; then mv "$backup" "$target"; fi
        /usr/bin/open "$target" 2>/dev/null || true
        exit 1
    fi
    rm -rf "$backup"
    /usr/bin/open "$target"
    status=$?
    echo "open status=$status"
    rm -rf "$(dirname "$stage")"
    exit $status
    """

    private struct GitHubRelease: Decodable {
        let tagName: String
        let body: String?
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body
            case assets
        }
    }

    private struct GitHubAsset: Decodable {
        let id: Int
        let name: String
    }
}

private final class ReleasesAtomParser: NSObject, XMLParserDelegate {
    struct Entry {
        let title: String
        let content: String
        let link: String
    }

    private(set) var firstEntry: Entry?
    private var inEntry = false
    private var inTitle = false
    private var inContent = false
    private var title = ""
    private var content = ""
    private var link: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName.lowercased() {
        case "entry":
            if firstEntry == nil {
                inEntry = true
                inTitle = false
                inContent = false
                title = ""
                content = ""
                link = nil
            } else {
                inEntry = false
            }
        case "title":
            if inEntry { inTitle = true }
        case "content":
            if inEntry { inContent = true }
        case "link":
            if inEntry, link == nil {
                let relation = attributeDict["rel"] ?? "alternate"
                if relation == "alternate" {
                    link = attributeDict["href"]
                }
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTitle { title += string }
        if inContent { content += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let string = String(data: CDATABlock, encoding: .utf8) else { return }
        if inTitle { title += string }
        if inContent { content += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName.lowercased() {
        case "title":
            inTitle = false
        case "content":
            inContent = false
        case "entry":
            if inEntry, firstEntry == nil {
                firstEntry = Entry(
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    content: content,
                    link: link ?? ""
                )
            }
            inEntry = false
        default:
            break
        }
    }
}

final class UpdateProgressPanel: NSPanel {
    private let statusLabel = NSTextField(labelWithString: "")
    private let indicator = NSProgressIndicator()
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private var cancelHandler: (() -> Void)?

    init(status: String, indeterminate: Bool, onCancel: @escaping () -> Void) {
        cancelHandler = onCancel
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 128),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        title = "软件更新"
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        statusLabel.stringValue = status
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.lineBreakMode = .byTruncatingMiddle

        indicator.style = .bar
        indicator.isIndeterminate = indeterminate
        indicator.minValue = 0
        indicator.maxValue = 1
        if indeterminate {
            indicator.startAnimation(nil)
        }

        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let content = NSView()
        for view in [statusLabel, indicator, cancelButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            indicator.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            indicator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            indicator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            cancelButton.topAnchor.constraint(equalTo: indicator.bottomAnchor, constant: 14),
            cancelButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            cancelButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancelButton.widthAnchor.constraint(equalToConstant: 80)
        ])
        contentView = content
        center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    func setProgress(_ value: Double) {
        indicator.doubleValue = min(max(value, 0), 1)
    }

    func setIndeterminate() {
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)
    }

    func setCancelEnabled(_ enabled: Bool) {
        cancelButton.isEnabled = enabled
    }

    @objc private func cancelPressed() {
        cancelHandler?()
    }
}
