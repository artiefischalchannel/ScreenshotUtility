import AppKit
import ApplicationServices

/// Small always-on-top readout shown while a scrolling capture runs, and briefly afterwards to confirm it.
/// It is drawn in the system highlight colour so that it stands out from whatever is being captured.
@MainActor
final class ScrollCaptureHUD {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "Esc to cancel")
    private let spinner = NSProgressIndicator()
    private let track = NSView()
    private let fill = NSView()

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 52), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Clicks and scroll events must pass straight through to the window being captured.
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let background = NSView(frame: panel.contentView!.bounds)
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.backgroundColor = NSColor.controlAccentColor.usingColorSpace(.deviceRGB)?.cgColor ?? NSColor.systemBlue.cgColor
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        spinner.style = .spinning
        spinner.controlSize = .small
        // A light spinner, to show on the coloured background.
        spinner.appearance = NSAppearance(named: .darkAqua)
        spinner.frame = NSRect(x: 14, y: 18, width: 16, height: 16)
        background.addSubview(spinner)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 40, y: 26, width: 246, height: 18)
        background.addSubview(label)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = NSColor.white.withAlphaComponent(0.85)
        detail.frame = NSRect(x: 40, y: 9, width: 110, height: 14)
        background.addSubview(detail)
        track.frame = NSRect(x: 150, y: 13, width: 136, height: 6)
        track.wantsLayer = true
        track.layer?.cornerRadius = 3
        track.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.3).cgColor
        track.isHidden = true
        fill.frame = NSRect(x: 0, y: 0, width: 0, height: 6)
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 3
        fill.layer?.backgroundColor = NSColor.white.cgColor
        track.addSubview(fill)
        background.addSubview(track)
        panel.contentView = background
    }

    func show(near target: CGRect) {
        // Top centre of the screen showing the window, just under the menu bar.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let point = NSPoint(x: target.midX, y: primaryHeight - target.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.maxY - panel.frame.height - 8))
        spinner.startAnimation(nil)
        update(text: "Scrolling capture: preparing…", fraction: nil)
        panel.orderFrontRegardless()
    }

    func update(text: String, fraction: Double?) {
        label.stringValue = text
        track.isHidden = fraction == nil
        if let fraction { fill.frame.size.width = track.frame.width * CGFloat(min(1, max(0, fraction))) }
    }

    /// Replaces the progress with a one-line confirmation, in the same place, then goes away.
    func finish(text: String, after delay: TimeInterval = 1.6) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        detail.isHidden = true
        track.isHidden = true
        label.alignment = .center
        label.frame = NSRect(x: 12, y: 17, width: panel.frame.width - 24, height: 18)
        label.stringValue = text
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                             userInfo: [.announcement: text.replacingOccurrences(of: "✓  ", with: ""), .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.close() }
    }

    func close() {
        spinner.stopAnimation(nil)
        panel.orderOut(nil)
    }
}

/// Runs one scrolling capture from picking the target to handing back a saved PNG.
@MainActor
final class ScrollingCaptureController {
    struct Details: Sendable {
        var pixelWidth = 0
        var pixelHeight = 0
        var sections = 0
        var trace: [String] = []
        var restoredPosition = false
        var complete = true
        /// The capture reached the height limit, so the image ends before the bottom of the content.
        var stoppedAtLimit = false
    }

    enum Outcome {
        /// `note` is something the user must be told about the saved image (for example that it stops short).
        case saved(URL, note: String?, details: Details)
        case cancelled
        case failed(String)
    }

    /// When false, questions are answered with the safe default (nothing partial is saved) instead of showing alerts.
    var interactive = true
    /// What the engine did during the most recent capture, for the developer validation report.
    private(set) var lastTrace: [String] = []
    private let picker = ScrollTargetPicker()
    private var hud: ScrollCaptureHUD?
    private var task: Task<Void, Never>?
    private var completion: ((Outcome) -> Void)?
    private var targetSummary = ""

    var isRunning: Bool { completion != nil }

    /// Asks for whatever access is missing using the system prompts. Returns true when a capture can start.
    static func requestAccess(explain: (String, _ settingsPane: String) -> Void) -> Bool {
        var ready = true
        if !CGPreflightScreenCaptureAccess() {
            ready = false
            // The system shows its own prompt the first time only.
            if !CGRequestScreenCaptureAccess(), UserDefaults.standard.bool(forKey: "askedForScreenRecording") {
                explain("Scrolling capture reads the selected window’s picture, which needs Screen Recording access.\n\nTurn on ScreenshotUtility in System Settings › Privacy & Security › Screen & System Audio Recording, then quit and reopen ScreenshotUtility.", "Privacy_ScreenCapture")
            }
            UserDefaults.standard.set(true, forKey: "askedForScreenRecording")
        }
        if !AXIsProcessTrusted() {
            ready = false
            // Standard system prompt with an “Open System Settings” button.
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        return ready
    }

    func start(makeURL: @escaping () throws -> URL, completion: @escaping (Outcome) -> Void) {
        guard !isRunning else { return }
        self.completion = completion
        lastTrace = []
        targetSummary = ""
        picker.begin { [weak self] target in
            guard let self else { return }
            guard let target else { return self.finish(.cancelled) }
            self.capture(target, makeURL: makeURL)
        }
    }

    /// Captures a known target without showing the picker. `customScroll` replaces wheel events
    /// (the developer self-test scrolls its own web view).
    func start(target: ScrollTarget, customScroll: (@Sendable (Double) async -> Void)? = nil, makeURL: @escaping () throws -> URL, completion: @escaping (Outcome) -> Void) {
        guard !isRunning else { return }
        self.completion = completion
        capture(target, customScroll: customScroll, makeURL: makeURL)
    }

    /// Escape: stop picking or stop capturing. The engine puts the scroll position back before it returns.
    func cancel() {
        if picker.isActive { picker.cancel() }
        task?.cancel()
    }

    /// Where each attempt is recorded (text only, never pictures), so a capture that went wrong can be diagnosed afterwards.
    static let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ScreenshotUtility/scrolling-capture.log")

    private func record(_ outcome: Outcome) {
        var lines = ["=== \(ISO8601DateFormatter().string(from: Date()))  \(targetSummary.isEmpty ? "no target chosen" : targetSummary)"]
        switch outcome {
        case .saved(let url, let note, let details):
            lines.append("saved \(url.lastPathComponent), \(details.pixelWidth)x\(details.pixelHeight) px, \(details.sections) sections, position restored: \(details.restoredPosition)\(details.stoppedAtLimit ? ", stopped at the height limit" : "")\(note.map { ", note: \($0)" } ?? "")")
        case .cancelled: lines.append("cancelled")
        case .failed(let message): lines.append("failed: \(message.replacingOccurrences(of: "\n", with: " "))")
        }
        lines += lastTrace.map { "  " + $0 }
        let url = Self.logURL
        let text = lines.joined(separator: "\n") + "\n"
        DispatchQueue.global(qos: .utility).async {
            let manager = FileManager.default
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Keep the file small: start again once it passes about 300 KB.
            if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 300_000 { try? manager.removeItem(at: url) }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(text.utf8))
            } else {
                try? Data(text.utf8).write(to: url)
            }
        }
    }

    /// Called once a saved capture has been copied and added to the gallery: the readout that showed
    /// the progress confirms it (or just goes away when there is nothing to confirm).
    func completeReadout(_ text: String?, for seconds: TimeInterval = 1.6) {
        if let text { hud?.finish(text: text, after: seconds) } else { hud?.close() }
        hud = nil
    }

    private func finish(_ outcome: Outcome) {
        record(outcome)
        // A saved capture keeps its readout up until the app has copied it; see `completeReadout`.
        if case .saved = outcome {} else {
            hud?.close()
            hud = nil
        }
        task = nil
        let completion = completion
        self.completion = nil
        completion?(outcome)
    }

    private func capture(_ target: ScrollTarget, customScroll: (@Sendable (Double) async -> Void)? = nil, makeURL: @escaping () throws -> URL) {
        guard #available(macOS 14.0, *) else {
            return finish(.failed("Scrolling capture needs macOS 14 or later."))
        }
        lastTrace = []
        targetSummary = "\(target.appName), area \(Int(target.region.width))x\(Int(target.region.height)) pt of a \(Int(target.windowFrame.width))x\(Int(target.windowFrame.height)) pt window"
        let hud = ScrollCaptureHUD()
        hud.show(near: target.windowFrame)
        self.hud = hud
        let legacyScrollBars = NSScroller.preferredScrollerStyle == .legacy
        task = Task { [weak self] in
            let surface = WindowScrollSurface(target: target, customScroll: customScroll)
            let engine = ScrollCaptureEngine(surface: surface)
            let outcome: Outcome
            do {
                try await surface.prepare(legacyScrollBars: legacyScrollBars)
                let scale = await surface.scale
                let result = try await engine.run { progress in
                    Task { @MainActor in self?.show(progress, scale: scale) }
                }
                await surface.finish()
                var details = Details(pixelWidth: result.image.width, pixelHeight: result.image.height, sections: result.shifts.count + 1,
                                      trace: await engine.trace, restoredPosition: result.restored, complete: result.stop == .reachedEnd)
                var note: String?
                switch result.stop {
                case .reachedEnd: break
                case .sizeLimit:
                    // Expected for a very long page: the readout says so, without an alert to dismiss.
                    details.stoppedAtLimit = true
                case .timeLimit:
                    note = "The capture was taking too long and was stopped, so the saved image ends before the bottom of the content. This usually means the page keeps loading or changing as it scrolls."
                }
                details.complete = result.stop == .reachedEnd
                hud.update(text: "Saving…", fraction: nil)
                outcome = try await Self.save(await surface.makeImage(result.image), scale: scale, makeURL: makeURL, note: note, details: details)
            } catch is CancellationError {
                await surface.finish()
                outcome = .cancelled
            } catch ScrollCaptureError.didNotScroll(let visible) {
                await surface.finish()
                hud.close()
                let scale = await surface.scale
                let message = "The selected area in \(target.appName) didn’t scroll, so there was nothing to stitch.\n\nEither it is already at the bottom, or \(target.appName) doesn’t respond to scrolling at that spot. Try clicking directly on the scrolling content, or drag to outline just the part that scrolls."
                if self?.ask(message, save: "Save Visible Area") == true {
                    let details = Details(pixelWidth: visible.width, pixelHeight: visible.height, sections: 1, complete: true)
                    outcome = (try? await Self.save(await surface.makeImage(visible), scale: scale, makeURL: makeURL, note: nil, details: details))
                        ?? .failed("The image could not be saved.")
                } else {
                    outcome = self?.interactive == false ? .failed(message) : .cancelled
                }
            } catch ScrollCaptureError.alignment(let partial) {
                await surface.finish()
                hud.close()
                let scale = await surface.scale
                var message = "\(target.appName) changed while it was being captured, so consecutive sections could not be lined up reliably. This happens when content loads, animates or re-flows as it scrolls, when there is a blank stretch taller than the window, or when the window is resized mid-capture.\n\nNothing has been saved."
                if let partial {
                    message += " The first \(Self.points(partial.height, scale)) points were stitched cleanly."
                    if self?.ask(message, save: "Save Partial Image") == true {
                        let details = Details(pixelWidth: partial.width, pixelHeight: partial.height, complete: false)
                        outcome = (try? await Self.save(await surface.makeImage(partial), scale: scale, makeURL: makeURL, note: nil, details: details))
                            ?? .failed("The image could not be saved.")
                    } else {
                        outcome = self?.interactive == false ? .failed(message) : .cancelled
                    }
                } else {
                    outcome = .failed(message)
                }
            } catch ScrollCaptureError.repetitive(let image) {
                await surface.finish()
                hud.close()
                let scale = await surface.scale
                let message = "The content in \(target.appName) repeats so regularly (identical rows, or an empty grid) that some sections could not be told apart. They were placed by how far the window was asked to scroll, so the image may have a repeated or missing strip.\n\nNothing has been saved."
                if self?.ask(message, save: "Save Anyway") == true {
                    let details = Details(pixelWidth: image.width, pixelHeight: image.height, complete: false)
                    outcome = (try? await Self.save(await surface.makeImage(image), scale: scale, makeURL: makeURL, note: nil, details: details))
                        ?? .failed("The image could not be saved.")
                } else {
                    outcome = self?.interactive == false ? .failed(message) : .cancelled
                }
            } catch WindowScrollSurfaceError.areaTooSmall {
                outcome = .failed("That area is too small to stitch. Choose an area at least 50 points tall.")
            } catch WindowScrollSurfaceError.covered(let other) {
                await surface.finish()
                outcome = .failed("\(other) came in front of \(target.appName) during the capture, so scrolling stopped reaching it. Nothing was saved.\n\nKeep \(target.appName) in front and leave the mouse and keyboard alone until the capture finishes.")
            } catch WindowScrollSurfaceError.windowChanged {
                await surface.finish()
                outcome = .failed("The window was resized during the capture, so the sections no longer match. Nothing was saved.")
            } catch {
                await surface.finish()
                outcome = .failed("The window in \(target.appName) could not be captured.\n\n\(error.localizedDescription)")
            }
            self?.lastTrace = await engine.trace
            self?.finish(outcome)
        }
    }

    private func show(_ progress: ScrollCaptureProgress, scale: Double) {
        guard let hud else { return }
        switch progress.phase {
        case .preparing: hud.update(text: "Scrolling capture: starting…", fraction: nil)
        case .capturing: hud.update(text: "Scrolling capture: \(Self.points(progress.pixelHeight, scale)) pt captured", fraction: progress.fraction)
        case .restoring: hud.update(text: "Returning to where you were…", fraction: nil)
        }
    }

    private static func points(_ pixels: Int, _ scale: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: Int(Double(pixels) / scale))) ?? "\(pixels)"
    }

    private func ask(_ message: String, save: String) -> Bool {
        guard interactive else { return false }
        let alert = NSAlert()
        alert.messageText = "Scrolling Capture"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: save)
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    private static func save(_ image: CGImage?, scale: Double, makeURL: @escaping () throws -> URL, note: String?, details: Details) async throws -> Outcome {
        guard let image else { return .failed("The stitched image could not be created.") }
        let url = try makeURL()
        // Encoding a very tall PNG takes a few seconds; keep it off the main thread.
        try await Task.detached(priority: .userInitiated) {
            try CaptureFile.writePNG(image, to: url, pixelsPerPoint: scale)
        }.value
        return .saved(url, note: note, details: details)
    }
}
