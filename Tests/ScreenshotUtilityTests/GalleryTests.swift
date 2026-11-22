import Testing
import Foundation
import AppKit
@testable import ScreenshotUtility

struct GalleryTests {
    private func withFolder(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }

    @Test func cutoffSortingPersistenceAndNoCountLimit() throws {
        try withFolder { folder in
            let now = Date()
            for i in 0..<14 {
                let url = folder.appendingPathComponent("capture-\(i).png")
                try Data([1]).write(to: url)
                #expect(RecentCaptures.recordCapture(at: url, date: now.addingTimeInterval(-Double(i) * 60)))
            }
            let old = folder.appendingPathComponent("old.png")
            try Data([1]).write(to: old)
            #expect(RecentCaptures.recordCapture(at: old, date: now.addingTimeInterval(-RecentCaptures.lifetime)))
            let future = folder.appendingPathComponent("future.png")
            try Data([1]).write(to: future)
            RecentCaptures.recordCapture(at: future, date: now.addingTimeInterval(60))
            let result = RecentCaptures.scan(folder: folder, now: now)
            #expect(result.captures.count == 14)
            #expect(result.captures.first?.url.lastPathComponent == "capture-0.png")
            #expect(result.captures.last?.url.lastPathComponent == "capture-13.png")
            #expect(RecentCaptures.scan(folder: folder, now: now).captures == result.captures)
            #expect(RecentCaptures.scan(folder: folder, now: now.addingTimeInterval(RecentCaptures.lifetime + 61)).captures.isEmpty)
            #expect(FileManager.default.fileExists(atPath: old.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 16)
        }
    }

    @Test func legacyCapturesUseBirthDateWithoutStrictFilenameAgreement() throws {
        try withFolder { folder in
            let legacy = folder.appendingPathComponent("Screenshot-2020-01-01-01.00.00.png")
            try Data([1]).write(to: legacy)
            try Data([1]).write(to: folder.appendingPathComponent("unrelated.png"))
            let result = RecentCaptures.scan(folder: folder)
            #expect(result.captures.map { $0.url.lastPathComponent } == [legacy.lastPathComponent])
            #expect(abs(result.captures[0].capturedAt.timeIntervalSinceNow) < 10)
        }
    }

    @Test func folderChangesDeletionRenamingAndMissingFolder() throws {
        try withFolder { folder in
            let one = folder.appendingPathComponent("one", isDirectory: true)
            let two = folder.appendingPathComponent("two", isDirectory: true)
            try FileManager.default.createDirectory(at: one, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: two, withIntermediateDirectories: true)
            let original = one.appendingPathComponent("Screenshot-2026-11-21-10.00.00.png")
            try Data([1]).write(to: original)
            RecentCaptures.recordCapture(at: original)
            let renamed = one.appendingPathComponent("renamed.png")
            try FileManager.default.moveItem(at: original, to: renamed)
            #expect(RecentCaptures.scan(folder: one).captures.map { $0.url.lastPathComponent } == [renamed.lastPathComponent])
            #expect(RecentCaptures.scan(folder: two).captures.isEmpty)
            try FileManager.default.removeItem(at: renamed)
            #expect(RecentCaptures.scan(folder: one).captures.isEmpty)
            let missing = folder.appendingPathComponent("missing")
            #expect(RecentCaptures.scan(folder: missing).captures.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: missing.path))
        }
    }

    @Test @MainActor func clipboardContainsOriginalImageAndRejectsCorruption() throws {
        try withFolder { folder in
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 300, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let png = bitmap.representation(using: .png, properties: [:])!
            let file = folder.appendingPathComponent("image.png")
            try png.write(to: file)
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            try ImageClipboard.copy(file, to: board)
            #expect(board.data(forType: .init("public.png")) == png)
            let tiff = try #require(board.data(forType: .tiff))
            let pasted = try #require(NSBitmapImageRep(data: tiff))
            #expect(pasted.pixelsWide == 1200)
            #expect(pasted.pixelsHigh == 300)
            #expect(board.data(forType: .fileURL) == nil)
            let corrupt = folder.appendingPathComponent("corrupt.png")
            try Data("not an image".utf8).write(to: corrupt)
            #expect(throws: (any Error).self) { try ImageClipboard.copy(corrupt, to: board) }
            #expect(board.data(forType: .init("public.png")) == png)
        }
    }
    @Test @MainActor func largeImagesProvideTheirTIFFCopyOnDemand() throws {
        try withFolder { folder in
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 4000, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let png = bitmap.representation(using: .png, properties: [:])!
            let file = folder.appendingPathComponent("long.png")
            try png.write(to: file)
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            try ImageClipboard.copy(file, to: board, lazyTIFFAbove: 1_000_000)
            #expect(board.data(forType: .init("public.png")) == png)
            let tiff = try #require(board.data(forType: .tiff))
            let pasted = try #require(NSBitmapImageRep(data: tiff))
            #expect(pasted.pixelsWide == 640)
            #expect(pasted.pixelsHigh == 4000)
        }
    }

    @Test func longCapturesPreviewTheirTopInsteadOfASliver() throws {
        try withFolder { folder in
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 12_000, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let long = folder.appendingPathComponent("long.png")
            try bitmap.representation(using: .png, properties: [:])!.write(to: long)
            let preview = try #require(CGImageSourceCreateWithURL(long as CFURL, nil).flatMap { GalleryView.thumbnail(from: $0) })
            #expect(preview.width == 352)
            #expect(GalleryView.isLongPreview(preview))
            let normal = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 300, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let wide = folder.appendingPathComponent("wide.png")
            try normal.representation(using: .png, properties: [:])!.write(to: wide)
            let fitted = try #require(CGImageSourceCreateWithURL(wide as CFURL, nil).flatMap { GalleryView.thumbnail(from: $0) })
            #expect(fitted.width == 352 && fitted.height == 88)
            #expect(!GalleryView.isLongPreview(fitted))
        }
    }

    @Test @MainActor func galleryScrollsImmediatelyAndClampsToContent() throws {
        let gallery = GalleryView()
        let now = Date()
        let captures = (0..<16).map { index in
            RecentCapture(url: URL(fileURLWithPath: "/nonexistent/test-\(index).png"), capturedAt: now, modifiedAt: now, size: 0)
        }
        gallery.update(captures, error: nil)
        gallery.prepareHeight(screenHeight: 800)
        let scroll = try #require(gallery.subviews.compactMap { $0 as? NSScrollView }.first)
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -150, wheel2: 0, wheel3: 0).flatMap(NSEvent.init(cgEvent:)))
        scroll.scrollWheel(with: event)
        #expect(scroll.contentView.bounds.minY > 0)
        for _ in 0..<100 { scroll.scrollWheel(with: event) }
        #expect(scroll.contentView.bounds.maxY <= (scroll.documentView?.bounds.height ?? 0) + 1)
        #expect(gallery.frame.height == 330)
        gallery.prepareHeight(screenHeight: 500)
        #expect(gallery.frame.height == 240)
        gallery.update(Array(captures.prefix(1)), error: nil)
        gallery.prepareHeight(screenHeight: 800)
        #expect(scroll.documentView?.frame.height == gallery.frame.height)
    }

}
