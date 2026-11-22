import Testing
import Foundation
@testable import ScreenshotUtility

/// A synthetic scrollable window: a tall "document" of text-like blocks shown through a viewport,
/// optionally with a sticky header, sticky footer, fixed sidebar and an overlay scroll thumb.
private struct Layout: Sendable {
    var width = 384
    var viewport = 300
    var documentHeight = 2400
    var header = 0
    var footer = 0
    var sidebar = 0
    /// Rows the app actually moves per requested pixel (1 = exact).
    var ratio = 1.0
    /// The app only scrolls in multiples of this many pixels (like a terminal scrolling by lines).
    var quantum = 1
    var overlayThumb = false
    enum Style: Sendable { case article, list, grid, gap }
    var style = Style.article

    var scrollRange: Int { documentHeight - viewport }

    private static func mix(_ a: Int, _ b: Int, _ c: Int) -> UInt64 {
        var value = UInt64(truncatingIfNeeded: a &* 0x9E37_79B9) ^ (UInt64(truncatingIfNeeded: b) << 20) ^ (UInt64(truncatingIfNeeded: c) << 40)
        value = (value ^ (value >> 31)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 29)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 32)
    }

    /// Content pixel at document coordinates.
    func document(_ x: Int, _ y: Int) -> UInt32 {
        if style == .list || style == .grid {
            // Rows that look alike: striped backgrounds, a rule under each row, the same label in every
            // row. A list also numbers its rows; a grid has nothing to tell one row from another.
            let item = y / 44, within = y % 44
            if within == 43 { return 0xFFD0_D0D4 }
            let background: UInt32 = item % 2 == 0 ? 0xFFFF_FFFF : 0xFFF4_F5F7
            if within >= 14, within < 30 {
                if x >= 110, x < 230, (x / 6) % 2 == 0 { return 0xFF33_3338 }
                if style == .list, x >= 24, x < 84, Layout.mix(item, x / 5, within / 4) % 2 == 0 { return 0xFF10_1014 }
            }
            return background
        }
        // A blank stretch much taller than the window.
        if style == .gap, y >= 900, y < 1700 { return 0xFFFF_FFFF }
        let line = y / 20, row = y % 20
        // Some empty stretches and some identical lines, as real pages have.
        if row >= 14 || (line % 23 >= 19) { return 0xFFFF_FFFF }
        let key = (line % 31 == 7 || line % 31 == 8) ? 7 : line
        let block = Layout.mix(key, x / 8, row / 7)
        if block % 3 == 0 { return 0xFFFF_FFFF }
        return 0xFF00_0000 | UInt32(block >> 8 & 0x7F7F7F)
    }

    func headerPixel(_ x: Int, _ y: Int) -> UInt32 {
        Layout.mix(900, x / 12, y / 6) % 2 == 0 ? 0xFF30_3036 : 0xFFE0_E0E8
    }

    func footerPixel(_ x: Int, _ y: Int) -> UInt32 {
        Layout.mix(901, x / 10, y / 5) % 2 == 0 ? 0xFF20_4060 : 0xFFD0_E0F0
    }

    static let sidebarBackground: UInt32 = 0xFFEE_EEF2

    func sidebarPixel(_ x: Int, _ y: Int) -> UInt32 {
        guard y % 24 < 12, x > 8, x < sidebar - 8 else { return Layout.sidebarBackground }
        return Layout.mix(902, x / 9, y / 24) % 3 == 0 ? Layout.sidebarBackground : 0xFF40_4048
    }

    /// What the window shows when scrolled to `offset`.
    func frame(offset: Int, thumb: Bool = false) -> ScrollFrame {
        var pixels = [UInt32](repeating: 0, count: width * viewport)
        let thumbTop = header + (viewport - header - footer) * offset / documentHeight
        let thumbLength = max(20, (viewport - header - footer) * viewport / documentHeight)
        for y in 0..<viewport {
            for x in 0..<width {
                let pixel: UInt32
                if y < header { pixel = headerPixel(x, y) }
                else if y >= viewport - footer { pixel = footerPixel(x, y - (viewport - footer)) }
                else if x < sidebar { pixel = sidebarPixel(x, y) }
                else if thumb, x >= width - 10, x < width - 3, y >= thumbTop, y < thumbTop + thumbLength { pixel = 0xFF80_8080 }
                else { pixel = document(x, y + offset) }
                pixels[y * width + x] = pixel
            }
        }
        return ScrollFrame(width: width, height: viewport, pixels: pixels)
    }
}

private actor SimulatedSurface: ScrollSurface {
    let layout: Layout
    private(set) var offset: Int
    private var pending = 0.0
    private var thumbUntil = ContinuousClock.now
    private(set) var grabs = 0
    let exposesScrollBar: Bool
    var frozen = false

    init(layout: Layout, offset: Int = 0, exposesScrollBar: Bool = false) {
        self.layout = layout
        self.offset = offset
        self.exposesScrollBar = exposesScrollBar
    }

    var scale: Double { 2 }

    func freeze() { frozen = true }

    func grab() async throws -> ScrollFrame {
        grabs += 1
        return layout.frame(offset: offset, thumb: layout.overlayThumb && ContinuousClock.now < thumbUntil)
    }

    func scroll(points: Double) async {
        guard !frozen else { return }
        pending += points * 2 * layout.ratio
        let whole = Int(pending / Double(layout.quantum)) * layout.quantum
        pending -= Double(whole)
        let target = min(layout.scrollRange, max(0, offset + whole))
        if target != offset {
            offset = target
            thumbUntil = .now + .milliseconds(40)
        }
    }

    func scrollBarPosition() async -> Double? {
        exposesScrollBar ? Double(offset) / Double(layout.scrollRange) : nil
    }

    func setScrollBarPosition(_ value: Double) async -> Bool {
        guard exposesScrollBar else { return false }
        offset = Int((value * Double(layout.scrollRange)).rounded())
        return true
    }
}

private let fastTiming = ScrollCaptureTiming(
    poll: .milliseconds(1), stable: .milliseconds(4), noResponse: .milliseconds(12), maxSettle: .milliseconds(300),
    scrollerWatch: .milliseconds(120), scrollerMargin: .milliseconds(30), retryDelay: .milliseconds(5)
)

/// Checks the stitched image against what the document really contains.
/// The capture begins at `start` (the scroll offset when it was started) and runs to the end.
private func expectFaithful(_ image: ScrollImageBuffer, _ layout: Layout, from start: Int = 0, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(image.width == layout.width, sourceLocation: sourceLocation)
    #expect(image.height == layout.documentHeight - start, sourceLocation: sourceLocation)
    guard image.width == layout.width, image.height == layout.documentHeight - start else { return }
    var wrong = 0
    var firstWrong: [String] = []
    for y in 0..<image.height {
        for x in 0..<image.width {
            let expected: UInt32
            if y < layout.header { expected = layout.headerPixel(x, y) }
            else if y >= image.height - layout.footer { expected = layout.footerPixel(x, y - (image.height - layout.footer)) }
            else if x < layout.sidebar { expected = y < layout.viewport - layout.footer ? layout.sidebarPixel(x, y) : Layout.sidebarBackground }
            else { expected = layout.document(x, y + start) }
            if image[x, y] != expected {
                wrong += 1
                if firstWrong.count < 6 || (wrong % 5000 == 0 && firstWrong.count < 20) { firstWrong.append("(\(x),\(y))") }
            }
        }
    }
    #expect(wrong == 0, "\(wrong) pixels differ from the source document, e.g. \(firstWrong.joined(separator: " "))", sourceLocation: sourceLocation)
}

struct ScrollStitcherTests {
    @Test func findsExactShiftAndReportsNoMotion() {
        let layout = Layout()
        let a = layout.frame(offset: 400), b = layout.frame(offset: 533)
        #expect(ScrollStitching.motion(from: a, to: b, expected: 120) == .moved(133))
        #expect(ScrollStitching.motion(from: a, to: a, expected: 120) == .unchanged)
        // One pixel is still a real movement.
        #expect(ScrollStitching.motion(from: a, to: layout.frame(offset: 401), expected: 120) == .moved(1))
    }

    @Test func unrelatedFramesDoNotAlign() {
        let layout = Layout()
        let a = layout.frame(offset: 0), b = layout.frame(offset: 1500)
        #expect(ScrollStitching.motion(from: a, to: b, expected: 150) == .failed)
    }

    @Test func stickyHeaderAndSidebarAreSeparatedFromScrollingContent() {
        var layout = Layout()
        layout.header = 44
        layout.footer = 30
        layout.sidebar = 96
        let a = layout.frame(offset: 200), b = layout.frame(offset: 310)
        #expect(ScrollStitching.motion(from: a, to: b, expected: 100) == .moved(110))
        let analysis = ScrollStitching.analyze(from: a, to: b, shift: 110)
        #expect(analysis.header == 44)
        let edges = ScrollStitching.fixedEdges(
            stillMisses: analysis.columnStillMisses.map(Int.init), movedMisses: analysis.columnMovedMisses.map(Int.init), samples: analysis.columnSamples
        )
        // The sidebar's outer padding is flat, so only its textured part must be recognised as fixed.
        #expect(edges.left > 80 && edges.left <= 96, "left edge \(edges.left)")
        #expect(edges.right == 0)
    }

    @Test func repeatingContentUsesTheExpectedDistance() {
        // Identical lines every 20 px: every multiple of 20 aligns equally well.
        var pixels = [UInt32](repeating: 0xFFFF_FFFF, count: 320 * 300)
        for y in 0..<300 where y % 20 < 10 { for x in 20..<300 where (x / 6) % 2 == 0 { pixels[y * 320 + x] = 0xFF22_2222 } }
        let frame = ScrollFrame(width: 320, height: 300, pixels: pixels)
        var shifted = [UInt32](repeating: 0xFFFF_FFFF, count: 320 * 300)
        for y in 0..<300 where (y + 60) % 20 < 10 { for x in 20..<300 where (x / 6) % 2 == 0 { shifted[y * 320 + x] = 0xFF22_2222 } }
        shifted[5] = 0xFF00_00FF
        let next = ScrollFrame(width: 320, height: 300, pixels: shifted)
        #expect(ScrollStitching.motion(from: frame, to: next, expected: 100) != .failed)
    }
}

struct ScrollCaptureEngineTests {
    private func run(_ layout: Layout, offset: Int = 0, scrollBar: Bool = false, limits: ScrollCaptureLimits = .init()) async throws -> (ScrollCaptureResult, SimulatedSurface) {
        let surface = SimulatedSurface(layout: layout, offset: offset, exposesScrollBar: scrollBar)
        let engine = ScrollCaptureEngine(surface: surface, timing: fastTiming, limits: limits)
        return (try await engine.run(), surface)
    }

    @Test func capturesFromTheCurrentPositionDownAndRestoresIt() async throws {
        let layout = Layout()
        let (result, surface) = try await run(layout, offset: 730)
        expectFaithful(result.image, layout, from: 730)
        #expect(result.stop == .reachedEnd)
        #expect(result.restored)
        #expect(await surface.offset == 730)
    }

    @Test func stickyHeaderFooterAndSidebarAppearOnce() async throws {
        var layout = Layout()
        layout.header = 44
        layout.footer = 30
        layout.sidebar = 96
        let (result, surface) = try await run(layout, offset: 0)
        expectFaithful(result.image, layout)
        #expect(await surface.offset == 0)
    }

    @Test func overlayScrollThumbIsNotBakedIntoTheImage() async throws {
        var layout = Layout()
        layout.overlayThumb = true
        let (result, _) = try await run(layout)
        expectFaithful(result.image, layout)
    }

    @Test func handlesAppsThatScrollByLinesOrAtADifferentRate() async throws {
        var layout = Layout()
        layout.quantum = 20
        layout.ratio = 1.6
        let (result, surface) = try await run(layout, offset: 400)
        expectFaithful(result.image, layout, from: 400)
        let offset = await surface.offset
        #expect(offset == 400)
    }

    @Test func restoresThroughTheScrollBarWhenTheAppExposesOne() async throws {
        let layout = Layout()
        let (result, surface) = try await run(layout, offset: 1234, scrollBar: true)
        expectFaithful(result.image, layout, from: 1234)
        #expect(result.restored)
        #expect(await surface.offset == 1234)
    }

    @Test func listsOfSimilarRowsAreStitchedExactly() async throws {
        var layout = Layout()
        layout.style = .list
        layout.documentHeight = 4400
        let (result, surface) = try await run(layout, offset: 616)
        expectFaithful(result.image, layout, from: 616)
        let offset = await surface.offset
        #expect(offset == 616)
    }

    @Test func contentWithNothingToTellRowsApartIsReportedNotSilentlySaved() async throws {
        var layout = Layout()
        layout.style = .grid
        layout.documentHeight = 4400
        let surface = SimulatedSurface(layout: layout)
        let engine = ScrollCaptureEngine(surface: surface, timing: fastTiming)
        do {
            _ = try await engine.run()
            Issue.record("A capture that could not be verified was returned as if it were reliable")
        } catch ScrollCaptureError.repetitive(let image) {
            // What it produced is still offered to the user, who decides.
            #expect(image.width == layout.width)
        }
    }

    @Test func blankStretchTallerThanTheWindowDoesNotEndTheCapture() async throws {
        var layout = Layout()
        layout.style = .gap
        let (result, _) = try await run(layout)
        #expect(result.stop == .reachedEnd)
        #expect(result.image.height == layout.documentHeight)
        // Everything after the gap is present and in the right place.
        var wrong = 0
        for y in 0..<min(result.image.height, layout.documentHeight) {
            for x in 0..<layout.width where result.image[x, y] != layout.document(x, y) { wrong += 1 }
        }
        #expect(wrong == 0)
    }

    @Test func stopsAtTheHeightLimitInsteadOfRunningForever() async throws {
        var layout = Layout()
        layout.documentHeight = 60_000
        let (result, _) = try await run(layout, limits: ScrollCaptureLimits(maxHeight: 3000))
        #expect(result.stop == .sizeLimit)
        // As close to the limit as whole sections allow, and never over it.
        #expect(result.image.height > 2600 && result.image.height <= 3000)
    }

    @Test func reportsAnAreaThatDoesNotScroll() async throws {
        var layout = Layout()
        layout.documentHeight = layout.viewport
        let surface = SimulatedSurface(layout: layout)
        let engine = ScrollCaptureEngine(surface: surface, timing: fastTiming)
        await #expect(throws: ScrollCaptureError.self) { try await engine.run() }
    }

    @Test func cancellingRestoresThePosition() async throws {
        var layout = Layout()
        layout.documentHeight = 40_000
        let surface = SimulatedSurface(layout: layout, offset: 900)
        let engine = ScrollCaptureEngine(surface: surface, timing: fastTiming)
        let task = Task { try await engine.run() }
        try await Task.sleep(for: .milliseconds(600))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let offset = await surface.offset
        #expect(offset == 900)
    }

    @Test func outlinedBoxPicksTheWindowItCovers() {
        // Front-to-back: a small front window, then a large one behind it.
        let frames = [CGRect(x: 100, y: 100, width: 300, height: 300), CGRect(x: 0, y: 33, width: 1728, height: 1000)]
        // Drawn inside the front window.
        #expect(ScrollTargetPicker.windowIndex(forBox: CGRect(x: 150, y: 150, width: 100, height: 100), frames: frames) == 0)
        // Drawn over the back window only, starting above it in the menu bar.
        #expect(ScrollTargetPicker.windowIndex(forBox: CGRect(x: 600, y: 0, width: 400, height: 500), frames: frames) == 1)
        // Middle of the box is outside every window: the one it overlaps most wins.
        #expect(ScrollTargetPicker.windowIndex(forBox: CGRect(x: 1500, y: 900, width: 400, height: 400), frames: frames) == 1)
        // Nothing under it.
        #expect(ScrollTargetPicker.windowIndex(forBox: CGRect(x: 0, y: 0, width: 200, height: 20), frames: frames) == nil)
    }
}
