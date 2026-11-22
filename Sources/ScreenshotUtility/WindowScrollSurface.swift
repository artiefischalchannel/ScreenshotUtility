import AppKit
import ApplicationServices
import ImageIO
@preconcurrency import ScreenCaptureKit

/// What the user picked. Rectangles and points are in global display coordinates (points, origin at
/// the top-left of the primary display), as used by CGEvent, CGWindowList and the Accessibility API.
struct ScrollTarget: Sendable {
    let windowID: CGWindowID
    let pid: pid_t
    let appName: String
    let windowFrame: CGRect
    /// The part of the window to capture and stitch.
    let region: CGRect
    /// Where scroll events are aimed.
    let scrollPoint: CGPoint
}

struct AXRef: @unchecked Sendable {
    let element: AXUIElement
}

/// Read-only Accessibility queries. These are synchronous IPC to the other app, so call them off the main thread.
enum AXLookup {
    struct ScrollArea: Sendable {
        let frame: CGRect
        let verticalBar: AXRef?
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    static func application(_ pid: pid_t) -> AXUIElement {
        let application = AXUIElementCreateApplication(pid)
        // Never let a busy app hold up the picker or the capture.
        AXUIElementSetMessagingTimeout(application, 0.4)
        return application
    }

    static func hit(pid: pid_t, point: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(application(pid), Float(point.x), Float(point.y), &element) == .success else { return nil }
        return element
    }

    /// The innermost usefully-sized scrolling container under a point, clipped to its window.
    static func scrollArea(pid: pid_t, point: CGPoint, windowFrame: CGRect, legacyScrollBars: Bool) -> ScrollArea? {
        guard AXIsProcessTrusted() else { return nil }
        var current = hit(pid: pid, point: point)
        var webArea: CGRect?
        var depth = 0
        while let element = current, depth < 60 {
            depth += 1
            let role = string(element, kAXRoleAttribute)
            if role == kAXScrollAreaRole, var area = frame(element)?.intersection(windowFrame), area.width >= 100, area.height >= 100 {
                let bar = self.element(element, kAXVerticalScrollBarAttribute)
                if legacyScrollBars {
                    // Always-visible scroll bars sit beside the content; leave them out of the picture.
                    if let bar, let barFrame = frame(bar), barFrame.width < 40, abs(barFrame.maxX - area.maxX) < 2 {
                        area.size.width -= barFrame.width
                    }
                    if let horizontal = self.element(element, kAXHorizontalScrollBarAttribute), let barFrame = frame(horizontal),
                       barFrame.height < 40, abs(barFrame.maxY - area.maxY) < 2 {
                        area.size.height -= barFrame.height
                    }
                }
                return ScrollArea(frame: area.integral, verticalBar: bar.map(AXRef.init))
            }
            if role == "AXWebArea", webArea == nil, let area = frame(element)?.intersection(windowFrame), area.width >= 100, area.height >= 100 {
                webArea = area
            }
            if role == kAXWindowRole { break }
            current = self.element(element, kAXParentAttribute)
        }
        return webArea.map { ScrollArea(frame: $0.integral, verticalBar: nil) }
    }

    /// Brings the window containing `point` to the front so that scroll events aimed at it arrive.
    static func raiseWindow(pid: pid_t, point: CGPoint) {
        let application = application(pid)
        AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        guard let element = hit(pid: pid, point: point) else { return }
        let window = string(element, kAXRoleAttribute) == kAXWindowRole ? element : self.element(element, kAXWindowAttribute)
        if let window {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
    }
}

enum WindowScrollSurfaceError: Error {
    case windowUnavailable
    case areaTooSmall
    case windowChanged
    /// Another app's window is in front of the spot being scrolled, so scrolling no longer reaches the target.
    case covered(by: String)
}

/// Captures one region of one window with ScreenCaptureKit and scrolls it with synthetic wheel events.
@available(macOS 14.0, *)
actor WindowScrollSurface: ScrollSurface {
    private let target: ScrollTarget
    private var filter: SCContentFilter?
    private let configuration = SCStreamConfiguration()
    private var cropX = 0, cropY = 0, cropWidth = 0, cropHeight = 0
    private var pixelScale = 2.0
    private var colorSpace: CGColorSpace?
    private var scrollPoint: CGPoint
    private var savedCursor: CGPoint?
    private var bar: AXRef?
    private var coveredBy: String?
    private let eventSource = CGEventSource(stateID: .combinedSessionState)
    /// Replaces wheel events (used by the developer self-test, which scrolls its own web view).
    private let customScroll: (@Sendable (Double) async -> Void)?

    init(target: ScrollTarget, customScroll: (@Sendable (Double) async -> Void)? = nil) {
        self.target = target
        self.customScroll = customScroll
        scrollPoint = target.scrollPoint
    }

    var scale: Double { pixelScale }

    func prepare(legacyScrollBars: Bool) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == target.windowID }) else {
            throw WindowScrollSurfaceError.windowUnavailable
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        self.filter = filter
        pixelScale = Double(filter.pointPixelScale)
        let frame = window.frame
        let imageWidth = Int((frame.width * pixelScale).rounded()), imageHeight = Int((frame.height * pixelScale).rounded())
        configuration.width = imageWidth
        configuration.height = imageHeight
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        configuration.scalesToFit = false

        // The region is kept relative to the window in case the window moved since it was picked.
        let region = target.region.offsetBy(dx: -target.windowFrame.minX, dy: -target.windowFrame.minY)
        cropX = max(0, Int((region.minX * pixelScale).rounded(.up)))
        cropY = max(0, Int((region.minY * pixelScale).rounded(.up)))
        cropWidth = min(imageWidth, Int((region.maxX * pixelScale).rounded(.down))) - cropX
        cropHeight = min(imageHeight, Int((region.maxY * pixelScale).rounded(.down))) - cropY
        guard cropWidth >= 64, cropHeight >= 96 else { throw WindowScrollSurfaceError.areaTooSmall }
        scrollPoint = CGPoint(x: target.scrollPoint.x + frame.minX - target.windowFrame.minX,
                              y: target.scrollPoint.y + frame.minY - target.windowFrame.minY)

        guard customScroll == nil else { return }
        AXLookup.raiseWindow(pid: target.pid, point: scrollPoint)
        NSRunningApplication(processIdentifier: target.pid)?.activate()
        try await Task.sleep(for: .milliseconds(350))
        bar = AXLookup.scrollArea(pid: target.pid, point: scrollPoint, windowFrame: frame, legacyScrollBars: legacyScrollBars)?.verticalBar
        savedCursor = CGEvent(source: nil)?.location
        aimCursor()
        try await Task.sleep(for: .milliseconds(120))
    }

    /// Puts the pointer back where the user left it.
    func finish() {
        if let savedCursor {
            CGWarpMouseCursorPosition(savedCursor)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        savedCursor = nil
    }

    func grab() async throws -> ScrollFrame {
        guard let filter else { throw WindowScrollSurfaceError.windowUnavailable }
        if let coveredBy { throw WindowScrollSurfaceError.covered(by: coveredBy) }
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        if colorSpace == nil { colorSpace = image.colorSpace }
        guard image.width >= cropX + cropWidth, image.height >= cropY + cropHeight else { throw WindowScrollSurfaceError.windowChanged }
        return ScrollFrame(width: cropWidth, height: cropHeight, pixels: Self.pixels(of: image, x: cropX, y: cropY, width: cropWidth, height: cropHeight))
    }

    func scroll(points: Double) async {
        if let customScroll { return await customScroll(points) }
        // Wheel events go to whatever is under the pointer, so keep it over the scrolling area, and
        // never scroll some other app's window that has come in front.
        coveredBy = Self.appCovering(windowID: target.windowID, pid: target.pid, at: scrollPoint)
        guard coveredBy == nil else { return }
        aimCursor()
        let total = Int((-points).rounded())
        guard total != 0 else { return }
        // Glide instead of jumping: the same distance spread over a few screen refreshes, easing in
        // and out. The amounts are whole numbers that add up to exactly the distance asked for.
        let count = abs(total) < 40 ? 1 : min(14, max(6, abs(total) / 40))
        var sent = 0
        for index in 1...count {
            let progress = Double(index) / Double(count)
            let eased = progress * progress * (3 - 2 * progress)
            let reached = index == count ? total : Int((Double(total) * eased).rounded())
            post(reached - sent)
            sent = reached
            // If the capture is cancelled the pause is skipped, and the rest is sent at once.
            if index < count { try? await Task.sleep(for: .milliseconds(12)) }
        }
    }

    private func post(_ amount: Int) {
        var remaining = amount
        while remaining != 0 {
            let delta = Int32(max(-30_000, min(30_000, remaining)))
            remaining -= Int(delta)
            guard let event = CGEvent(scrollWheelEvent2Source: eventSource, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else { return }
            event.location = scrollPoint
            event.post(tap: .cghidEventTap)
        }
    }

    func scrollBarPosition() -> Double? {
        guard let bar else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar.element, kAXValueAttribute as CFString, &value) == .success,
              let number = value as? NSNumber else { return nil }
        return number.doubleValue
    }

    func setScrollBarPosition(_ value: Double) -> Bool {
        guard let bar else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(bar.element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue else { return false }
        return AXUIElementSetAttributeValue(bar.element, kAXValueAttribute as CFString, NSNumber(value: min(1, max(0, value)))) == .success
    }

    /// Wraps the stitched pixels as an image without copying them.
    func makeImage(_ buffer: ScrollImageBuffer) -> CGImage? {
        Self.makeImage(buffer, colorSpace: colorSpace)
    }

    func makeImage(_ frame: ScrollFrame) -> CGImage? {
        let data = frame.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frame.width * 4,
            space: colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    static func makeImage(_ buffer: ScrollImageBuffer, colorSpace: CGColorSpace?) -> CGImage? {
        let count = buffer.width * buffer.height
        var opaque = true
        for index in 0..<count where buffer.baseAddress[index] >> 24 != 0xFF {
            opaque = false
            break
        }
        let info = Unmanaged.passRetained(buffer).toOpaque()
        guard let provider = CGDataProvider(dataInfo: info, data: buffer.baseAddress, size: count * 4, releaseData: { info, _, _ in
            if let info { Unmanaged<ScrollImageBuffer>.fromOpaque(info).release() }
        }) else {
            Unmanaged<ScrollImageBuffer>.fromOpaque(info).release()
            return nil
        }
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipFirst : .premultipliedFirst
        return CGImage(
            width: buffer.width, height: buffer.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: buffer.width * 4,
            space: colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | alpha.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// The name of another app whose ordinary window is in front of `windowID` at `point`, if any.
    private static func appCovering(windowID: CGWindowID, pid: pid_t, at point: CGPoint) -> String? {
        let own = getpid()
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner != own,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.contains(point) else { continue }
            // The list is front to back: the first ordinary window at the point is the one that gets the scroll.
            if (info[kCGWindowNumber as String] as? CGWindowID) == windowID || owner == pid { return nil }
            return info[kCGWindowOwnerName as String] as? String ?? "Another app"
        }
        return nil
    }

    private func aimCursor() {
        if let location = CGEvent(source: nil)?.location, hypot(location.x - scrollPoint.x, location.y - scrollPoint.y) < 1.5 { return }
        CGWarpMouseCursorPosition(scrollPoint)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Copies a rectangle of the capture as premultiplied BGRA words, untouched (no scaling or color conversion).
    private static func pixels(of image: CGImage, x: Int, y: Int, width: Int, height: Int) -> [UInt32] {
        let alpha = image.alphaInfo
        let littleEndian = image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little
        if image.bitsPerPixel == 32, image.bitsPerComponent == 8, littleEndian, alpha == .premultipliedFirst || alpha == .noneSkipFirst,
           let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
           CFDataGetLength(data) >= image.bytesPerRow * (y + height - 1) + (x + width) * 4 {
            let stride = image.bytesPerRow
            var pixels = [UInt32](unsafeUninitializedCapacity: width * height) { buffer, count in
                for row in 0..<height {
                    memcpy(buffer.baseAddress! + row * width, bytes + (y + row) * stride + x * 4, width * 4)
                }
                count = width * height
            }
            if alpha == .noneSkipFirst {
                for index in pixels.indices { pixels[index] |= 0xFF00_0000 }
            }
            return pixels
        }
        // Unexpected pixel layout: redraw into the layout the stitcher works in.
        var pixels = [UInt32](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            ) else { return }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: -x, y: -(image.height - y - height), width: image.width, height: image.height))
        }
        return pixels
    }
}

enum CaptureFile {
    /// Writes a PNG whose resolution metadata matches the display scale, as `screencapture` does,
    /// so the image opens at its on-screen size.
    static func writePNG(_ image: CGImage, to url: URL, pixelsPerPoint: Double) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).partial")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let dpi = 72 * pixelsPerPoint
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.moveItem(at: temporary, to: url)
    }
}
