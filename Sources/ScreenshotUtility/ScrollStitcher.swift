import Foundation

// Pure stitching logic for scrolling capture. Nothing here touches the screen, so it is
// unit-tested with synthetic frames.
//
// Frames are compared exactly: a window that scrolls by whole device pixels re-presents the
// same rendered pixels, so equal hashes mean equal content and a seam can be placed anywhere
// in the overlap without blending (which would soften the image).

/// One capture of the scrolling region. Pixels are premultiplied BGRA packed as 0xAARRGGBB.
struct ScrollFrame: Sendable {
    let width: Int
    let height: Int
    let pixels: [UInt32]
    /// Each row is split into `bands` vertical strips so that a fixed sidebar, a scroll thumb or a
    /// small animation only disturbs the strips it touches.
    let bands: Int
    /// `height * bands` hashes, one per (row, band).
    let hashes: [UInt64]
    /// For each (row, band): a signature of the change from the row above, or 0 where the strip is the
    /// same as the row above. Flat areas look alike at any offset; only these transitions pin down a shift.
    let edges: [UInt64]

    init(width: Int, height: Int, pixels: [UInt32]) {
        precondition(width > 0 && height > 0 && pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
        let bands = max(1, min(64, width / 32))
        self.bands = bands
        var hashes = [UInt64](repeating: 0, count: height * bands)
        pixels.withUnsafeBufferPointer { source in
            hashes.withUnsafeMutableBufferPointer { out in
                for y in 0..<height {
                    let row = y * width
                    for band in 0..<bands {
                        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
                        var x = row + band * width / bands
                        let end = row + (band + 1) * width / bands
                        while x < end {
                            hash = (hash ^ UInt64(source[x])) &* 0x0000_0100_0000_01b3
                            x += 1
                        }
                        out[y * bands + band] = hash
                    }
                }
            }
        }
        var edges = [UInt64](repeating: 0, count: height * bands)
        for index in bands..<(height * bands) where hashes[index] != hashes[index - bands] {
            edges[index] = (hashes[index - bands] &* 0x9E37_79B9_7F4A_7C15) ^ hashes[index] | 1
        }
        self.hashes = hashes
        self.edges = edges
    }

    /// Number of (row, band) cells that differ, and the span of bands and rows they fall in.
    func difference(from other: ScrollFrame) -> (cells: Int, bandRange: ClosedRange<Int>?, rowRange: ClosedRange<Int>?) {
        guard other.width == width, other.height == height else { return (height * bands, 0...(bands - 1), 0...(height - 1)) }
        var count = 0, low = Int.max, high = -1, first = -1, last = -1
        hashes.withUnsafeBufferPointer { a in
            other.hashes.withUnsafeBufferPointer { b in
                for index in 0..<a.count where a[index] != b[index] {
                    count += 1
                    let band = index % bands
                    low = min(low, band)
                    high = max(high, band)
                    if first < 0 { first = index / bands }
                    last = index / bands
                }
            }
        }
        return (count, high >= 0 ? low...high : nil, first >= 0 ? first...last : nil)
    }
}

enum ScrollMotion: Sendable, Equatable {
    /// Nothing moved (the end of the content, or the scroll was ignored).
    case unchanged
    /// Content moved up by this many pixels: `to[y] == from[y + shift]`.
    case moved(Int)
    /// The frames differ but cannot be aligned.
    case failed
}

struct ScrollMotionDetail: Sendable, Equatable {
    let motion: ScrollMotion
    /// Several clearly different shifts fit equally well (identical rows, a blank grid), so the result
    /// rests on the expected distance rather than on the picture.
    var ambiguous = false
}

/// What the previous pairs established about where scrolling happens inside the region.
struct ScrollViewport: Sendable, Equatable {
    var top: Int
    var movingBands: [Bool]
}

struct ScrollPairAnalysis: Sendable {
    let shift: Int
    /// Rows at the top of the newer frame that did not scroll with the content (sticky header, toolbar).
    let header: Int
    /// Rows at the bottom of the newer frame that stayed put while the content moved. Flat content can
    /// inflate this for one pair, so only the smallest value over a capture is trusted.
    let footer: Int
    let movingBands: [Bool]
    /// Per pixel column, over `columnSamples` rows of the overlap: how often the newer frame disagreed
    /// with the older one in place, and how often it disagreed with the older one shifted.
    /// Columns that agree in place but not when shifted did not scroll (sidebars, scroll bar tracks).
    let columnStillMisses: [Int32]
    let columnMovedMisses: [Int32]
    let columnSamples: Int
}

enum ScrollStitching {
    /// Finds how far the content moved up between two frames of the same size.
    /// - Parameters:
    ///   - expected: the shift the scroll request should have produced; breaks ties on repeating content.
    ///   - noise: number of cells that differ between frames even when nothing is scrolled.
    static func motion(from a: ScrollFrame, to b: ScrollFrame, expected: Int, viewport: ScrollViewport? = nil, noise: Int = 0) -> ScrollMotion {
        motionDetail(from: a, to: b, expected: expected, viewport: viewport, noise: noise).motion
    }

    /// True when the scrolling part of a frame has nothing in it to line up against (a blank stretch).
    /// `fixedDetail` marks cells known not to scroll (a border, the window's rounded corners).
    static func isFeatureless(_ frame: ScrollFrame, fixedDetail: [Bool]?, viewport: ScrollViewport?) -> Bool {
        let bands = frame.bands
        let mask = viewport?.movingBands.count == bands ? viewport?.movingBands : nil
        let fixed = fixedDetail?.count == frame.edges.count ? fixedDetail : nil
        var edges = 0
        // The row where a fixed header meets the content is a transition too, but not one that scrolls.
        for y in firstScrollingRow(viewport, height: frame.height)..<frame.height {
            for band in 0..<bands where mask?[band] ?? true {
                let index = y * bands + band
                guard frame.edges[index] != 0, fixed?[index] != true else { continue }
                edges += 1
                if edges >= 12 { return false }
            }
        }
        return true
    }

    /// Narrows down which cells hold detail that stays put, given two frames at different scroll positions.
    static func fixedDetail(_ a: ScrollFrame, _ b: ScrollFrame, known: [Bool]?) -> [Bool] {
        var result = [Bool](repeating: false, count: a.edges.count)
        guard a.edges.count == b.edges.count else { return result }
        for index in 0..<result.count where a.edges[index] != 0 && a.edges[index] == b.edges[index] {
            result[index] = known?[index] ?? true
        }
        return result
    }

    private static func firstScrollingRow(_ viewport: ScrollViewport?, height: Int) -> Int {
        guard let top = viewport?.top, top > 0 else { return 1 }
        return min(top + 1, height - 1)
    }

    static func motionDetail(from a: ScrollFrame, to b: ScrollFrame, expected: Int, viewport: ScrollViewport? = nil, noise: Int = 0) -> ScrollMotionDetail {
        find(from: a, to: b, expected: expected, viewport: viewport, noise: noise)
    }

    private static func find(from a: ScrollFrame, to b: ScrollFrame, expected: Int, viewport: ScrollViewport?, noise: Int) -> ScrollMotionDetail {
        guard a.width == b.width, a.height == b.height else { return .init(motion: .failed) }
        let bands = a.bands, height = a.height
        let top = firstScrollingRow(viewport, height: height)
        let mask = viewport?.movingBands.count == bands ? viewport?.movingBands : nil

        var differing = 0, informative = 0, unmoved = 0
        var cells: [Int32] = []
        a.hashes.withUnsafeBufferPointer { ha in
            b.hashes.withUnsafeBufferPointer { hb in
                for y in top..<height {
                    for band in 0..<bands where mask?[band] ?? true {
                        let index = y * bands + band
                        if hb[index] != ha[index] { differing += 1 }
                        let edge = b.edges[index]
                        guard edge != 0 else { continue }
                        informative += 1
                        if edge == a.edges[index] { unmoved += 1 } else { cells.append(Int32(index)) }
                    }
                }
            }
        }
        if differing <= noise { return .init(motion: .unchanged) }

        let minimumOverlap = max(8, height / 20)
        let maxShift = height - minimumOverlap
        // Mostly still with a little activity (a video, a blinking caret) counts as no progress.
        let still = ScrollMotionDetail(motion: informative > 0 && unmoved * 10 >= informative * 9 ? .unchanged : .failed)
        guard maxShift >= 1, !cells.isEmpty else { return still }
        let sampling = max(1, cells.count / 8000)
        var scores = [Int32](repeating: 0, count: maxShift + 1)
        var rowsSampled = [Int32](repeating: 0, count: height)
        a.edges.withUnsafeBufferPointer { ea in
            b.edges.withUnsafeBufferPointer { eb in
                scores.withUnsafeMutableBufferPointer { scores in
                    var sample = 0
                    while sample < cells.count {
                        let index = Int(cells[sample])
                        let y = index / bands
                        rowsSampled[y] += 1
                        let value = eb[index]
                        let limit = min(maxShift, height - 1 - y)
                        var shift = 1, other = index + bands
                        while shift <= limit {
                            if ea[other] == value { scores[shift] += 1 }
                            shift += 1
                            other += bands
                        }
                        sample += sampling
                    }
                }
            }
        }
        // testable[d] = sampled cells that still have a counterpart after shifting by d.
        var cumulative = [Int32](repeating: 0, count: height + 1)
        for y in 0..<height { cumulative[y + 1] = cumulative[y] + rowsSampled[y] }
        // Rank shifts by the share of comparable cells that agree, not by the raw count: a small wrong
        // shift overlaps more rows, so on repetitive content it would otherwise out-count the true one.
        var candidates: [(shift: Int, score: Int, testable: Int, fit: Double)] = []
        for shift in 1...maxShift {
            let testable = Int(cumulative[height - shift]), score = Int(scores[shift])
            guard score >= 6, score * 10 >= testable * 3 else { continue }
            candidates.append((shift, score, testable, Double(score) / Double(testable)))
        }
        guard !candidates.isEmpty else { return still }
        // A few chance agreements at a sliver of overlap must not set the standard for a good fit.
        let substantial = max(12, Int(cumulative[height]) / 25)
        let bestFit = (candidates.filter { $0.testable >= substantial }.map(\.fit).max() ?? candidates.map(\.fit).max()) ?? 0
        var leaders = candidates.filter { $0.fit >= bestFit - 0.02 }
        // ...nor may they compete with a fit that rests on far more evidence.
        let support = leaders.map(\.score).max() ?? 0
        leaders = leaders.filter { $0.score * 2 >= support }
        guard let chosen = leaders.min(by: { abs($0.shift - expected) < abs($1.shift - expected) }) else { return still }
        return .init(motion: .moved(chosen.shift), ambiguous: leaders.contains { abs($0.shift - chosen.shift) > 2 })
    }

    /// Works out which parts of the newer frame actually scrolled, given the shift between the frames.
    static func analyze(from a: ScrollFrame, to b: ScrollFrame, shift: Int) -> ScrollPairAnalysis {
        let bands = a.bands, height = a.height, width = a.width
        let rows = height - shift
        var movingBands = [Bool](repeating: false, count: bands)
        var moved = [Bool](repeating: false, count: max(rows, 0))
        var still = [Bool](repeating: false, count: max(rows, 0))
        a.hashes.withUnsafeBufferPointer { ha in
            b.hashes.withUnsafeBufferPointer { hb in
                for band in 0..<bands {
                    var evidence = 0
                    for y in 0..<rows {
                        let value = hb[y * bands + band]
                        if value == ha[(y + shift) * bands + band] && value != ha[y * bands + band] { evidence += 1 }
                    }
                    movingBands[band] = evidence >= max(3, rows / 100)
                }
                let count = movingBands.filter { $0 }.count
                let allowed = count <= 2 ? 0 : max(1, count / 5)
                for y in 0..<rows {
                    var movedMisses = 0, stillMisses = 0
                    for band in 0..<bands where movingBands[band] {
                        let value = hb[y * bands + band]
                        if value != ha[(y + shift) * bands + band] { movedMisses += 1 }
                        if value != ha[y * bands + band] { stillMisses += 1 }
                    }
                    moved[y] = count > 0 && movedMisses <= allowed
                    still[y] = count > 0 && stillMisses <= allowed
                }
            }
        }

        var footer = 0
        let movingCount = movingBands.filter { $0 }.count
        if movingCount > 0 {
            a.hashes.withUnsafeBufferPointer { ha in
                b.hashes.withUnsafeBufferPointer { hb in
                    let allowed = movingCount <= 2 ? 0 : max(1, movingCount / 5)
                    var y = height - 1
                    while y >= 0 {
                        var misses = 0
                        for band in 0..<bands where movingBands[band] && hb[y * bands + band] != ha[y * bands + band] { misses += 1 }
                        if misses > allowed { break }
                        footer += 1
                        y -= 1
                    }
                }
            }
        }

        // The header ends where rows start following the scroll. Rows that satisfy both tests are
        // identical either way, so the boundary only has to clear the last row that did not move.
        var header = 0
        if let firstScrolling = (0..<max(rows - 1, 0)).first(where: { moved[$0] && !still[$0] && moved[$0 + 1] && !still[$0 + 1] }) {
            if let lastFixed = (0..<firstScrolling).last(where: { !moved[$0] }) { header = lastFixed + 1 }
        }

        // Per-column comparison below the header locates sidebars at pixel accuracy.
        var stillMisses = [Int32](repeating: 0, count: width)
        var movedMisses = [Int32](repeating: 0, count: width)
        var sampled = 0
        if rows - header >= 4 {
            let step = rows - header > 600 ? 2 : 1
            a.pixels.withUnsafeBufferPointer { pa in
                b.pixels.withUnsafeBufferPointer { pb in
                    stillMisses.withUnsafeMutableBufferPointer { stillMisses in
                        movedMisses.withUnsafeMutableBufferPointer { movedMisses in
                            var y = header
                            while y < rows {
                                // Only rows known to have scrolled say anything about a column; rows newly
                                // revealed above a sticky footer have no counterpart in the older frame.
                                if moved[y] {
                                    let row = y * width, shifted = (y + shift) * width
                                    for x in 0..<width {
                                        let value = pb[row + x]
                                        if value != pa[row + x] { stillMisses[x] += 1 }
                                        if value != pa[shifted + x] { movedMisses[x] += 1 }
                                    }
                                    sampled += 1
                                }
                                y += step
                            }
                        }
                    }
                }
            }
        }
        return ScrollPairAnalysis(shift: shift, header: header, footer: footer, movingBands: movingBands, columnStillMisses: stillMisses, columnMovedMisses: movedMisses, columnSamples: sampled)
    }

    /// Stands in for `analyze` when a pair has nothing to compare (one of the frames is blank where it scrolls).
    static func unmeasured(shift: Int, width: Int, viewport: ScrollViewport?, bands: Int) -> ScrollPairAnalysis {
        ScrollPairAnalysis(shift: shift, header: viewport?.top ?? 0, footer: 0, movingBands: viewport?.movingBands ?? [Bool](repeating: true, count: bands),
                           columnStillMisses: [Int32](repeating: 0, count: width), columnMovedMisses: [Int32](repeating: 0, count: width), columnSamples: 0)
    }

    /// Widths of the edge zones that never scrolled, from miss counts accumulated over every pair.
    static func fixedEdges(stillMisses: [Int], movedMisses: [Int], samples: Int) -> (left: Int, right: Int) {
        let width = stillMisses.count
        guard samples > 0, width > 0 else { return (0, 0) }
        func isFixed(_ x: Int) -> Bool {
            movedMisses[x] >= 3 && stillMisses[x] * 4 < movedMisses[x] * 3 && stillMisses[x] * 8 <= samples
        }
        func isMoving(_ x: Int) -> Bool {
            stillMisses[x] >= 3 && movedMisses[x] * 4 < stillMisses[x]
        }
        func extent(_ columns: some Sequence<Int>) -> Int {
            var run = 0, extent = 0, position = 0
            for x in columns {
                position += 1
                if isFixed(x) { extent = position; run = 0 }
                else if isMoving(x) { run += 1; if run >= 4 { break } }
            }
            return extent >= 8 ? extent : 0
        }
        let left = extent(0..<width), right = extent((0..<width).reversed())
        return left + right > width * 9 / 10 ? (0, 0) : (left, right)
    }
}

/// The finished pixels, row-major, premultiplied BGRA packed as 0xAARRGGBB.
final class ScrollImageBuffer: @unchecked Sendable {
    let width: Int
    let height: Int
    let baseAddress: UnsafeMutablePointer<UInt32>
    fileprivate init(width: Int, height: Int, baseAddress: UnsafeMutablePointer<UInt32>) {
        self.width = width
        self.height = height
        self.baseAddress = baseAddress
    }
    deinit { baseAddress.deallocate() }
    subscript(x: Int, y: Int) -> UInt32 { baseAddress[y * width + x] }
}

/// Builds the tall image. Each new frame overwrites the rows it shares with earlier frames, except
/// its sticky header rows, so a header appears once (from the first frame) and a sticky footer
/// survives only at the very end. Edge columns that never scrolled are reset to the first frame when finishing.
final class ScrollComposer {
    let width: Int
    let frameHeight: Int
    private(set) var height: Int
    private(set) var offset = 0
    private var storage: UnsafeMutablePointer<UInt32>?
    private var capacity: Int
    private var stillMisses: [Int]
    private var movedMisses: [Int]
    private var samples = 0
    private var footer = Int.max
    private var lastTop = 0
    private let first: ScrollFrame
    private var last: ScrollFrame

    init(first: ScrollFrame) {
        self.first = first
        last = first
        width = first.width
        frameHeight = first.height
        height = first.height
        capacity = first.height * 4
        stillMisses = [Int](repeating: 0, count: first.width)
        movedMisses = [Int](repeating: 0, count: first.width)
        let storage = UnsafeMutablePointer<UInt32>.allocate(capacity: capacity * width)
        first.pixels.withUnsafeBufferPointer { storage.initialize(from: $0.baseAddress!, count: $0.count) }
        self.storage = storage
    }

    deinit { storage?.deallocate() }

    var pixelCount: Int { height * width }

    func append(_ frame: ScrollFrame, analysis: ScrollPairAnalysis) {
        precondition(frame.width == width && frame.height == frameHeight && analysis.shift > 0)
        guard var storage else { return }
        let oldHeight = height
        offset += analysis.shift
        let newHeight = offset + frameHeight
        if newHeight > capacity {
            let newCapacity = max(newHeight, capacity * 3 / 2)
            let grown = UnsafeMutablePointer<UInt32>.allocate(capacity: newCapacity * width)
            grown.moveInitialize(from: storage, count: height * width)
            storage.deallocate()
            storage = grown
            self.storage = grown
            capacity = newCapacity
        }
        height = newHeight
        for x in 0..<width {
            stillMisses[x] += Int(analysis.columnStillMisses[x])
            movedMisses[x] += Int(analysis.columnMovedMisses[x])
        }
        samples += analysis.columnSamples
        if analysis.columnSamples > 0 { footer = min(footer, analysis.footer) }
        last = frame
        let top = analysis.header
        if offset + top > oldHeight {
            // Only after a blank stretch that was crossed without anything to measure: continue the
            // blank down to where this frame starts.
            for row in oldHeight..<(offset + top) {
                (storage + row * width).update(from: storage + (oldHeight - 1) * width, count: width)
            }
        }
        lastTop = top
        frame.pixels.withUnsafeBufferPointer { source in
            (storage + (offset + top) * width).update(from: source.baseAddress! + top * width, count: (frameHeight - top) * width)
        }
    }

    struct Checkpoint {
        fileprivate let offset: Int, height: Int, lastTop: Int, last: ScrollFrame
    }

    func checkpoint() -> Checkpoint {
        Checkpoint(offset: offset, height: height, lastTop: lastTop, last: last)
    }

    /// Drops every section appended after the checkpoint.
    func rollback(to checkpoint: Checkpoint) {
        offset = checkpoint.offset
        height = checkpoint.height
        lastTop = checkpoint.lastTop
        last = checkpoint.last
    }

    /// Redraws the most recent section from a cleaner capture of the same scroll position.
    func replaceLast(_ frame: ScrollFrame) {
        precondition(frame.width == width && frame.height == frameHeight)
        guard let storage, offset > 0 else { return }
        last = frame
        frame.pixels.withUnsafeBufferPointer { source in
            (storage + (offset + lastTop) * width).update(from: source.baseAddress! + lastTop * width, count: (frameHeight - lastTop) * width)
        }
    }

    /// Hands over the finished image. The composer cannot be used afterwards.
    func finish() -> ScrollImageBuffer {
        guard let storage else { preconditionFailure("finish() called twice") }
        self.storage = nil
        let edges = ScrollStitching.fixedEdges(stillMisses: stillMisses, movedMisses: movedMisses, samples: samples)
        if height > frameHeight {
            // A fixed edge column (sidebar, scroll bar track) is shown once, as it was in the first frame.
            // Below that its dominant color continues, so the sidebar's background and borders run on down
            // the image, and a sticky footer that spans it is taken from the final frame.
            let footer = min(footer, frameHeight / 2)
            let body = frameHeight - footer
            for x in Array(0..<edges.left) + Array((width - edges.right)..<width) {
                var counts: [UInt32: Int] = [:]
                first.pixels.withUnsafeBufferPointer { source in
                    for y in 0..<body {
                        let pixel = source[y * width + x]
                        if pixel >> 24 == 0xFF { counts[pixel, default: 0] += 1 }
                        storage[y * width + x] = pixel
                    }
                }
                let fill = counts.max { $0.value < $1.value }?.key ?? 0xFFFF_FFFF
                for y in (frameHeight / 2)..<body {
                    // The window's rounded bottom corner in the first frame: flatten it onto the fill.
                    let pixel = storage[y * width + x], alpha = pixel >> 24
                    guard alpha < 0xFF else { continue }
                    var blended: UInt32 = 0xFF00_0000
                    for channel: UInt32 in [0, 8, 16] {
                        let over = (pixel >> channel) & 0xFF, under = (fill >> channel) & 0xFF
                        blended |= min(255, over + (under * (255 - alpha) + 127) / 255) << channel
                    }
                    storage[y * width + x] = blended
                }
                for y in body..<(height - footer) { storage[y * width + x] = fill }
                last.pixels.withUnsafeBufferPointer { source in
                    for y in body..<frameHeight { storage[(height - frameHeight + y) * width + x] = source[y * width + x] }
                }
            }
        }
        return ScrollImageBuffer(width: width, height: height, baseAddress: storage)
    }
}
