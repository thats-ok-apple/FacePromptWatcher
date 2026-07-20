import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import UserNotifications
import Vision

struct MonitorConfig: Codable, Equatable {
    var scanIntervalSeconds: Double
    var reminderRepeatSeconds: Double
    var windowTerms: [String]
    var keywords: [String]

    static let defaults = MonitorConfig(
        scanIntervalSeconds: 1.0,
        reminderRepeatSeconds: 10,
        windowTerms: [
            "iPhone Mirroring",
            "iPhone 镜像",
            "iPhone镜像"
        ],
        keywords: [
            "人脸识别",
            "人脸认证",
            "人脸验证",
            "请确认由本人亲自操作",
            "开始人脸认证"
        ]
    )
}

struct WindowCandidate: Equatable {
    let id: CGWindowID
    let ownerName: String
    let windowName: String
    let bounds: CGRect

    var displayName: String {
        windowName.isEmpty ? ownerName : "\(ownerName) - \(windowName)"
    }
}

private struct MirrorRegion: Equatable {
    let candidate: WindowCandidate
    let displayID: CGDirectDisplayID
    let sourceRect: CGRect
    let outputWidth: Int
    let outputHeight: Int
    let isClippedToDisplay: Bool
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private static let minimumWindowRefreshInterval: TimeInterval = 2
    private static let maximumWindowRefreshTolerance: TimeInterval = 0.25
    private static let maximumOCRLongSide = 1100.0

    private let config = AppDelegate.loadConfig()
    private let streamQueue = DispatchQueue(label: "local.codex.FacePromptWatcher.capture")
    private let decisiveFaceTerms = [
        "人脸识别", "人臉識別", "人脸认证", "人脸验证",
        "本人亲自操作", "本人親自操作", "开始人脸认证", "開始人臉認證",
        "拍照时请注意保护个人隐私", "拍照時請注意保護個人隱私"
    ]

    private var window: NSWindow!
    private var statusLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var ruleLabel: NSTextField!
    private var notificationLabel: NSTextField!
    private var startButton: NSButton!
    private var pauseButton: NSButton!
    private var acknowledgeButton: NSButton!
    private var settingsButton: NSButton!
    private var testNotificationButton: NSButton!
    private var notificationSettingsButton: NSButton!

    private var trackingTimer: Timer?
    private var stream: SCStream?
    private var streamReceiver: StreamReceiver?
    private var activeRegion: MirrorRegion?
    private var regionUpdateGeneration = 0
    private var occlusionChecks = 0
    private var isMonitoring = false
    private var isRegionOccluded = false
    private var alertActive = false
    private var requiresPromptToClear = false
    private var pendingHit = ""
    private var pendingSource = ""
    private var pendingHitCount = 0
    private var consecutivePromptMisses = 0
    private var notificationSubmissionInFlight = false
    private var alertNotificationSubmitted = false
    private var alertGeneration = 0
    private var activeAlertNotificationID: String?
    private lazy var textRequest: VNRecognizeTextRequest = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["zh-Hans"]
        request.customWords = decisiveFaceTerms
        request.minimumTextHeight = 0.015
        return request
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        UNUserNotificationCenter.current().delegate = self
        buildWindow()
        requestNotificationPermission()
        startMonitoring()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 372),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "科目一人脸提示提醒"
        window.center()

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "正在准备检测...")
        statusLabel.font = .systemFont(ofSize: 22, weight: .semibold)

        detailLabel = NSTextField(labelWithString: "请让 iPhone 镜像窗口保持可见且不被遮挡。")
        detailLabel.font = .systemFont(ofSize: 14)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 4
        detailLabel.lineBreakMode = .byWordWrapping

        ruleLabel = NSTextField(labelWithString: "后台区域流：仅识别 iPhone 镜像窗口内的明确提示文字")
        ruleLabel.font = .systemFont(ofSize: 12)
        ruleLabel.textColor = .tertiaryLabelColor
        ruleLabel.maximumNumberOfLines = 2
        ruleLabel.lineBreakMode = .byWordWrapping

        notificationLabel = NSTextField(labelWithString: "系统通知：正在检查授权状态…")
        notificationLabel.font = .systemFont(ofSize: 12)
        notificationLabel.textColor = .secondaryLabelColor
        notificationLabel.maximumNumberOfLines = 2
        notificationLabel.lineBreakMode = .byWordWrapping

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let notificationButtons = NSStackView()
        notificationButtons.orientation = .horizontal
        notificationButtons.spacing = 10

        startButton = NSButton(title: "开始检测", target: self, action: #selector(startClicked))
        pauseButton = NSButton(title: "暂停", target: self, action: #selector(pauseClicked))
        acknowledgeButton = NSButton(title: "已处理", target: self, action: #selector(acknowledgeClicked))
        settingsButton = NSButton(title: "录屏权限", target: self, action: #selector(openSettingsClicked))
        testNotificationButton = NSButton(title: "测试系统提醒", target: self, action: #selector(testNotificationClicked))
        notificationSettingsButton = NSButton(title: "通知设置", target: self, action: #selector(openNotificationSettingsClicked))
        let quitButton = NSButton(title: "退出", target: self, action: #selector(quitClicked))

        [startButton, pauseButton, acknowledgeButton, quitButton].forEach(buttons.addArrangedSubview)
        [testNotificationButton, notificationSettingsButton, settingsButton].forEach(notificationButtons.addArrangedSubview)
        [statusLabel, detailLabel, ruleLabel, notificationLabel, buttons, notificationButtons].forEach(root.addArrangedSubview)

        window.contentView = NSView()
        window.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 570),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 570),
            ruleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 570),
            notificationLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 570)
        ])

        acknowledgeButton.isEnabled = false
        settingsButton.isEnabled = false
        notificationSettingsButton.isEnabled = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func startClicked() {
        startMonitoring()
    }

    @objc private func pauseClicked() {
        stopMonitoring(message: "已暂停", detail: "点击“开始检测”即可继续。")
    }

    @objc private func acknowledgeClicked() {
        requiresPromptToClear = alertActive
        clearAlert(message: "已处理，继续检测", detail: "当前提示页离开后，下一次出现时才会再次提醒。")
    }

    @objc private func openSettingsClicked() {
        openScreenRecordingSettings()
    }

    @objc private func testNotificationClicked() {
        sendSystemNotification(
            title: "FacePromptWatcher 测试提醒",
            body: "这是一条 macOS 系统通知测试。",
            isTest: true
        )
    }

    @objc private func openNotificationSettingsClicked() {
        openNotificationSettings()
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    private func startMonitoring() {
        stopCaptureStream()
        trackingTimer?.invalidate()
        isMonitoring = true
        isRegionOccluded = false
        startButton.isEnabled = false
        pauseButton.isEnabled = true
        acknowledgeButton.isEnabled = alertActive
        settingsButton.isEnabled = false
        updateStatus("正在检测", detail: "正在建立 iPhone 镜像的后台区域流。")

        let refreshInterval = max(Self.minimumWindowRefreshInterval, config.scanIntervalSeconds)
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshCaptureRegion()
        }
        timer.tolerance = min(Self.maximumWindowRefreshTolerance, refreshInterval * 0.2)
        trackingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        refreshCaptureRegion()
    }

    private func stopMonitoring(message: String, detail: String) {
        isMonitoring = false
        isRegionOccluded = false
        trackingTimer?.invalidate()
        trackingTimer = nil
        stopCaptureStream()
        startButton.isEnabled = true
        pauseButton.isEnabled = false
        acknowledgeButton.isEnabled = false
        settingsButton.isEnabled = false
        resetPendingConfirmation()
        updateStatus(message, detail: detail)
    }

    private func refreshCaptureRegion() {
        guard isMonitoring else { return }

        guard let infoList = onScreenWindowInfo(),
              let candidate = findMirrorWindow(in: infoList)
        else {
            isRegionOccluded = false
            occlusionChecks = 0
            stopCaptureStream()
            if !alertActive {
                updateStatus("等待镜像窗口", detail: "暂时找不到 iPhone 镜像窗口，正在自动重试。")
            }
            return
        }

        if isMirrorWindowOccluded(candidate, in: infoList) {
            isRegionOccluded = true
            occlusionChecks += 1
            if occlusionChecks >= 2, activeRegion != nil || stream != nil {
                stopCaptureStream()
            }
            if !alertActive {
                let detail = occlusionChecks >= 2
                    ? "镜像被遮挡，已暂停采集以节省资源；恢复可见后会自动继续。"
                    : "请让 iPhone 镜像窗口保持可见；遮挡期间会暂停判别，不会错误重置当前提示。"
                updateStatus("镜像被遮挡", detail: detail)
            }
            return
        }

        isRegionOccluded = false
        occlusionChecks = 0
        guard let region = makeRegion(for: candidate) else {
            if !alertActive {
                updateStatus("等待镜像窗口", detail: "无法确定 iPhone 镜像所在显示器，正在自动重试。")
            }
            return
        }

        if region == activeRegion { return }
        configureCaptureStream(for: region)
    }

    private func makeRegion(for candidate: WindowCandidate) -> MirrorRegion? {
        let matches = NSScreen.screens.compactMap { screen -> (screen: NSScreen, displayID: CGDirectDisplayID, displayBounds: CGRect, intersection: CGRect)? in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }

            let displayID = CGDirectDisplayID(screenNumber.uint32Value)
            let displayBounds = CGDisplayBounds(displayID)
            let intersection = candidate.bounds.intersection(displayBounds)
            guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
                return nil
            }
            return (screen, displayID, displayBounds, intersection)
        }
        guard let match = matches.max(by: { lhs, rhs in
            lhs.intersection.width * lhs.intersection.height < rhs.intersection.width * rhs.intersection.height
        }) else {
            return nil
        }

        // kCGWindowBounds and CGDisplayBounds share Quartz global coordinates.
        let capturedBounds = match.intersection.integral
        let displayLocalBounds = CGRect(origin: .zero, size: match.displayBounds.size)
        let sourceRect = CGRect(
            x: capturedBounds.minX - match.displayBounds.minX,
            y: capturedBounds.minY - match.displayBounds.minY,
            width: capturedBounds.width,
            height: capturedBounds.height
        ).intersection(displayLocalBounds).integral
        guard sourceRect.width > 0, sourceRect.height > 0 else {
            return nil
        }

        let scale = match.screen.backingScaleFactor
        let nativeWidth = max(1, Int((sourceRect.width * scale).rounded(.up)))
        let nativeHeight = max(1, Int((sourceRect.height * scale).rounded(.up)))
        let outputScale = min(1, Self.maximumOCRLongSide / Double(max(nativeWidth, nativeHeight)))
        let capturedArea = capturedBounds.width * capturedBounds.height
        let windowArea = candidate.bounds.width * candidate.bounds.height
        return MirrorRegion(
            candidate: candidate,
            displayID: match.displayID,
            sourceRect: sourceRect,
            outputWidth: max(1, Int((Double(nativeWidth) * outputScale).rounded(.up))),
            outputHeight: max(1, Int((Double(nativeHeight) * outputScale).rounded(.up))),
            isClippedToDisplay: capturedArea + 0.5 < windowArea
        )
    }

    private func configureCaptureStream(for region: MirrorRegion) {
        let configuration = streamConfiguration(for: region)

        if let stream, activeRegion?.displayID == region.displayID {
            regionUpdateGeneration += 1
            let updateGeneration = regionUpdateGeneration
            activeRegion = region
            stream.updateConfiguration(configuration) { [weak self, weak stream] error in
                guard let self, let stream else { return }
                DispatchQueue.main.async {
                    guard self.isMonitoring,
                          self.stream === stream,
                          self.regionUpdateGeneration == updateGeneration
                    else {
                        return
                    }
                    guard let error else { return }
                    self.activeRegion = nil
                    self.updateStatus("区域流更新失败", detail: error.localizedDescription)
                }
            }
            return
        }

        stopCaptureStream()
        regionUpdateGeneration += 1
        let launchGeneration = regionUpdateGeneration
        activeRegion = region
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self,
                      self.isMonitoring,
                      self.activeRegion == region,
                      self.regionUpdateGeneration == launchGeneration
                else {
                    return
                }
                guard let content, error == nil,
                      let display = content.displays.first(where: { $0.displayID == region.displayID })
                else {
                    self.activeRegion = nil
                    self.updateStatus("区域流启动失败", detail: error?.localizedDescription ?? "无法访问镜像所在显示器。")
                    return
                }

                let ownBundleID = Bundle.main.bundleIdentifier
                let ownWindows = content.windows.filter {
                    $0.owningApplication?.bundleIdentifier == ownBundleID
                }
                let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
                let receiver = StreamReceiver(owner: self)
                let stream = SCStream(filter: filter, configuration: configuration, delegate: receiver)

                do {
                    try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: self.streamQueue)
                } catch {
                    self.activeRegion = nil
                    self.updateStatus("区域流启动失败", detail: error.localizedDescription)
                    return
                }

                self.stream = stream
                self.streamReceiver = receiver
                stream.startCapture { [weak self, weak stream] error in
                    guard let self, let stream, let error else { return }
                    DispatchQueue.main.async {
                        guard self.isMonitoring,
                              self.stream === stream,
                              self.regionUpdateGeneration == launchGeneration
                        else {
                            return
                        }
                        self.activeRegion = nil
                        self.updateStatus("区域流启动失败", detail: error.localizedDescription)
                    }
                }
            }
        }
    }

    private func streamConfiguration(for region: MirrorRegion) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = region.sourceRect
        configuration.width = region.outputWidth
        configuration.height = region.outputHeight
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 2
        configuration.capturesAudio = false
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        return configuration
    }

    private func stopCaptureStream() {
        regionUpdateGeneration += 1
        let streamToStop = stream
        stream = nil
        streamReceiver = nil
        activeRegion = nil
        streamToStop?.stopCapture { _ in }
        resetPendingConfirmation()
    }

    private func receiveFrame(
        _ sampleBuffer: CMSampleBuffer,
        outputType: SCStreamOutputType,
        from stream: SCStream
    ) {
        guard outputType == .screen,
              stream === self.stream,
              !isRegionOccluded,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              frameIsComplete(sampleBuffer)
        else {
            return
        }

        let recognizedText = recognizeText(in: pixelBuffer)
        let source = activeRegion?.candidate.displayName ?? "iPhone 镜像"
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.isMonitoring,
                  self.stream === stream,
                  !self.isRegionOccluded
            else {
                return
            }
            self.handleScanResult(recognizedText: recognizedText, source: source)
        }
    }

    private func frameIsComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus)
        else {
            return false
        }
        return status == .complete
    }

    private func recognizeText(in pixelBuffer: CVPixelBuffer) -> String {
        return autoreleasepool {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
            do {
                try handler.perform([textRequest])
            } catch {
                return ""
            }

            return textRequest.results?
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n") ?? ""
        }
    }

    private func handleScanResult(recognizedText: String, source: String) {
        let normalized = recognizedText
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        let hit = decisiveFaceTerms.first(where: { normalized.localizedCaseInsensitiveContains($0) })

        guard let hit else {
            resetPendingConfirmation()
            consecutivePromptMisses += 1
            guard consecutivePromptMisses >= 2 else { return }

            if requiresPromptToClear {
                requiresPromptToClear = false
                consecutivePromptMisses = 0
                updateStatus("已处理，继续检测", detail: "已确认上一张提示页结束，下一次出现时会重新提醒。")
                return
            }

            if alertActive {
                alertActive = false
                alertGeneration += 1
                acknowledgeButton.isEnabled = false
                notificationSubmissionInFlight = false
                alertNotificationSubmitted = false
                activeAlertNotificationID = nil
                consecutivePromptMisses = 0
            }
            if !alertActive {
                let scope = activeRegion?.isClippedToDisplay == true
                    ? "镜像窗口跨屏，当前只识别主要显示器内的可见部分。"
                    : "已锁定镜像窗口区域。"
                updateStatus("正在检测", detail: "已连接：\(source)。\(scope) 还没有看到人脸识别提示。")
            }
            return
        }

        consecutivePromptMisses = 0

        if requiresPromptToClear {
            if !alertActive {
                updateStatus("已处理，等待提示页结束", detail: "同一张人脸提示页仍在显示，不会重复提醒。")
            }
            return
        }

        if hit == pendingHit && source == pendingSource {
            pendingHitCount += 1
        } else {
            pendingHit = hit
            pendingSource = source
            pendingHitCount = 1
        }

        guard pendingHitCount >= 2 else {
            if !alertActive {
                updateStatus("正在复核提示", detail: "已发现疑似人脸验证画面，正在进行第二次确认。")
            }
            return
        }

        triggerAlert(hit: hit, source: source)
    }

    private func triggerAlert(hit: String, source: String) {
        if !alertActive {
            alertActive = true
            alertGeneration += 1
            acknowledgeButton.isEnabled = true
            alertNotificationSubmitted = false
            notificationSubmissionInFlight = false
        }

        if !alertNotificationSubmitted && !notificationSubmissionInFlight {
            notificationSubmissionInFlight = true
            let generation = alertGeneration
            sendSystemNotification { [weak self] submitted, identifier in
                guard let self,
                      self.alertActive,
                      self.alertGeneration == generation
                else {
                    return
                }
                self.notificationSubmissionInFlight = false
                self.alertNotificationSubmitted = submitted
                if submitted {
                    self.activeAlertNotificationID = identifier
                }
            }
        }
        updateStatus("检测到人脸识别提示", detail: "命中“\(hit)”。请回到手机前完成识别，然后点击“已处理”。来源：\(source)")
    }

    private func clearAlert(message: String, detail: String) {
        if alertActive {
            alertActive = false
            alertGeneration += 1
            acknowledgeButton.isEnabled = false
            notificationSubmissionInFlight = false
            alertNotificationSubmitted = false
            if let activeAlertNotificationID {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [activeAlertNotificationID])
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [activeAlertNotificationID])
            }
            activeAlertNotificationID = nil
        }
        updateStatus(message, detail: detail)
    }

    private func onScreenWindowInfo() -> [[String: Any]]? {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    }

    private func findMirrorWindow(in infoList: [[String: Any]]) -> WindowCandidate? {
        return infoList.compactMap(windowCandidate(from:)).first(where: { candidate in
            let haystack = "\(candidate.ownerName) \(candidate.windowName)"
            return config.windowTerms
                .filter { $0.localizedCaseInsensitiveCompare("iPhone") != .orderedSame }
                .contains { haystack.localizedCaseInsensitiveContains($0) }
        })
    }

    private func isMirrorWindowOccluded(_ candidate: WindowCandidate, in infoList: [[String: Any]]) -> Bool {
        guard let targetIndex = infoList.firstIndex(where: { ($0[kCGWindowNumber as String] as? UInt32) == candidate.id })
        else {
            return false
        }

        let ignoredOwners: Set<String> = [
            ProcessInfo.processInfo.processName,
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "",
            Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "",
            window.title,
            "程序坞",
            "Dock",
            "Window Server"
        ]
        let targetArea = candidate.bounds.width * candidate.bounds.height
        for info in infoList.prefix(targetIndex) {
            guard
                let number = info[kCGWindowNumber as String] as? UInt32,
                number != candidate.id,
                let owner = info[kCGWindowOwnerName as String] as? String,
                owner != candidate.ownerName,
                !ignoredOwners.contains(owner),
                let alpha = info[kCGWindowAlpha as String] as? Double,
                alpha > 0.05,
                let layer = info[kCGWindowLayer as String] as? Int,
                layer == 0,
                let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else {
                continue
            }

            let overlap = bounds.intersection(candidate.bounds)
            if !overlap.isNull, overlap.width * overlap.height > targetArea * 0.05 {
                return true
            }
        }
        return false
    }

    private func windowCandidate(from info: [String: Any]) -> WindowCandidate? {
        guard
            let number = info[kCGWindowNumber as String] as? UInt32,
            let owner = info[kCGWindowOwnerName as String] as? String,
            let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
            let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
            bounds.width >= 180,
            bounds.height >= 260
        else {
            return nil
        }
        return WindowCandidate(
            id: CGWindowID(number),
            ownerName: owner,
            windowName: info[kCGWindowName as String] as? String ?? "",
            bounds: bounds
        )
    }

    private func requestNotificationPermission() {
        refreshNotificationPermission(requestIfNeeded: true)
    }

    private func refreshNotificationPermission(requestIfNeeded: Bool) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.showNotificationStatus(for: settings)
            }

            guard requestIfNeeded, settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in
                self?.refreshNotificationPermission(requestIfNeeded: false)
            }
        }
    }

    private func showNotificationStatus(for settings: UNNotificationSettings) {
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            if settings.alertSetting == .enabled, settings.notificationCenterSetting == .enabled {
                switch settings.alertStyle {
                case .banner:
                    notificationLabel.stringValue = "系统通知：已授权，横幅提醒已可用。"
                case .alert:
                    notificationLabel.stringValue = "系统通知：已授权，提醒将以系统提示框显示。"
                case .none:
                    notificationLabel.stringValue = "系统通知：已授权，但系统未设置横幅或提示框。"
                @unknown default:
                    notificationLabel.stringValue = "系统通知：已授权，显示方式由系统决定。"
                }
                notificationSettingsButton.isEnabled = false
            } else {
                notificationLabel.stringValue = "系统通知：已授权，但横幅或通知中心在系统设置中被关闭。"
                notificationSettingsButton.isEnabled = true
            }
        case .notDetermined:
            notificationLabel.stringValue = "系统通知：等待系统授权。"
            notificationSettingsButton.isEnabled = false
        case .denied:
            notificationLabel.stringValue = "系统通知：未获授权。请在“通知设置”中允许 FacePromptWatcher。"
            notificationSettingsButton.isEnabled = true
        @unknown default:
            notificationLabel.stringValue = "系统通知：无法确认授权状态。"
            notificationSettingsButton.isEnabled = true
        }
    }

    private func sendSystemNotification(
        title: String = "人脸识别提示",
        body: String = "请回到手机前完成识别。",
        isTest: Bool = false,
        completion: ((Bool, String?) -> Void)? = nil
    ) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            let isAuthorized: Bool
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                isAuthorized = true
            default:
                isAuthorized = false
            }

            guard isAuthorized else {
                DispatchQueue.main.async {
                    self.showNotificationStatus(for: settings)
                    self.notificationLabel.stringValue = "系统通知：没有权限，提醒未能发出。"
                    completion?(false, nil)
                }
                return
            }

            let identifier = isTest
                ? "face-prompt-test-\(UUID().uuidString)"
                : "face-prompt-alert-\(UUID().uuidString)"
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

            if !isTest {
                DispatchQueue.main.async {
                    self.activeAlertNotificationID = identifier
                }
            }

            center.add(request) { error in
                DispatchQueue.main.async {
                    if let error {
                        self.notificationLabel.stringValue = "系统通知发送失败：\(error.localizedDescription)"
                        self.notificationSettingsButton.isEnabled = true
                        completion?(false, nil)
                    } else if settings.alertSetting == .enabled, settings.notificationCenterSetting == .enabled {
                        self.notificationLabel.stringValue = isTest
                            ? "系统通知：测试提醒已提交。"
                            : "系统通知：人脸识别提醒已提交。"
                        completion?(true, identifier)
                    } else {
                        self.notificationLabel.stringValue = "系统通知：已提交到通知中心，但横幅目前被系统设置关闭。"
                        self.notificationSettingsButton.isEnabled = true
                        completion?(true, identifier)
                    }
                }
            }
        }
    }

    private func resetPendingConfirmation() {
        pendingHit = ""
        pendingSource = ""
        pendingHitCount = 0
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    private func openScreenRecordingSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenRecording"
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    private func openNotificationSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications"
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    private func updateStatus(_ message: String, detail: String) {
        statusLabel.stringValue = message
        detailLabel.stringValue = detail
    }

    private static func loadConfig() -> MonitorConfig {
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FacePromptWatcher", isDirectory: true)
        let configURL = support.appendingPathComponent("config.json")

        if let data = try? Data(contentsOf: configURL),
           let config = try? JSONDecoder().decode(MonitorConfig.self, from: data) {
            return mergeConfig(config)
        }

        try? fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        if let data = try? JSONEncoder.pretty.encode(MonitorConfig.defaults) {
            try? data.write(to: configURL)
        }
        return .defaults
    }

    private static func mergeConfig(_ config: MonitorConfig) -> MonitorConfig {
        var merged = config
        for term in MonitorConfig.defaults.windowTerms where !merged.windowTerms.contains(term) {
            merged.windowTerms.append(term)
        }
        for keyword in MonitorConfig.defaults.keywords where !merged.keywords.contains(keyword) {
            merged.keywords.append(keyword)
        }
        return merged
    }

    private final class StreamReceiver: NSObject, SCStreamOutput, SCStreamDelegate {
        weak var owner: AppDelegate?

        init(owner: AppDelegate) {
            self.owner = owner
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
            owner?.receiveFrame(sampleBuffer, outputType: outputType, from: stream)
        }

        func stream(_ stream: SCStream, didStopWithError error: Error) {
            DispatchQueue.main.async { [weak owner] in
                guard let owner, owner.isMonitoring, owner.stream === stream else { return }
                owner.activeRegion = nil
                owner.updateStatus("区域流已停止", detail: error.localizedDescription)
            }
        }
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
