import Foundation
import Darwin

struct RecentCapture: Equatable, Sendable {
    let url: URL
    let capturedAt: Date
    let modifiedAt: Date
    let size: Int
}

struct CaptureScan: Sendable {
    var captures: [RecentCapture]
    var error: String?
}

enum RecentCaptures {
    static let lifetime: TimeInterval = 48 * 60 * 60
    static let timestampAttribute = "local.screenshotutility.capturedAt"

    // Extended attributes preserve an unambiguous capture instant across restarts and renames.
    // If the volume cannot store them, the original file's creation date remains a fallback.
    @discardableResult
    static func recordCapture(at url: URL, date: Date = Date()) -> Bool {
        var timestamp = date.timeIntervalSince1970
        return withUnsafeBytes(of: &timestamp) { bytes in
            setxattr(url.path, timestampAttribute, bytes.baseAddress, bytes.count, 0, 0) == 0
        }
    }

    static func recordedDate(at url: URL) -> Date? {
        var timestamp: Double = 0
        let count = withUnsafeMutableBytes(of: &timestamp) { bytes in
            getxattr(url.path, timestampAttribute, bytes.baseAddress, bytes.count, 0, 0)
        }
        guard count == MemoryLayout<Double>.size, timestamp.isFinite, timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    static func scan(folder: URL, now: Date = Date()) -> CaptureScan {
        do {
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey]
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
            let captures = files.compactMap { url -> RecentCapture? in
                guard url.pathExtension.lowercased() == "png",
                      let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
                let recorded = recordedDate(at: url)
                let legacyName = url.lastPathComponent.range(of: #"^Screenshot-\d{4}-\d{2}-\d{2}-\d{2}\.\d{2}\.\d{2}(?:-[A-Fa-f0-9-]+)?\.png$"#, options: .regularExpression) != nil
                guard recorded != nil || legacyName else { return nil }
                // Do not reject legacy captures merely because filename time and birth time
                // differ (selection delay, timezone changes and DST all cause differences).
                guard let date = recorded ?? values.creationDate ?? legacyDate(url) else { return nil }
                // Compare on the persisted epoch timebase. Date's reference-date
                // conversion can otherwise round exact now/48-hour boundaries differently.
                let age = now.timeIntervalSince1970 - date.timeIntervalSince1970
                guard age >= 0, age < lifetime else { return nil }
                return RecentCapture(url: url, capturedAt: date, modifiedAt: values.contentModificationDate ?? date, size: values.fileSize ?? 0)
            }.sorted { a, b in
                a.capturedAt == b.capturedAt ? a.url.lastPathComponent > b.url.lastPathComponent : a.capturedAt > b.capturedAt
            }
            return CaptureScan(captures: captures)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return CaptureScan(captures: [])
        } catch {
            return CaptureScan(captures: [], error: "Can’t read the save folder")
        }
    }

    private static func legacyDate(_ url: URL) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd-HH.mm.ss"
        return formatter.date(from: String(url.deletingPathExtension().lastPathComponent.dropFirst(11).prefix(19)))
    }
}
