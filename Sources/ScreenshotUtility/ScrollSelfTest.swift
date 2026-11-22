#if DEBUG
import AppKit
import WebKit

/// Developer self-test: `--scroll-selftest <url-or-html-file>` opens a web view in this app's own
/// window and runs a real scrolling capture of it through the app's normal save, clipboard and gallery
/// steps. It scrolls with JavaScript instead of wheel events, so it needs Screen Recording but not
/// Accessibility, and the page itself reports how tall the result should be.
///
/// `--scroll-selftest native:text` and `native:table` do the same with AppKit scroll views (a long
/// text view, and a table whose column header stays pinned), scrolled programmatically.
///
/// Options: `--scroll-selftest-report <json>`, `--scroll-selftest-start <css px>` (initial scroll
/// offset), `--scroll-selftest-size <w,h>`. Use `-saveDirectoryPath <folder>` to keep test images
/// out of the real screenshot folder.
@MainActor
final class ScrollSelfTest: NSObject, WKNavigationDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var scrollView: NSScrollView?
    private var started = false
    /// Runs the capture through the app and reports what happened. Set by the app delegate.
    var capture: ((ScrollTarget, @escaping @Sendable (Double) async -> Void, @escaping ([String: Any]) -> Void) -> Void)?
    private let arguments = CommandLine.arguments

    private func value(_ name: String) -> String? {
        arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }

    func run() {
        guard let location = value("--scroll-selftest") else { return NSApp.terminate(nil) }
        let size = value("--scroll-selftest-size")?.split(separator: ",").compactMap { Double($0) } ?? []
        let content = NSRect(x: 0, y: 0, width: size.count == 2 ? size[0] : 900, height: size.count == 2 ? size[1] : 700)
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: content, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ScreenshotUtility — Scrolling Capture Self-Test"
        if let screen = NSScreen.main {
            window.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.maxY - 20))
        }
        self.window = window
        if location.hasPrefix("native:") {
            let scrollView = location == "native:table" ? Self.makeTable(frame: content, dataSource: self) : Self.makeText(frame: content)
            window.contentView = scrollView
            window.orderFrontRegardless()
            self.scrollView = scrollView
            Task { await self.capture() }
            return
        }
        let webView = WKWebView(frame: content)
        webView.navigationDelegate = self
        window.contentView = webView
        window.orderFrontRegardless()
        self.webView = webView
        if location.contains("://"), let url = URL(string: location) {
            webView.load(URLRequest(url: url))
        } else {
            let file = URL(fileURLWithPath: location)
            webView.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !started else { return }
        started = true
        Task { await self.capture() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(["status": "failed", "message": error.localizedDescription])
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(["status": "failed", "message": error.localizedDescription])
    }

    private func number(_ script: String) async -> Double {
        guard let webView else { return 0 }
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, _ in continuation.resume(returning: (result as? NSNumber)?.doubleValue ?? 0) }
        }
    }

    private static func makeText(frame: NSRect) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.frame = frame
        let text = NSMutableAttributedString()
        var seed: UInt64 = 42
        let words = ["window", "scroll", "capture", "pixel", "margin", "header", "stitch", "overlap", "section", "content", "display", "sharp", "exact", "frame", "offset", "settle"]
        for paragraph in 1...260 {
            let heading = paragraph % 9 == 1
            var line = heading ? "Chapter \(paragraph / 9 + 1)" : "\(paragraph). "
            if !heading {
                for _ in 0..<(20 + Int(seed % 60)) {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    line += words[Int(seed >> 33) % words.count] + " "
                }
            }
            text.append(NSAttributedString(string: line + "\n\n", attributes: [
                .font: heading ? NSFont.boldSystemFont(ofSize: 22) : NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor
            ]))
        }
        (scrollView.documentView as? NSTextView)?.textStorage?.setAttributedString(text)
        (scrollView.documentView as? NSTextView)?.textContainerInset = NSSize(width: 16, height: 12)
        return scrollView
    }

    private static func makeTable(frame: NSRect, dataSource: NSTableViewDataSource & NSTableViewDelegate) -> NSScrollView {
        let table = NSTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        for (identifier, title, width) in [("n", "Row", 90.0), ("name", "Name", 380.0), ("value", "Value", 200.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = dataSource
        table.delegate = dataSource
        let scrollView = NSScrollView(frame: frame)
        scrollView.hasVerticalScroller = true
        scrollView.documentView = table
        return scrollView
    }

    private func capture() async {
        if let scrollView { return await captureNative(scrollView) }
        guard let window, let webView else { return }
        try? await Task.sleep(for: .milliseconds(1500))
        if let start = value("--scroll-selftest-start").flatMap({ Double($0) }) {
            _ = await number("window.scrollTo({top: \(start), behavior: 'instant'}); 0")
            try? await Task.sleep(for: .milliseconds(600))
        }
        let before = await number("window.scrollY")
        let frame = ScrollTargetPicker.global(window.frame)
        let region = ScrollTargetPicker.global(window.convertToScreen(webView.convert(webView.bounds, to: nil)))
        let target = ScrollTarget(windowID: CGWindowID(window.windowNumber), pid: getpid(), appName: "Self-Test", windowFrame: frame,
                                  region: region, scrollPoint: CGPoint(x: region.midX, y: region.midY))
        let began = Date()
        struct Fields: @unchecked Sendable { let values: [String: Any] }
        let fields = await withCheckedContinuation { (continuation: CheckedContinuation<Fields, Never>) in
            guard let capture else { return continuation.resume(returning: Fields(values: ["status": "failed", "message": "No capture handler."])) }
            capture(target, { points in
                await withCheckedContinuation { (scrolled: CheckedContinuation<Void, Never>) in
                    Task { @MainActor in
                        webView.evaluateJavaScript("window.scrollBy({top: \(points), behavior: 'instant'}); 0") { _, _ in scrolled.resume() }
                    }
                }
            }) { continuation.resume(returning: Fields(values: $0)) }
        }
        var report = fields.values
        report["seconds"] = Date().timeIntervalSince(began)
        try? await Task.sleep(for: .milliseconds(500))
        report["scrollYBefore"] = before
        report["scrollYAfter"] = await number("window.scrollY")
        report["expectedPixelHeight"] = await number("(document.documentElement.scrollHeight - \(before)) * window.devicePixelRatio")
        finish(report)
    }

    private func scrollNative(by points: Double) {
        guard let scrollView else { return }
        let clip = scrollView.contentView
        let range = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height + clip.contentInsets.bottom)
        let y = min(range, max(-clip.contentInsets.top, clip.bounds.origin.y + points))
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    private func captureNative(_ scrollView: NSScrollView) async {
        guard let window, let capture else { return }
        try? await Task.sleep(for: .milliseconds(800))
        let clip = scrollView.contentView
        if let start = value("--scroll-selftest-start").flatMap({ Double($0) }) {
            scrollNative(by: start)
            try? await Task.sleep(for: .milliseconds(600))
        }
        let before = clip.bounds.origin.y
        let frame = ScrollTargetPicker.global(window.frame)
        let region = ScrollTargetPicker.global(window.convertToScreen(scrollView.convert(scrollView.bounds, to: nil)))
        let target = ScrollTarget(windowID: CGWindowID(window.windowNumber), pid: getpid(), appName: "Self-Test", windowFrame: frame,
                                  region: region, scrollPoint: CGPoint(x: region.midX, y: region.midY))
        struct Fields: @unchecked Sendable { let values: [String: Any] }
        let began = Date()
        let fields = await withCheckedContinuation { (continuation: CheckedContinuation<Fields, Never>) in
            capture(target, { points in await self.scrollNative(by: points) }) { continuation.resume(returning: Fields(values: $0)) }
        }
        var report = fields.values
        report["seconds"] = Date().timeIntervalSince(began)
        report["scrollYBefore"] = before
        report["scrollYAfter"] = clip.bounds.origin.y
        // Everything scrolled past, plus one full view of the scroll view (which includes any pinned header).
        let scale = window.backingScaleFactor
        let travel = (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height + clip.contentInsets.top + clip.contentInsets.bottom
        report["expectedPixelHeight"] = ((travel - (before + clip.contentInsets.top) + scrollView.frame.height) * scale).rounded()
        finish(report)
    }

    private func finish(_ fields: [String: Any]) {
        if let report = value("--scroll-selftest-report"), let data = try? JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: report))
        }
        NSApp.terminate(nil)
    }
}

extension ScrollSelfTest: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { 900 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "n": text = "\(row + 1)"
        // Many rows look alike, as in a real list, to exercise matching on repetitive content.
        case "name": text = row % 5 == 0 ? "Item \(row + 1) — \(String(UnicodeScalar(UInt8(65 + row % 26))))\(row * 7919 % 1000)" : "Item"
        default: text = row % 3 == 0 ? "\(row * 37 % 500)" : "—"
        }
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 13)
        return field
    }
}
#endif
