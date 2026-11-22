import AppKit
import Carbon

private let appName = "ScreenshotUtility"
private let hotKeySignature: OSType = 0x53435554 // SCUT
private let hotKeyIDValue: UInt32 = 1
private let escapeHotKeyIDValue: UInt32 = 2
private let scrollHotKeyIDValue: UInt32 = 3
private let saveDirectoryDefaultsKey = "saveDirectoryPath"
@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var saveFolderItem: NSMenuItem?
    private var lastCaptureItem: NSMenuItem?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var escapeHotKeyRef: EventHotKeyRef?
    private var scrollHotKeyRef: EventHotKeyRef?
    private let scrollingCapture = ScrollingCaptureController()
    private var isCapturing = false
    private var lastCaptureURL: URL?
    private let gallery = GalleryView()
    private let scanQueue = DispatchQueue(label: "ScreenshotUtility.scan", qos: .userInitiated)
    private var recent: [RecentCapture] = []
    private var scanError: String?
    private var scanInFlight = false
    private var refreshTimer: Timer?
    private var toast: NSPanel?
    private var toastDismiss: DispatchWorkItem?
    private var menuIsOpen = false


    private static let fileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd-HH.mm.ss"
        return formatter
    }()

    private var defaultSaveDirectoryURL: URL {
        let picturesURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        return (picturesURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures"))
            .appendingPathComponent("ScreenshotUtility", isDirectory: true)
    }

    private var saveDirectoryURL: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: saveDirectoryDefaultsKey), !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }

            return defaultSaveDirectoryURL
        }
        set {
            UserDefaults.standard.set(newValue.path, forKey: saveDirectoryDefaultsKey)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // Developer hook: `--access-check <file>` records what access this app has, without asking
        // for any and without showing anything, then quits.
        if let index = CommandLine.arguments.firstIndex(of: "--access-check"), CommandLine.arguments.indices.contains(index + 1) {
            let state = "screenRecording=\(CGPreflightScreenCaptureAccess()) accessibility=\(AXIsProcessTrusted())\n"
            try? state.write(toFile: CommandLine.arguments[index + 1], atomically: true, encoding: .utf8)
            exit(0)
        }
        #endif
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()
        installHotKeyHandler()
        #if DEBUG
        if CommandLine.arguments.contains("--gallery-validation") {
            showValidationWindow()
        } else if CommandLine.arguments.contains("--scroll-selftest") {
            selfTest.capture = { [weak self] target, scroll, done in
                guard let self else { return }
                self.scrollingCapture.interactive = false
                self.setEscapeHotKey(true)
                self.scrollingCapture.start(target: target, customScroll: scroll, makeURL: { self.newCaptureURL() }) { outcome in
                    self.setEscapeHotKey(false)
                    // A private pasteboard, so testing does not replace what the user has copied.
                    let board = NSPasteboard.withUniqueName()
                    done(self.validationReport(outcome, pasteboard: board))
                    board.releaseGlobally()
                }
            }
            selfTest.run()
        } else if CommandLine.arguments.contains(where: { $0.hasPrefix("--scroll-capture") }) {
            runScrollingValidation()
        } else {
            registerHotKey()
        }
        #else
        registerHotKey()
        #endif
        scanRecentCaptures()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let scrollHotKeyRef {
            UnregisterEventHotKey(scrollHotKeyRef)
        }

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        refreshMenuState()
        scanRecentCaptures()
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(refreshGallery), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        refreshTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        // The menu belongs to the status item only while it is showing; otherwise a plain click captures.
        statusItem?.menu = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    @objc private func refreshGallery() {
        recent.removeAll { $0.capturedAt <= Date().addingTimeInterval(-RecentCaptures.lifetime) }
        gallery.update(recent, error: scanError)
        scanRecentCaptures()
    }

    private func scanRecentCaptures() {
        guard !scanInFlight else { return }
        scanInFlight = true
        let folder = saveDirectoryURL
        scanQueue.async { [weak self] in
            let result = RecentCaptures.scan(folder: folder)
            RunLoop.main.perform(inModes: [.default, .eventTracking]) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scanInFlight = false
                    guard self.saveDirectoryURL == folder else {
                        self.scanRecentCaptures()
                        return
                    }
                    self.recent = result.captures.filter { $0.capturedAt > Date().addingTimeInterval(-RecentCaptures.lifetime) }
                    self.scanError = result.error
                    self.gallery.update(self.recent, error: result.error)
                    if self.lastCaptureURL == nil { self.lastCaptureURL = self.recent.first?.url }
                    self.refreshMenuState()
                }
            }
        }
    }

    @objc private func captureFromMenu(_ sender: Any?) {
        captureScreenshot()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            captureScreenshot()
            return
        }

        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showStatusMenu()
        } else if event.modifierFlags.contains(.option) {
            startScrollingCapture()
        } else {
            captureScreenshot()
        }
    }

    @objc private func scrollingCaptureFromMenu(_ sender: Any?) {
        // Let the menu finish closing so it is not in the way of the window picker.
        DispatchQueue.main.async { self.startScrollingCapture() }
    }

    @objc private func chooseSaveFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Choose Screenshot Folder"
        panel.prompt = "Choose"
        panel.message = "Screenshots will be saved directly into this folder."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = saveDirectoryURL

        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let selectedURL = panel.url {
            saveDirectoryURL = selectedURL
            lastCaptureURL = nil
            recent = []
            scanError = nil
            gallery.update([], error: nil)
            scanRecentCaptures()
            self.refreshMenuState()
        }
    }

    @objc private func openSaveFolder(_ sender: Any?) {
        do {
            try FileManager.default.createDirectory(at: saveDirectoryURL, withIntermediateDirectories: true)
            NSWorkspace.shared.open(saveDirectoryURL)
        } catch {
            presentError("Could not open the screenshot folder:\n\(error.localizedDescription)")
        }
    }

    @objc private func openLastCapture(_ sender: Any?) {
        guard let lastCaptureURL else {
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([lastCaptureURL])
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func buildStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: appName) {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "SC"
            }

            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Click to capture (Ctrl+Option+4). Option-click for a scrolling capture (Ctrl+Option+5). Right-click for options."
        }

        let menu = NSMenu()
        menu.delegate = self

        let captureItem = NSMenuItem(
            title: "Capture Selection",
            action: #selector(captureFromMenu(_:)),
            keyEquivalent: ""
        )
        captureItem.target = self
        captureItem.keyEquivalent = "4"
        captureItem.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(captureItem)
        let scrollingItem = NSMenuItem(
            title: "Scrolling Capture…",
            action: #selector(scrollingCaptureFromMenu(_:)),
            keyEquivalent: ""
        )
        scrollingItem.target = self
        scrollingItem.keyEquivalent = "5"
        scrollingItem.keyEquivalentModifierMask = [.control, .option]
        scrollingItem.toolTip = "Capture a window’s scrolling content as one tall image. Shortcuts: Ctrl+Option+5, or Option-click the menu bar icon."
        menu.addItem(scrollingItem)
        menu.addItem(.separator())
        let heading = NSMenuItem(title: "Last 48 Hours                         Click to copy", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        let galleryItem = NSMenuItem()
        galleryItem.view = gallery
        menu.addItem(galleryItem)
        menu.addItem(.separator())
        gallery.onCopy = { [weak self] url in
            guard let self else { return }
            self.menu?.cancelTracking()
            // Copy after dismissing the gallery so the receiving app keeps focus.
            DispatchQueue.main.async {
                do {
                    try ImageClipboard.copy(url)
                    self.showCopiedConfirmation()
                } catch {
                    self.presentError("Could not copy that screenshot:\n\(error.localizedDescription)")
                    self.scanRecentCaptures()
                }
            }
        }

        let saveFolderItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        saveFolderItem.isEnabled = false
        self.saveFolderItem = saveFolderItem
        menu.addItem(saveFolderItem)

        let chooseFolderItem = NSMenuItem(
            title: "Choose Save Folder…",
            action: #selector(chooseSaveFolder(_:)),
            keyEquivalent: ""
        )
        chooseFolderItem.target = self
        menu.addItem(chooseFolderItem)

        let openFolderItem = NSMenuItem(
            title: "Open Save Folder",
            action: #selector(openSaveFolder(_:)),
            keyEquivalent: ""
        )
        openFolderItem.target = self
        menu.addItem(openFolderItem)

        let lastCaptureItem = NSMenuItem(
            title: "Show Last Capture",
            action: #selector(openLastCapture(_:)),
            keyEquivalent: ""
        )
        lastCaptureItem.target = self
        self.lastCaptureItem = lastCaptureItem
        menu.addItem(lastCaptureItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.menu = menu
        refreshMenuState()
    }

    private func refreshMenuState() {
        let path = (saveDirectoryURL.path as NSString).abbreviatingWithTildeInPath
        var shortened = path
        while ("Folder: " + shortened as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width > 280 && shortened.count > 16 {
            let side = (shortened.count - 2) / 2
            shortened = String(path.prefix(side)) + "…" + String(path.suffix(side))
        }
        saveFolderItem?.title = "Folder: \(shortened)"
        saveFolderItem?.toolTip = saveDirectoryURL.path
        lastCaptureItem?.isEnabled = lastCaptureURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    private func showStatusMenu() {
        guard let statusItem, let button = statusItem.button, let menu else {
            return
        }

        prepareMenu(for: button)
        // Hand the menu to the status item for this one click so macOS places it itself. Popping it up
        // at a point under the icon opened it one menu-bar height too high, with the first item hidden
        // behind a scroll arrow until the mouse moved.
        statusItem.menu = menu
        button.performClick(nil)
        if !menuIsOpen { statusItem.menu = nil }
    }

    private func prepareMenu(for button: NSView) {
        refreshMenuState()
        recent.removeAll { $0.capturedAt <= Date().addingTimeInterval(-RecentCaptures.lifetime) }
        gallery.update(recent, error: scanError)
        gallery.prepareHeight(screenHeight: button.window?.screen?.visibleFrame.height ?? 700)
    }

    private func presentMenu(_ menu: NSMenu, from button: NSView) {
        prepareMenu(for: button)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    #if DEBUG
    private let selfTest = ScrollSelfTest()
    private var validationWindow: NSWindow?
    private func showValidationWindow() {
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ScreenshotUtility — Gallery Validation"
        let open = NSButton(title: "Open Screenshot Menu", target: self, action: #selector(openValidationMenu(_:)))
        open.frame = NSRect(x: 30, y: 630, width: 220, height: 32)
        window.contentView?.addSubview(open)
        let capture = NSButton(title: "Capture Selection", target: self, action: #selector(captureFromMenu(_:)))
        capture.frame = NSRect(x: 280, y: 630, width: 220, height: 32)
        window.contentView?.addSubview(capture)
        window.center()
        window.makeKeyAndOrderFront(nil)
        validationWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func openValidationMenu(_ sender: NSButton) {
        if let menu { presentMenu(menu, from: sender) }
    }
    #endif

    private func installHotKeyHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, _ in
                guard let eventRef else {
                    return OSStatus(eventNotHandledErr)
                }

                var hotKeyID = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard parameterStatus == noErr,
                      hotKeyID.signature == hotKeySignature,
                      [hotKeyIDValue, escapeHotKeyIDValue, scrollHotKeyIDValue].contains(hotKeyID.id) else {
                    return OSStatus(eventNotHandledErr)
                }

                let pressed = hotKeyID.id
                DispatchQueue.main.async {
                    let delegate = NSApp.delegate as? AppDelegate
                    switch pressed {
                    case escapeHotKeyIDValue: delegate?.scrollingCapture.cancel()
                    case scrollHotKeyIDValue: delegate?.startScrollingCapture()
                    default: delegate?.captureScreenshot()
                    }
                }

                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )

        if status != noErr {
            presentError("Could not install the hotkey handler. Error code: \(status)")
        }
    }

    /// Ctrl+Option+4 captures a selection and Ctrl+Option+5 starts a scrolling capture.
    private func registerHotKey() {
        let modifiers = UInt32(optionKey | controlKey)
        let keys: [(code: Int, id: UInt32, name: String)] = [
            (kVK_ANSI_4, hotKeyIDValue, "Ctrl+Option+4"),
            (kVK_ANSI_5, scrollHotKeyIDValue, "Ctrl+Option+5")
        ]
        for key in keys {
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(key.code), modifiers, EventHotKeyID(signature: hotKeySignature, id: key.id), GetApplicationEventTarget(), 0, &reference)
            if key.id == hotKeyIDValue { hotKeyRef = reference } else { scrollHotKeyRef = reference }
            if status == eventHotKeyExistsErr {
                presentError("The hotkey \(key.name) is already in use.")
            } else if status != noErr {
                presentError("Could not register the hotkey \(key.name). Error code: \(status)")
            }
        }
    }

    private func captureScreenshot() {
        guard !isCapturing else {
            return
        }

        menu?.cancelTracking()
        toast?.orderOut(nil)
        isCapturing = true

        do {
            try FileManager.default.createDirectory(at: saveDirectoryURL, withIntermediateDirectories: true)
        } catch {
            isCapturing = false
            presentError("Could not create the screenshot folder:\n\(error.localizedDescription)")
            return
        }

        let outputURL = newCaptureURL()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-s", outputURL.path]

        do {
            try process.run()
            process.waitUntilExit()
            isCapturing = false

            if process.terminationStatus == 0,
               FileManager.default.fileExists(atPath: outputURL.path) {
                finishCapture(at: outputURL)
            } else if process.terminationStatus != 1 {
                presentError("The screenshot was not saved. screencapture exited with code \(process.terminationStatus).")
            }
        } catch {
            isCapturing = false
            presentError("Could not start macOS screencapture:\n\(error.localizedDescription)")
        }
    }

    private func newCaptureURL() -> URL {
        let timestamp = Self.fileNameFormatter.string(from: Date())
        let url = saveDirectoryURL.appendingPathComponent("Screenshot-\(timestamp).png")
        if FileManager.default.fileExists(atPath: url.path) {
            return saveDirectoryURL.appendingPathComponent("Screenshot-\(timestamp)-\(UUID().uuidString).png")
        }
        return url
    }

    /// Everything that happens once a capture is on disk, whichever kind of capture produced it:
    /// stamp it for the gallery, make it the last capture, refresh the gallery and copy the image.
    @discardableResult
    private func finishCapture(at url: URL, pasteboard: NSPasteboard = .general) -> Bool {
        RecentCaptures.recordCapture(at: url)
        lastCaptureURL = url
        scanRecentCaptures()
        refreshMenuState()
        do {
            try ImageClipboard.copy(url, to: pasteboard)
            return true
        } catch {
            presentError("The screenshot was saved, but could not be copied to the clipboard:\n\(error.localizedDescription)")
            return false
        }
    }

    // MARK: Scrolling capture

    private func startScrollingCapture() {
        guard !isCapturing else { return }
        menu?.cancelTracking()
        toast?.orderOut(nil)
        guard #available(macOS 14.0, *) else {
            presentError("Scrolling capture needs macOS 14 or later.")
            return
        }
        let ready = ScrollingCaptureController.requestAccess { [weak self] message, pane in
            self?.presentError(message, settingsPane: pane)
        }
        guard ready else {
            // macOS is showing its own prompt; say what to do next.
            showConfirmation("Allow access when macOS asks, then start the scrolling capture again", duration: 5)
            return
        }
        do {
            try FileManager.default.createDirectory(at: saveDirectoryURL, withIntermediateDirectories: true)
        } catch {
            presentError("Could not create the screenshot folder:\n\(error.localizedDescription)")
            return
        }
        isCapturing = true
        setEscapeHotKey(true)
        scrollingCapture.start(makeURL: { [weak self] in
            guard let self else { throw CocoaError(.fileWriteUnknown) }
            return self.newCaptureURL()
        }) { [weak self] outcome in
            self?.scrollingCaptureEnded(outcome)
        }
    }

    private func scrollingCaptureEnded(_ outcome: ScrollingCaptureController.Outcome) {
        setEscapeHotKey(false)
        isCapturing = false
        switch outcome {
        case .saved(let url, let note, let details):
            // The confirmation appears in the same readout that showed the progress.
            if !finishCapture(at: url) {
                scrollingCapture.completeReadout(nil)
            } else if details.stoppedAtLimit {
                scrollingCapture.completeReadout("✓  Copied · stopped at the length limit", for: 3.5)
            } else {
                scrollingCapture.completeReadout("✓  Scrolling capture copied")
            }
            if let note { presentError(note) }
        case .cancelled:
            break
        case .failed(let message):
            presentError(message)
        }
    }

    /// Escape is claimed system-wide only while a scrolling capture is being picked or is running,
    /// because the app being captured, not this one, has the keyboard.
    private func setEscapeHotKey(_ enabled: Bool) {
        if enabled, escapeHotKeyRef == nil {
            RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: hotKeySignature, id: escapeHotKeyIDValue), GetApplicationEventTarget(), 0, &escapeHotKeyRef)
        } else if !enabled, let escapeHotKeyRef {
            UnregisterEventHotKey(escapeHotKeyRef)
            self.escapeHotKeyRef = nil
        }
    }

    #if DEBUG
    /// Developer hook: `--scroll-capture-window <id>` captures that window without the picker,
    /// `--scroll-capture-pick` opens the picker. `--scroll-capture-region x,y,w,h` and
    /// `--scroll-capture-point x,y` (global points) narrow the area; `--scroll-capture-report <file>`
    /// receives a JSON summary. The app quits when the capture ends.
    private func runScrollingValidation() {
        let arguments = CommandLine.arguments
        func value(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        func numbers(_ name: String) -> [CGFloat]? {
            value(name)?.split(separator: ",").compactMap { Double($0).map { CGFloat($0) } }
        }
        let report = value("--scroll-capture-report")
        func write(_ fields: [String: Any]) {
            if let report, let data = try? JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: report))
            }
        }
        let access: [String: Any] = ["screenRecording": CGPreflightScreenCaptureAccess(), "accessibility": AXIsProcessTrusted()]
        // `--scroll-capture-skip-access` shows the picker without access, to check how it looks.
        guard arguments.contains("--scroll-capture-skip-access") || ScrollingCaptureController.requestAccess(explain: { _, _ in }) else {
            // The system prompts stay on screen; they are for this app's permanent identity.
            write(["status": "needs-access", "access": access])
            guard arguments.contains("--scroll-capture-wait-for-access") else { return NSApp.terminate(nil) }
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated {
                    if CGPreflightScreenCaptureAccess() && AXIsProcessTrusted() { NSApp.terminate(nil) }
                }
            }
            return
        }
        try? FileManager.default.createDirectory(at: saveDirectoryURL, withIntermediateDirectories: true)
        setEscapeHotKey(true)
        let custom = numbers("--scroll-capture-region")
        let requestedPoint = numbers("--scroll-capture-point")
        let windowID = value("--scroll-capture-window").flatMap { UInt32($0) }
        Task { @MainActor in
            let outcome: ScrollingCaptureController.Outcome = await withCheckedContinuation { continuation in
                let makeURL: () throws -> URL = { self.newCaptureURL() }
                guard let id = windowID else {
                    return self.scrollingCapture.start(makeURL: makeURL) { continuation.resume(returning: $0) }
                }
                self.scrollingCapture.interactive = false
                let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] ?? []
                guard let info = list.first, let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                      let bounds = info[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: bounds) else {
                    return continuation.resume(returning: .failed("No window with id \(id)."))
                }
                let app = info[kCGWindowOwnerName as String] as? String ?? "App"
                let point = requestedPoint.flatMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil } ?? CGPoint(x: frame.midX, y: frame.midY)
                let detected = AXLookup.scrollArea(pid: pid, point: point, windowFrame: frame, legacyScrollBars: NSScroller.preferredScrollerStyle == .legacy)?.frame
                var region = detected ?? frame
                if let custom, custom.count == 4 {
                    region = CGRect(x: custom[0], y: custom[1], width: custom[2], height: custom[3]).intersection(frame)
                }
                let aim = requestedPoint != nil || detected == nil ? point : CGPoint(x: point.x, y: region.minY + region.height * 0.8)
                let target = ScrollTarget(windowID: id, pid: pid, appName: app, windowFrame: frame, region: region, scrollPoint: aim)
                self.scrollingCapture.start(target: target, makeURL: makeURL) { continuation.resume(returning: $0) }
            }
            self.setEscapeHotKey(false)
            write(self.validationReport(outcome, pasteboard: .general))
            NSApp.terminate(nil)
        }
    }

    /// Finishes a validation capture exactly as a normal one and describes the result, including
    /// what actually reached the clipboard and the gallery.
    private func validationReport(_ outcome: ScrollingCaptureController.Outcome, pasteboard: NSPasteboard) -> [String: Any] {
        switch outcome {
        case .saved(let url, let note, let details):
            let copied = finishCapture(at: url, pasteboard: pasteboard)
            scrollingCapture.completeReadout(nil)
            var fields: [String: Any] = [
                "status": "saved", "file": url.path, "note": note ?? "", "copied": copied, "pixelWidth": details.pixelWidth,
                "pixelHeight": details.pixelHeight, "sections": details.sections, "trace": details.trace,
                "restoredPosition": details.restoredPosition, "complete": details.complete
            ]
            if let data = pasteboard.data(forType: NSPasteboard.PasteboardType("public.png")),
               let source = CGImageSourceCreateWithData(data as CFData, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                fields["clipboardPNG"] = "\(properties[kCGImagePropertyPixelWidth] ?? 0)x\(properties[kCGImagePropertyPixelHeight] ?? 0)"
                fields["clipboardMatchesFile"] = (try? Data(contentsOf: url)) == data
                fields["dpi"] = properties[kCGImagePropertyDPIHeight] ?? 0
            }
            fields["clipboardTypes"] = pasteboard.types?.map(\.rawValue) ?? []
            fields["galleryNewest"] = RecentCaptures.scan(folder: saveDirectoryURL).captures.first?.url.lastPathComponent ?? ""
            fields["captureTimeRecorded"] = RecentCaptures.recordedDate(at: url) != nil
            return fields
        case .cancelled: return ["status": "cancelled", "trace": scrollingCapture.lastTrace]
        case .failed(let message): return ["status": "failed", "message": message, "trace": scrollingCapture.lastTrace]
        }
    }
    #endif

    private func showCopiedConfirmation() {
        showConfirmation("✓  Copied image")
    }

    private func showConfirmation(_ text: String, duration: TimeInterval = 1.3) {
        guard let button = statusItem?.button, let window = button.window else { return }
        toastDismiss?.cancel()
        toast?.orderOut(nil)
        let width = max(150, ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width) + 32)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 36), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let background = NSVisualEffectView(frame: panel.contentView!.bounds)
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.frame = NSRect(x: 8, y: 9, width: width - 16, height: 18)
        background.addSubview(label)
        panel.contentView = background
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? anchor
        panel.setFrameOrigin(NSPoint(x: min(max(anchor.midX - width / 2, screen.minX + 8), screen.maxX - width - 8), y: screen.maxY - 44))
        panel.orderFrontRegardless()
        toast = panel
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested, userInfo: [.announcement: text.replacingOccurrences(of: "✓  ", with: ""), .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        let dismiss = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }
        toastDismiss = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: dismiss)
    }

    private func presentError(_ message: String, settingsPane: String? = nil) {
        let alert = NSAlert()
        alert.messageText = appName
        alert.informativeText = message
        alert.alertStyle = .warning
        if settingsPane != nil {
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
        }

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, let settingsPane,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsPane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
