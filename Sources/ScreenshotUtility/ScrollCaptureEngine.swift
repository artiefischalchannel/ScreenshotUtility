import Foundation

/// Something that can be scrolled and photographed. The real implementation drives a window;
/// tests drive a simulated document.
protocol ScrollSurface: Sendable {
    /// Device pixels per point.
    var scale: Double { get async }
    func grab() async throws -> ScrollFrame
    /// Positive values scroll toward the end of the content.
    func scroll(points: Double) async
    /// Position of the vertical scroll bar from 0 (top) to 1 (end), when the app exposes one.
    func scrollBarPosition() async -> Double?
    func setScrollBarPosition(_ value: Double) async -> Bool
}

struct ScrollCaptureTiming: Sendable {
    var poll: Duration = .milliseconds(25)
    /// How long the picture must hold still to count as settled.
    var stable: Duration = .milliseconds(100)
    /// How long to wait for any reaction before deciding the scroll did nothing.
    var noResponse: Duration = .milliseconds(350)
    var maxSettle: Duration = .milliseconds(2500)
    /// How long after the first scroll to watch for overlay scroll bars fading out.
    var scrollerWatch: Duration = .milliseconds(1700)
    var scrollerMargin: Duration = .milliseconds(350)
    var retryDelay: Duration = .milliseconds(400)
}

struct ScrollCaptureLimits: Sendable {
    /// The tallest image worth making, in pixels. Beyond this an image is slow to open, many apps and
    /// upload forms refuse or shrink it, and nobody scrolls through it. The capture stops here.
    var maxHeight = 30_000
    // Backstops only: memory for an unusually wide area, and anything that never settles.
    var maxPixels = 200_000_000
    var maxDuration: Duration = .seconds(120)
    var maxFrames = 800
}

struct ScrollCaptureProgress: Sendable {
    enum Phase: Sendable { case preparing, capturing, restoring }
    var phase: Phase
    var pixelHeight = 0
    var fraction: Double?
}

struct ScrollCaptureResult: Sendable {
    enum Stop: Sendable, Equatable { case reachedEnd, sizeLimit, timeLimit }
    let image: ScrollImageBuffer
    let stop: Stop
    let shifts: [Int]
    let restored: Bool
}

enum ScrollCaptureError: Error {
    /// The area never moved. `visible` is what it showed.
    case didNotScroll(visible: ScrollFrame)
    /// Consecutive captures could not be lined up. `partial` is everything stitched before that point.
    case alignment(partial: ScrollImageBuffer?)
    /// The content repeats so regularly that sections could only be placed by the distance asked for,
    /// not by what they show. `image` is the result of doing that.
    case repetitive(image: ScrollImageBuffer)
}

actor ScrollCaptureEngine {
    private enum Scrollers {
        case unknown, absent
        /// Overlay scroll bars flash on every scroll and take `fade` to disappear.
        case overlay(fade: Duration)
        /// They are still flashing, but now sit where the next section will cover them, so there is no need to wait.
        case overlayCovered(fade: Duration)
    }

    private let surface: any ScrollSurface
    private let timing: ScrollCaptureTiming
    private let limits: ScrollCaptureLimits
    private let clock = ContinuousClock()
    private var scale = 1.0
    private var noise = 0
    private var scrollers = Scrollers.unknown
    /// Top row of the scroll thumb in the most recent frame where its fade was seen.
    private var thumbTop: Int?

    // What is needed to put the view back where it was.
    private var originalBar: Double?
    /// Pixels the view has moved down from where it started, measured from the picture.
    private var travelled = 0
    /// Pixels asked for since the last measured section: movement that has not been measured yet.
    private var pending = 0.0
    private var ratio = 1.0
    private var ratioSamples: [Double] = []
    /// A short trace of what happened, for the developer validation report.
    private(set) var trace: [String] = []
    private var viewportPoints = 0.0
    private var startFrame: ScrollFrame?

    init(surface: any ScrollSurface, timing: ScrollCaptureTiming = .init(), limits: ScrollCaptureLimits = .init()) {
        self.surface = surface
        self.timing = timing
        self.limits = limits
    }

    /// Records how far the view really moved for what was asked. The median ignores the odd step that
    /// was cut short by the end of the content, and steadies apps that scroll in whole lines.
    private func calibrate(moved: Int, requestedPixels: Double) {
        guard requestedPixels > 0 else { return }
        ratioSamples.append(Double(moved) / requestedPixels)
        if ratioSamples.count > 15 { ratioSamples.removeFirst() }
        let sorted = ratioSamples.sorted()
        ratio = min(8, max(0.125, sorted[sorted.count / 2]))
    }

    func run(progress: @escaping @Sendable (ScrollCaptureProgress) -> Void = { _ in }) async throws -> ScrollCaptureResult {
        do {
            let captured = try await capture(progress)
            progress(.init(phase: .restoring, pixelHeight: captured.image.height))
            let restored = await restore()
            return ScrollCaptureResult(image: captured.image, stop: captured.stop, shifts: captured.shifts, restored: restored)
        } catch {
            progress(.init(phase: .restoring))
            _ = await restore()
            throw error
        }
    }

    // MARK: Capture

    private func capture(_ progress: @Sendable (ScrollCaptureProgress) -> Void) async throws -> (image: ScrollImageBuffer, stop: ScrollCaptureResult.Stop, shifts: [Int]) {
        let started = clock.now
        scale = await surface.scale
        progress(.init(phase: .preparing))

        // Anything that keeps changing without scrolling (a video, an animation) is noise to be tolerated.
        // Wait out one-off changes such as a scroll bar fading, so they are not mistaken for it.
        var frame = try await surface.grab()
        var changes: [Int] = []
        var quiet = 0
        while quiet < 4, changes.count < 24 {
            try await Task.sleep(for: timing.poll * 2)
            let next = try await surface.grab()
            let cells = next.difference(from: frame).cells
            changes.append(cells)
            quiet = cells == 0 ? quiet + 1 : 0
            frame = next
        }
        if quiet < 4 {
            let median = changes.sorted()[changes.count / 2]
            noise = median + median / 2
        }
        startFrame = frame
        viewportPoints = Double(frame.height) / scale

        trace.append("frame \(frame.width)x\(frame.height) px, scale \(scale), noise \(noise) cells")
        // The capture starts with what is on screen now and only ever moves down from there.
        originalBar = await surface.scrollBarPosition()
        let top = frame
        trace.append("starting from the current view; scroll bar \(originalBar.map { String(format: "%.4f", $0) } ?? "none")")
        let composer = ScrollComposer(first: top)
        var previous = top
        var shifts: [Int] = []
        var header = 0
        var viewport: ScrollViewport?
        var fraction = 0.25      // share of the scrolling area to advance per step; cautious until calibrated
        var requested = 0.0      // points asked for since `previous`
        var unseen = 0.0         // points asked for while the view was blank and so showed no movement
        var blankRun = 0         // consecutive steps spent in a blank stretch
        var fixedDetail: [Bool]? // cells seen holding the same detail at different scroll positions
        var trailingBlank = false
        var solid = composer.checkpoint()   // the last section that actually showed something
        var recheck: ScrollFrame?
        var steppedBack = false
        var stalls = 0, failures = 0, ambiguous = 0
        var stop = ScrollCaptureResult.Stop.reachedEnd

        capturing: while true {
            try Task.checkCancellation()
            // Stop while the next section would still fit under the height limit.
            let height = composer.height, pixelCount = composer.pixelCount
            if height + previous.height * 3 / 4 > limits.maxHeight || pixelCount >= limits.maxPixels || shifts.count >= limits.maxFrames {
                stop = .sizeLimit
                break
            }
            if clock.now - started >= limits.maxDuration { stop = .timeLimit; break }

            let current: ScrollFrame
            if let frame = recheck {
                current = frame
                recheck = nil
            } else {
                // Each section's lower part is redrawn by the section after it. Once the scroll thumb has
                // travelled down into that part there is no need to wait for it to fade any more.
                if case .overlay(let fade) = scrollers, let thumbTop, fraction >= 0.5,
                   thumbTop >= header + (previous.height - header) / 2 + 24 {
                    scrollers = .overlayCovered(fade: fade)
                    trace.append("scroll thumb at row \(thumbTop): no longer waiting for it to fade")
                }
                var share = fraction
                // While waiting for the fade on every step, fewer and larger steps are quicker.
                if case .overlay = scrollers, fraction >= 0.5 { share = 0.75 }
                // A negative `requested` means the view is above the last good frame; make that up first.
                let step = max(8, Double(previous.height - header) * share / scale / ratio) + max(0, -requested)
                requested += step
                pending = requested * scale * ratio
                await surface.scroll(points: step)
                current = try await settle(from: previous)
            }
            let expected = Int(requested * scale * ratio)
            let detail = ScrollStitching.motionDetail(from: previous, to: current, expected: expected, viewport: viewport, noise: noise)
            // A blank stretch gives nothing to line up, so a section entering or leaving one is placed by
            // the distance asked for. The only thing that can be off is the height of the blank gap.
            let blankBefore = ScrollStitching.isFeatureless(previous, fixedDetail: fixedDetail, viewport: viewport)
            let blankNow = ScrollStitching.isFeatureless(current, fixedDetail: fixedDetail, viewport: viewport)
            if detail.motion == .failed, blankBefore || blankNow, requested + unseen > 0 {
                let shift = max(1, Int((requested + unseen) * scale * ratio))
                composer.append(current, analysis: ScrollStitching.unmeasured(shift: shift, width: current.width, viewport: viewport, bands: current.bands))
                trace.append("step \(shifts.count + 1): \(blankNow ? "in" : "left") a blank stretch, placed \(shift) px on by distance")
                shifts.append(shift)
                travelled += shift
                pending = 0
                previous = current
                requested = 0
                unseen = 0
                stalls = 0
                failures = 0
                steppedBack = false
                if blankNow {
                    blankRun += 1
                    trailingBlank = true
                    // Several window-heights of nothing: treat it as the end.
                    if blankRun >= 8 { break capturing }
                } else {
                    blankRun = 0
                    trailingBlank = false
                    solid = composer.checkpoint()
                }
                progress(.init(phase: .capturing, pixelHeight: composer.height, fraction: await surface.scrollBarPosition()))
                continue
            }
            switch detail.motion {
            case .unchanged:
                trace.append("no movement after asking \(Int(requested * scale)) px")
                if blankNow {
                    unseen += max(0, requested)
                    blankRun += 1
                }
                requested = 0
                pending = 0
                if steppedBack {
                    steppedBack = false
                } else {
                    stalls += 1
                    // Two scrolls in a row with no movement: this is the end. A blank view looks the same
                    // whether or not it is moving, so there keep trying for a few more window-heights.
                    if blankNow ? blankRun >= 8 : stalls >= 2 { break capturing }
                }
            case .moved(let shift):
                let analysis = ScrollStitching.analyze(from: previous, to: current, shift: shift)
                composer.append(current, analysis: analysis)
                fixedDetail = ScrollStitching.fixedDetail(previous, current, known: fixedDetail)
                // A short final step means the end was reached, not that the app scrolls slowly.
                if shifts.isEmpty || shift * 4 >= expected * 3 { calibrate(moved: shift, requestedPixels: requested * scale) }
                trace.append("step \(shifts.count + 1): asked \(Int(requested * scale)) px, moved \(shift), header \(analysis.header), footer \(analysis.footer)\(detail.ambiguous ? ", ambiguous" : "")")
                if detail.ambiguous { ambiguous += 1 }
                shifts.append(shift)
                travelled += shift
                pending = 0
                header = analysis.header
                viewport = ScrollViewport(top: analysis.header, movingBands: analysis.movingBands)
                fraction = 0.5
                previous = current
                // Recovering by stepping back is not progress; only a real advance clears the failure count.
                if requested > 0 { failures = 0 }
                requested = 0
                unseen = 0
                stalls = 0
                blankRun = 0
                trailingBlank = false
                solid = composer.checkpoint()
                steppedBack = false
                let position = await surface.scrollBarPosition()
                progress(.init(phase: .capturing, pixelHeight: composer.height, fraction: position))
            case .failed:
                failures += 1
                trace.append("could not align after asking \(Int(requested * scale)) px (attempt \(failures))")
                if failures == 1 {
                    // The content may still be loading or animating; look again without scrolling.
                    try await Task.sleep(for: timing.retryDelay)
                    recheck = try await settle(from: current)
                } else if failures == 2 {
                    // Step back to the last good frame and advance more carefully from there.
                    await surface.scroll(points: -requested)
                    requested = 0
                    pending = 0
                    fraction = 0.2
                    let back = try await settle(from: current)
                    if case .moved(let above) = ScrollStitching.motion(from: back, to: previous, expected: 0, viewport: viewport, noise: noise) {
                        requested = -Double(above) / scale / ratio
                        pending = -Double(above)
                    } else {
                        steppedBack = true
                        recheck = back
                    }
                } else {
                    throw ScrollCaptureError.alignment(partial: shifts.isEmpty ? nil : composer.finish())
                }
            }
        }
        guard !shifts.isEmpty else { throw ScrollCaptureError.didNotScroll(visible: top) }
        if trailingBlank {
            // Blank sections added by distance alone at the very end cannot be told from standing still.
            composer.rollback(to: solid)
            trace.append("dropped unverifiable blank sections at the end")
        } else if case .overlayCovered(let fade) = scrollers {
            // The final section is not covered by anything, so take it again once the thumb has gone.
            try await Task.sleep(for: fade + timing.scrollerMargin)
            let clean = try await settle(from: previous)
            if ScrollStitching.motion(from: previous, to: clean, expected: 0, viewport: viewport, noise: noise) == .unchanged {
                composer.replaceLast(clean)
            }
        }
        if ambiguous > 0 {
            trace.append("\(ambiguous) of \(shifts.count) steps could not be confirmed from the picture")
            throw ScrollCaptureError.repetitive(image: composer.finish())
        }
        return (composer.finish(), stop, shifts)
    }

    // MARK: Settling

    /// Waits for the view to stop changing after a scroll and returns the settled frame.
    private func settle(from reference: ScrollFrame, interruptible: Bool = true) async throws -> ScrollFrame {
        let start = clock.now
        var last = try await surface.grab()
        var lastChange = start
        var responded = last.difference(from: reference).cells > noise
        while true {
            try await wait(timing.poll, interruptible)
            let frame = try await surface.grab()
            let now = clock.now
            if frame.difference(from: last).cells > noise {
                last = frame
                lastChange = now
                responded = true
            } else if now - lastChange >= timing.stable, responded || now - start >= timing.noResponse {
                break
            }
            if now - start >= timing.maxSettle { break }
        }
        guard responded else { return last }

        // Overlay scroll bars appear while scrolling and fade out a moment later. Captured mid-fade
        // they would leave a thumb in every section, so wait until they are gone.
        let deadline: ContinuousClock.Instant
        switch scrollers {
        case .absent, .overlayCovered: return last
        case .unknown: deadline = start + timing.scrollerWatch
        case .overlay(let fade): deadline = start + fade + timing.scrollerMargin
        }
        var faded: ContinuousClock.Instant?
        while clock.now < deadline {
            try await wait(timing.poll, interruptible)
            let frame = try await surface.grab()
            let change = frame.difference(from: last)
            if change.cells > noise {
                // A scroll bar is a narrow strip; anything wider is content still arriving.
                if let bands = change.bandRange, bands.count <= 2 {
                    if faded == nil { thumbTop = change.rowRange?.lowerBound }
                    faded = clock.now
                }
                last = frame
                lastChange = clock.now
            } else if faded != nil, clock.now - lastChange >= timing.stable {
                break
            }
        }
        if case .unknown = scrollers {
            scrollers = faded.map { .overlay(fade: $0 - start) } ?? .absent
        }
        return last
    }

    private func wait(_ duration: Duration, _ interruptible: Bool) async throws {
        if interruptible {
            try await Task.sleep(for: duration)
        } else {
            // Restoring the scroll position must finish even after the capture was cancelled.
            let components = duration.components
            let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
            }
        }
    }

    // MARK: Restoring

    private func restore() async -> Bool {
        guard await reposition() else { return false }
        // Check against what the view showed before anything was touched, and close any small gap.
        guard let startFrame, var frame = try? await settle(from: startFrame, interruptible: false) else { return false }
        for _ in 0..<3 {
            let below = ScrollStitching.motion(from: startFrame, to: frame, expected: 0, noise: noise)
            if below == .unchanged { return true }
            if case .moved(let shift) = below {
                await surface.scroll(points: -Double(shift) / scale / ratio)
            } else if case .moved(let shift) = ScrollStitching.motion(from: frame, to: startFrame, expected: 0, noise: noise) {
                await surface.scroll(points: Double(shift) / scale / ratio)
            } else {
                // The content itself changed since the start, so the position cannot be confirmed.
                trace.append("restore: could not compare with the starting view")
                return false
            }
            trace.append("restore: adjusting, \(below)")
            guard let next = try? await settle(from: frame, interruptible: false) else { return false }
            frame = next
        }
        return ScrollStitching.motion(from: startFrame, to: frame, expected: 0, noise: noise) == .unchanged
    }

    /// Moves the view back to (about) where it started; `restore` then checks it against the starting view.
    private func reposition() async -> Bool {
        guard viewportPoints > 0, var frame = try? await surface.grab() else { return false }
        if let originalBar, await surface.setScrollBarPosition(originalBar) {
            guard let next = try? await settle(from: frame, interruptible: false) else { return false }
            if travelled == 0 || next.difference(from: frame).cells > noise { return true }
            frame = next
        }
        // Jump back up by the distance measured on the way down.
        var remaining = (Double(travelled) + pending) / scale / ratio
        while remaining > 0.5 {
            let step = min(remaining, 20_000)
            await surface.scroll(points: -step)
            guard let next = try? await settle(from: frame, interruptible: false) else { return false }
            frame = next
            remaining -= step
        }
        trace.append("restore: went back up \(travelled) px")
        return true
    }
}
