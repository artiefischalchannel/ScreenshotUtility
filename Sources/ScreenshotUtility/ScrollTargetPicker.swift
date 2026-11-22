import AppKit

/// Full-screen overlay for choosing what to capture: hover highlights the scrolling area under the
/// pointer (or the whole window when the app does not describe its scrolling areas), a click picks
/// it, and a drag picks an exact rectangle inside a window.
@MainActor
final class ScrollTargetPicker {
    private struct Candidate {
        let id: CGWindowID
        let pid: pid_t
        let app: String
        let frame: CGRect
    }

    private var panels: [NSPanel] = []
    private var candidates: [Candidate] = []
    private var completion: ((ScrollTarget?) -> Void)?
    private let lookupQueue = DispatchQueue(label: "ScreenshotUtility.accessibility", qos: .userInteractive)
    private var lookupBusy = false
    private var lookupPending: CGPoint?
    private var hovered: Candidate?
    private var hoveredArea: CGRect?
    private var dragOrigin: CGPoint?
    private var dragWindow: Candidate?
    private var dragRect: CGRect?
    /// Shown in place of the usual hint after a drag that could not be used.
    private var note: String?
    private let legacyScrollBars = NSScroller.preferredScrollerStyle == .legacy

    var isActive: Bool { completion != nil }

    func begin(completion: @escaping (ScrollTarget?) -> Void) {
        self.completion = completion
        candidates = Self.windows()
        for screen in NSScreen.screens {
            let panel = PickerPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            // A see-through window normally lets clicks on its fully transparent pixels fall through to
            // whatever is underneath. Saying so explicitly makes the whole overlay take the mouse.
            panel.ignoresMouseEvents = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let view = PickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.picker = self
            view.screenOrigin = Self.global(screen.frame).origin
            panel.contentView = view
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        panels.first { $0.frame.contains(NSEvent.mouseLocation) }?.makeKey()
        hover(at: Self.pointer())
    }

    func cancel() {
        finish(nil)
    }

    // MARK: Geometry

    /// AppKit screen coordinates (origin bottom-left) to global display coordinates (origin top-left).
    static func global(_ rect: NSRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func pointer() -> CGPoint {
        let location = NSEvent.mouseLocation
        return CGPoint(x: location.x, y: (NSScreen.screens.first?.frame.height ?? 0) - location.y)
    }

    private static func windows() -> [Candidate] {
        let own = getpid()
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.width >= 160, frame.height >= 120 else { return nil }
            return Candidate(id: id, pid: pid, app: info[kCGWindowOwnerName as String] as? String ?? "This app", frame: frame)
        }
    }

    // MARK: Interaction (called by the overlay views)

    fileprivate func hover(at point: CGPoint) {
        guard dragOrigin == nil else { return }
        let window = candidates.first { $0.frame.contains(point) }
        if window?.id != hovered?.id || !(hoveredArea?.contains(point) ?? true) { hoveredArea = nil }
        hovered = window
        redraw()
        guard window != nil else { return }
        lookupPending = point
        runLookup()
    }

    private func runLookup() {
        guard !lookupBusy, let point = lookupPending, let window = candidates.first(where: { $0.frame.contains(point) }) else { return }
        lookupPending = nil
        lookupBusy = true
        let pid = window.pid, frame = window.frame, id = window.id, legacy = legacyScrollBars
        lookupQueue.async {
            let area = AXLookup.scrollArea(pid: pid, point: point, windowFrame: frame, legacyScrollBars: legacy)?.frame
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.lookupBusy = false
                    if self.isActive, self.dragOrigin == nil, self.hovered?.id == id, self.lookupPending == nil || area?.contains(self.lookupPending!) == true {
                        self.hoveredArea = area
                        self.redraw()
                    }
                    self.runLookup()
                }
            }
        }
    }

    /// The window an outlined box belongs to: the frontmost one under the middle of the box, or
    /// failing that the one the box overlaps most. `frames` are in front-to-back order.
    nonisolated static func windowIndex(forBox box: CGRect, frames: [CGRect]) -> Int? {
        let middle = CGPoint(x: box.midX, y: box.midY)
        if let index = frames.firstIndex(where: { $0.contains(middle) }) { return index }
        var best: (index: Int, area: CGFloat)?
        for (index, frame) in frames.enumerated() {
            let overlap = frame.intersection(box)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > (best?.area ?? 0) { best = (index, area) }
        }
        return best?.index
    }

    fileprivate func mouseDown(at point: CGPoint) {
        dragOrigin = point
        dragWindow = nil
        dragRect = nil
        note = nil
    }

    /// A drag can start anywhere, including outside the window, as when drawing around something.
    fileprivate func mouseDragged(to point: CGPoint) {
        guard let origin = dragOrigin else { return }
        let box = CGRect(x: min(origin.x, point.x), y: min(origin.y, point.y), width: abs(point.x - origin.x), height: abs(point.y - origin.y))
        if box.width > 6 || box.height > 6 {
            dragWindow = Self.windowIndex(forBox: box, frames: candidates.map(\.frame)).map { candidates[$0] }
            dragRect = dragWindow.map { box.intersection($0.frame) } ?? box
        } else {
            dragWindow = nil
            dragRect = nil
        }
        redraw()
    }

    fileprivate func mouseUp(at point: CGPoint) {
        guard dragOrigin != nil else { return }
        let box = dragRect, boxWindow = dragWindow
        dragOrigin = nil
        dragWindow = nil
        dragRect = nil
        if let box {
            guard let window = boxWindow, box.width >= 80, box.height >= 80 else {
                // Stay open and say why nothing happened.
                note = boxWindow == nil ? "Outline part of a window" : "Too small: outline a larger area"
                return hover(at: point)
            }
            // An outlined area: aim low in it, where each section is later overwritten by the next one,
            // so anything that reacts to the pointer does not end up in the picture.
            return finish(ScrollTarget(windowID: window.id, pid: window.pid, appName: window.app, windowFrame: window.frame, region: box.integral,
                                       scrollPoint: CGPoint(x: box.midX, y: box.minY + box.height * 0.8)))
        }
        // A plain click: take what is highlighted. A click on the menu bar or the desktop backs out.
        guard let window = candidates.first(where: { $0.frame.contains(point) }) else { return finish(nil) }
        let area = hovered?.id == window.id ? hoveredArea : nil
        let region = area ?? window.frame
        let aim = area == nil
            ? point
            : CGPoint(x: min(max(point.x, region.minX + 12), region.maxX - 12), y: region.minY + region.height * 0.8)
        finish(ScrollTarget(windowID: window.id, pid: window.pid, appName: window.app, windowFrame: window.frame, region: region, scrollPoint: aim))
    }

    private func finish(_ target: ScrollTarget?) {
        guard let completion else { return }
        self.completion = nil
        panels.forEach { $0.orderOut(nil) }
        panels = []
        hovered = nil
        hoveredArea = nil
        lookupPending = nil
        dragOrigin = nil
        dragWindow = nil
        dragRect = nil
        note = nil
        completion(target)
    }

    private func redraw() {
        for panel in panels {
            guard let view = panel.contentView as? PickerView else { continue }
            if dragRect != nil {
                view.windowFrame = dragWindow?.frame
                view.highlight = dragRect
                view.caption = dragWindow.map { "Release to capture this part of \($0.app)" } ?? "Outline part of a window"
            } else {
                view.windowFrame = hovered?.frame
                view.highlight = hoveredArea ?? hovered?.frame
                view.caption = hovered.map { hoveredArea != nil ? "\($0.app) — scrolling area" : "\($0.app) — whole window" }
            }
            view.hint = note ?? "Click the highlighted area  ·  or drag a box around what you want  ·  Esc to cancel"
            view.needsDisplay = true
        }
    }
}

private final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        (contentView as? PickerView)?.picker?.cancel()
    }
}

private final class PickerView: NSView {
    weak var picker: ScrollTargetPicker?
    var screenOrigin = CGPoint.zero
    var highlight: CGRect?
    var windowFrame: CGRect?
    var caption: String?
    var hint = ""

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        picker?.hover(at: ScrollTargetPicker.pointer())
    }
    override func mouseEntered(with event: NSEvent) { picker?.hover(at: ScrollTargetPicker.pointer()) }
    override func mouseDown(with event: NSEvent) { picker?.mouseDown(at: ScrollTargetPicker.pointer()) }
    override func mouseDragged(with event: NSEvent) { picker?.mouseDragged(to: ScrollTargetPicker.pointer()) }
    override func mouseUp(with event: NSEvent) { picker?.mouseUp(at: ScrollTargetPicker.pointer()) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { picker?.cancel() } else { super.keyDown(with: event) }
    }

    private func local(_ rect: CGRect) -> NSRect {
        rect.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.32).setFill()
        bounds.fill()
        if let highlight {
            let rect = local(highlight)
            // Show the chosen area almost at full brightness. It must not be completely see-through:
            // clicks on fully transparent pixels would go to the window underneath instead of here.
            NSColor.black.withAlphaComponent(0.06).setFill()
            rect.fill(using: .copy)
            if let windowFrame, windowFrame != highlight {
                NSColor.white.withAlphaComponent(0.55).setStroke()
                let outline = NSBezierPath(roundedRect: local(windowFrame).insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
                outline.lineWidth = 1
                outline.stroke()
            }
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(rect: rect.insetBy(dx: 1.5, dy: 1.5))
            border.lineWidth = 3
            border.stroke()
            if let caption { drawPill(caption, centeredAt: NSPoint(x: rect.midX, y: max(rect.minY + 26, 30)), emphasized: true) }
        }
        drawPill(hint, centeredAt: NSPoint(x: bounds.midX, y: bounds.maxY - 64), emphasized: false)
    }

    private func drawPill(_ text: String, centeredAt center: NSPoint, emphasized: Bool) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: emphasized ? 13 : 14, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        var rect = NSRect(x: center.x - size.width / 2 - 14, y: center.y - size.height / 2 - 7, width: size.width + 28, height: size.height + 14)
        rect.origin.x = min(max(rect.minX, 8), max(8, bounds.maxX - rect.width - 8))
        (emphasized ? NSColor.controlAccentColor : NSColor.black.withAlphaComponent(0.78)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        (text as NSString).draw(at: NSPoint(x: rect.minX + 14, y: rect.minY + 7), withAttributes: attributes)
    }
}
