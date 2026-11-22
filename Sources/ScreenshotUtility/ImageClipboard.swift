import AppKit
import ImageIO

@MainActor
enum ImageClipboard {
    /// Scrolling captures can be hundreds of megapixels. Above this size the TIFF copy (which most
    /// apps never ask for, since the PNG is on the clipboard too) is only produced if an app requests it,
    /// instead of holding gigabytes of uncompressed pixels on the pasteboard.
    static let lazyTIFFPixelThreshold = 24_000_000
    private static var provider: LazyTIFFProvider?

    static func copy(_ url: URL, to pasteboard: NSPasteboard = .general, lazyTIFFAbove threshold: Int = lazyTIFFPixelThreshold) throws {
        let data = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType("public.png"))
        var lazy: LazyTIFFProvider?
        if cgImage.width * cgImage.height > threshold {
            let provider = LazyTIFFProvider(image: cgImage)
            item.setDataProvider(provider, forTypes: [.tiff])
            lazy = provider
        } else {
            let image = NSImage(cgImage: cgImage, size: .zero)
            if let tiff = image.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw CocoaError(.fileWriteUnknown) }
        provider = lazy
    }
}

private final class LazyTIFFProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let image: CGImage

    init(image: CGImage) {
        self.image = image
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff else { return }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.tiff" as CFString, 1, nil) else { return }
        // LZW (5) is lossless and keeps a very tall capture to a sensible size.
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]] as CFDictionary)
        if CGImageDestinationFinalize(destination) { item.setData(data as Data, forType: .tiff) }
    }
}
