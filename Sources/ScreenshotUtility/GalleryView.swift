import AppKit
import ImageIO

@MainActor
private final class GalleryScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        // Avoid AppKit's animated scrolling, which can defer its updates until
        // NSMenu's tracking loop exits. Precise trackpad/momentum deltas remain pixel-based.
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 20
        let maxY = max(0, (documentView?.bounds.height ?? 0) - contentView.bounds.height)
        let y = min(maxY, max(0, contentView.bounds.minY - event.scrollingDeltaY * factor))
        contentView.scroll(to: NSPoint(x: 0, y: y))
        reflectScrolledClipView(contentView)
    }
}

@MainActor
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class CaptureTile: NSButton {
    let capture: RecentCapture
    var preview: NSImage?
    /// The preview shows only the top of a very tall (scrolling) capture.
    var isLong = false
    var failed = false
    var requested = false

    init(capture: RecentCapture, frame: NSRect) {
        self.capture = capture
        super.init(frame: frame)
        isBordered = false
        title = ""
        let date = DateFormatter.localizedString(from: capture.capturedAt, dateStyle: .short, timeStyle: .short)
        toolTip = "\(capture.url.lastPathComponent)\n\(date) — Click to copy image"
        setAccessibilityLabel("Screenshot, \(date)")
        setAccessibilityHelp("Copy the full image to the clipboard")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func scrollWheel(with event: NSEvent) {
        enclosingScrollView?.scrollWheel(with: event)
    }
    override func mouseEntered(with event: NSEvent) { needsDisplay = true }
    override func mouseExited(with event: NSEvent) { needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let well = NSRect(x: 0, y: 0, width: bounds.width, height: 116)
        let path = NSBezierPath(roundedRect: well.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.13).setFill()
        path.fill()
        let hover = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) && visibleRect.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        (hover ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = hover ? 2 : 0.5
        path.stroke()
        if let preview {
            let inset = well.insetBy(dx: 4, dy: 4)
            let scale = min(inset.width / preview.size.width, inset.height / preview.size.height)
            let size = NSSize(width: preview.size.width * scale, height: preview.size.height * scale)
            let rect = NSRect(x: inset.midX - size.width / 2, y: inset.midY - size.height / 2, width: size.width, height: size.height)
            preview.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            if isLong {
                // Mark it as the top of a longer image.
                let badge = NSRect(x: well.maxX - 30, y: well.maxY - 24, width: 22, height: 16)
                NSColor.black.withAlphaComponent(0.6).setFill()
                NSBezierPath(roundedRect: badge, xRadius: 8, yRadius: 8).fill()
                drawLabel("↕", in: badge.offsetBy(dx: 0, dy: 1), color: .white)
            }
        } else {
            let message = failed ? "Can’t preview" : "Loading…"
            drawLabel(message, in: well, color: .secondaryLabelColor, centeredVertically: true)
        }
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        drawLabel(formatter.string(from: capture.capturedAt), in: NSRect(x: 0, y: 120, width: bounds.width, height: 16), color: .secondaryLabelColor)
    }
    private func drawLabel(_ text: String, in rect: NSRect, color: NSColor, centeredVertically: Bool = false) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        var target = rect
        if centeredVertically { target.origin.y = rect.midY - 7; target.size.height = 16 }
        (text as NSString).draw(in: target, withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: color, .paragraphStyle: paragraph])
    }
}

@MainActor
final class GalleryView: NSView {
    static let width: CGFloat = 392
    private let scroll = GalleryScrollView()
    private let document = FlippedView()
    private let empty = NSTextField(labelWithString: "No screenshots in the last 48 hours")
    private var tiles: [CaptureTile] = []
    private let thumbnailQueue = DispatchQueue(label: "ScreenshotUtility.thumbnails", qos: .userInitiated)
    private let cache = NSCache<NSString, NSImage>()
    private var generation = 0
    private var longPreviews: Set<String> = []
    private var captures: [RecentCapture] = []
    private var message: String?
    var onCopy: ((URL) -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 330))
        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        addSubview(scroll)
        empty.alignment = .center
        empty.font = .systemFont(ofSize: 12)
        empty.textColor = .secondaryLabelColor
        addSubview(empty)
        cache.totalCostLimit = 32 * 1024 * 1024
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func prepareHeight(screenHeight: CGFloat) {
        // Only call before menu tracking starts. Contents may change while tracking,
        // but the outer view must retain the same dimensions until the next open.
        let content = captures.isEmpty ? 110 : CGFloat((captures.count + 1) / 2) * 144 + 12
        frame.size.height = max(48, min(content, 330, screenHeight - 260))
        document.frame.size.height = max(frame.height, captures.isEmpty ? 0 : CGFloat((captures.count + 1) / 2) * 144 + 12)
        let maxY = max(0, document.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(maxY, scroll.contentView.bounds.minY)))
        scroll.reflectScrolledClipView(scroll.contentView)
        layoutEmpty()
    }

    func update(_ captures: [RecentCapture], error: String?) {
        guard self.captures != captures || message != error else { return }
        self.captures = captures
        message = error
        generation += 1
        let anchorIndex = Int(scroll.contentView.bounds.minY / 144) * 2
        let anchor = tiles.indices.contains(anchorIndex) ? tiles[anchorIndex].capture.url : nil
        let offset = scroll.contentView.bounds.minY.truncatingRemainder(dividingBy: 144)
        tiles.forEach { $0.removeFromSuperview() }
        tiles = captures.enumerated().map { index, capture in
            let tile = CaptureTile(capture: capture, frame: NSRect(x: 14 + (index % 2) * 188, y: 6 + (index / 2) * 144, width: 176, height: 136))
            tile.target = self
            tile.action = #selector(copyTile(_:))
            document.addSubview(tile)
            return tile
        }
        document.frame = NSRect(x: 0, y: 0, width: Self.width, height: max(bounds.height, CGFloat((captures.count + 1) / 2) * 144 + 12))
        if let anchor, let index = captures.firstIndex(where: { $0.url == anchor }) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, document.bounds.height - scroll.contentSize.height), CGFloat(index / 2) * 144 + offset)))
        } else { scroll.contentView.scroll(to: .zero) }
        scroll.reflectScrolledClipView(scroll.contentView)
        empty.stringValue = error ?? "No screenshots in the last 48 hours"
        layoutEmpty()
        loadVisibleThumbnails()
    }

    override func layout() {
        super.layout()
        layoutEmpty()
    }
    private func layoutEmpty() {
        empty.frame = NSRect(x: 10, y: bounds.midY - 9, width: bounds.width - 20, height: 18)
        empty.isHidden = !captures.isEmpty
        scroll.isHidden = captures.isEmpty
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { loadVisibleThumbnails() }
    }
    @objc private func scrolled() {
        tiles.forEach { $0.needsDisplay = true }
        loadVisibleThumbnails()
    }
    @objc private func copyTile(_ tile: CaptureTile) { onCopy?(tile.capture.url) }

    /// Proportions of the preview well, which a long capture's preview is cropped to.
    private nonisolated static let wellAspect: CGFloat = 168.0 / 108.0

    nonisolated static func isLongPreview(_ image: CGImage) -> Bool {
        image.height > 0 && abs(CGFloat(image.width) / CGFloat(image.height) - wellAspect) < 0.02
    }

    /// A normal capture is scaled to fit. A very tall one (a scrolling capture) would shrink to an
    /// unrecognisable sliver, so its preview is the top of the image at a readable size instead.
    nonisolated static func thumbnail(from source: CGImageSource) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let long = width > 0 && height > width * 3
        let maxSize = long ? min(8192, 352 * height / width) : 352
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { return nil }
        guard long else { return image }
        let visible = min(image.height, Int((CGFloat(image.width) / wellAspect).rounded()))
        return image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: visible)) ?? image
    }

    private func loadVisibleThumbnails() {
        let visible = scroll.contentView.bounds.insetBy(dx: 0, dy: -144)
        for tile in tiles where !tile.frame.intersects(visible) {
            tile.preview = nil
            tile.requested = false
        }
        for tile in tiles where tile.frame.intersects(visible) && !tile.requested {
            tile.requested = true
            let capture = tile.capture
            let key = "\(capture.url.path)|\(capture.modifiedAt.timeIntervalSince1970)|\(capture.size)"
            if let image = cache.object(forKey: key as NSString) {
                tile.preview = image
                tile.isLong = longPreviews.contains(key)
                tile.needsDisplay = true
                continue
            }
            let generation = generation
            thumbnailQueue.async { [weak self, weak tile] in
                let source = CGImageSourceCreateWithURL(capture.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
                let image = source.flatMap { GalleryView.thumbnail(from: $0) }
                RunLoop.main.perform(inModes: [.default, .eventTracking]) { [weak self, weak tile] in
                    MainActor.assumeIsolated {
                        guard let self, let tile, self.generation == generation else { return }
                        if let image {
                            if GalleryView.isLongPreview(image) { self.longPreviews.insert(key) }
                            tile.isLong = self.longPreviews.contains(key)
                            let preview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                            self.cache.setObject(preview, forKey: key as NSString, cost: image.bytesPerRow * image.height)
                            if tile.frame.intersects(self.scroll.contentView.bounds.insetBy(dx: 0, dy: -144)) {
                                tile.preview = preview
                            } else { tile.requested = false }
                        } else {
                            tile.failed = true
                            tile.isEnabled = false
                            tile.setAccessibilityLabel("Screenshot preview unavailable")
                        }
                        tile.needsDisplay = true
                    }
                }
            }
        }
    }
}
