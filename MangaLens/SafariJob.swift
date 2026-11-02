import Foundation
import OSLog
import UIKit

/// Files shared by the Safari web extension and the containing app.
///
/// iOS will not give the extension the SwiftUI `translationTask` that downloads
/// language packs, and it will not let a content script call native messaging.
/// The extension therefore only captures the visible page and parks one JPEG
/// plus a manifest. The app runs Vision and Translation, then writes the boxes
/// back for the content script to paint.
///
/// App Groups are the storage that does not touch the clipboard. A free
/// Personal Team cannot sign that capability, so the same bytes can ride on
/// the local pasteboard instead. See the README.
enum SafariBridge {
    static let appGroupID = "group.com.julyanxu.MangaLens"
    static let urlScheme = "mangalens"
    static let manifestPasteboardType = "com.julyanxu.mangalens.safari-manifest"
    static let imagePasteboardType = "public.jpeg"
    static let resultPasteboardType = "com.julyanxu.mangalens.safari-result"
    static let jobVersion = 1

    static func openURL(jobID: String) -> URL? {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = "safari"
        components.queryItems = [URLQueryItem(name: "job", value: jobID)]
        return components.url
    }

    static func isOpenURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == urlScheme else { return false }
        return url.host?.lowercased() == "safari"
    }

    /// `http` and `https` only, fragment removed. Returns nil for new-tab pages.
    static func canonicalPageURL(_ raw: String) -> String? {
        guard var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty
        else { return nil }
        components.scheme = scheme
        components.fragment = nil
        return components.string
    }
}

enum SafariChannel: String, Codable {
    case appGroup
    case pasteboard
}

struct SafariAnchor: Codable {
    var id: String
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    /// "image" or "text". The content script uses it only as a hint.
    var kind: String
}

struct SafariJobManifest: Codable {
    var version: Int
    var id: String
    var pageURL: String
    var title: String
    var language: String
    var cssWidth: Double
    var cssHeight: Double
    var anchors: [SafariAnchor]
    var channel: String
    var createdAt: TimeInterval
}

struct SafariResultLine: Codable {
    var text: String
    var source: String
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

struct SafariResult: Codable {
    var version: Int
    var jobID: String
    var pageURL: String
    var cssWidth: Double
    var cssHeight: Double
    var lines: [SafariResultLine]
    var anchors: [SafariAnchor]
    var message: String
    var createdAt: TimeInterval
}

struct LoadedSafariJob {
    var manifest: SafariJobManifest
    var jpeg: Data
}

struct SavedSafariJob {
    var url: URL
    var jobID: String
    var channel: SafariChannel
}

enum SafariStoreError: LocalizedError {
    case badImage
    case badPage
    case noChannel

    var errorDescription: String? {
        switch self {
        case .badImage:
            return "这一屏的画面无法读取。"
        case .badPage:
            return "这个页面不是 http 或 https，Safari 扩展不会翻译它。"
        case .noChannel:
            return "没有写进 App Group，剪贴板也写失败了。"
        }
    }
}

enum SafariJobStore {
    private static let logger = Logger(subsystem: "com.julyanxu.MangaLens", category: "safari")
    private static let folderName = "safari"
    private static let manifestName = "manifest.json"
    private static let screenshotName = "screenshot.jpg"
    private static let resultName = "result.json"
    /// Long enough to switch apps and accept a language pack. Local only.
    private static let pendingLifetime: TimeInterval = 15 * 60
    private static let resultLifetime: TimeInterval = 30 * 60

    static func save(
        pageURL: String,
        title: String,
        language: String,
        cssWidth: Double,
        cssHeight: Double,
        anchors: [SafariAnchor],
        jpeg: Data
    ) -> Result<SavedSafariJob, SafariStoreError> {
        guard let canonical = SafariBridge.canonicalPageURL(pageURL) else {
            return .failure(.badPage)
        }
        guard let image = UIImage(data: jpeg), image.size.width > 1, image.size.height > 1 else {
            return .failure(.badImage)
        }
        guard let normalized = SafariPageImage.jpeg(from: image, maxEdge: 1800) else {
            return .failure(.badImage)
        }

        let jobID = UUID().uuidString
        var channel: SafariChannel = containerRoot() == nil ? .pasteboard : .appGroup
        var manifest = makeManifest(
            id: jobID,
            pageURL: canonical,
            title: title,
            language: language,
            cssWidth: cssWidth,
            cssHeight: cssHeight,
            anchors: anchors,
            channel: channel
        )

        if channel == .appGroup {
            do {
                guard let manifestData = try? jsonEncoder().encode(manifest) else {
                    return .failure(.badImage)
                }
                try writeAppGroup(id: jobID, manifest: manifestData, jpeg: normalized)
                clearPasteboardManifestIfOurs()
            } catch {
                logger.error("app group write failed: \(error.localizedDescription, privacy: .public)")
                if let root = containerRoot() {
                    // Don't keep serving the previous page, and don't let an old
                    // result.json win over the pasteboard copy of this capture.
                    try? FileManager.default.removeItem(at: root.appendingPathComponent(currentName))
                    try? FileManager.default.removeItem(at: root.appendingPathComponent(resultName))
                }
                channel = .pasteboard
                manifest.channel = channel.rawValue
            }
        }

        if channel == .pasteboard {
            guard let manifestData = try? jsonEncoder().encode(manifest),
                  writePasteboard(manifest: manifestData, jpeg: normalized, lifetime: pendingLifetime)
            else { return .failure(.noChannel) }
        }

        logger.info("stored safari job channel=\(channel.rawValue, privacy: .public) bytes=\(normalized.count, privacy: .public)")
        guard let url = SafariBridge.openURL(jobID: jobID) else {
            return .failure(.noChannel)
        }
        return .success(SavedSafariJob(url: url, jobID: jobID, channel: channel))
    }

    /// The user started an in-app capture or navigated away before this job finished.
    static func abandon(jobID: String) {
        if let root = containerRoot(), currentJobID() == jobID {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(currentName))
            try? FileManager.default.removeItem(at: root.appendingPathComponent(jobID, isDirectory: true))
        }
        if let pending = readPasteboardPending(), pending.manifest.id == jobID {
            UIPasteboard.general.setItems([], options: [.localOnly: true])
        }
    }

    static func peekPending() -> LoadedSafariJob? {
        if let job = readAppGroupPending() {
            return job
        }
        return readPasteboardPending()
    }

    static func writeResult(_ result: SafariResult, channel: SafariChannel) {
        if let pending = readAppGroupPending(), pending.manifest.id != result.jobID {
            logger.info("skipped stale safari result")
            return
        }
        guard let data = try? jsonEncoder().encode(result) else { return }

        if let root = containerRoot() {
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try writeAtomic(data, to: root.appendingPathComponent(resultName))
                if currentJobID() == result.jobID {
                    try? FileManager.default.removeItem(at: root.appendingPathComponent(currentName))
                    try? FileManager.default.removeItem(
                        at: root.appendingPathComponent(result.jobID, isDirectory: true)
                    )
                }
            } catch {
                logger.error("result write failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        if channel == .pasteboard || containerRoot() == nil {
            // Replaces the pending image. Until this returns, the clipboard is the screenshot.
            writePasteboardResult(data)
        }
    }

    static func readResult() -> SafariResult? {
        if containerRoot() != nil {
            // The group is the source of truth whenever it is signed. Falling
            // through to the pasteboard here would replay a previous fallback.
            return readGroupResult()
        }
        return readPasteboardResult()
    }

    // MARK: - App Group

    /// `current` is written last and names a folder that already contains both
    /// the JPEG and the manifest. A failed save cannot pair a new picture with
    /// the previous page's boxes.
    private static let currentName = "current"

    private static func containerRoot() -> URL? {
        guard let base = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SafariBridge.appGroupID
        ) else { return nil }
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    private static func makeManifest(
        id: String,
        pageURL: String,
        title: String,
        language: String,
        cssWidth: Double,
        cssHeight: Double,
        anchors: [SafariAnchor],
        channel: SafariChannel
    ) -> SafariJobManifest {
        SafariJobManifest(
            version: SafariBridge.jobVersion,
            id: id,
            pageURL: pageURL,
            title: String(title.prefix(80)),
            language: language,
            cssWidth: cssWidth,
            cssHeight: cssHeight,
            anchors: Array(anchors.prefix(48)),
            channel: channel.rawValue,
            createdAt: Date().timeIntervalSince1970
        )
    }

    private static func writeAppGroup(id: String, manifest: Data, jpeg: Data) throws {
        guard let root = containerRoot() else { throw SafariStoreError.noChannel }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let jobDir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
        try writeAtomic(jpeg, to: jobDir.appendingPathComponent(screenshotName))
        try writeAtomic(manifest, to: jobDir.appendingPathComponent(manifestName))
        try writeAtomic(Data(id.utf8), to: root.appendingPathComponent(currentName))
        try? FileManager.default.removeItem(at: root.appendingPathComponent(resultName))
        removeOldJobs(in: root, keeping: id)
    }

    private static func currentJobID() -> String? {
        guard let root = containerRoot(),
              let data = try? Data(contentsOf: root.appendingPathComponent(currentName)),
              let id = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty
        else { return nil }
        return id
    }

    private static func readAppGroupPending() -> LoadedSafariJob? {
        guard let root = containerRoot(), let id = currentJobID() else { return nil }
        let jobDir = root.appendingPathComponent(id, isDirectory: true)
        let manifestURL = jobDir.appendingPathComponent(manifestName)
        let imageURL = jobDir.appendingPathComponent(screenshotName)
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? jsonDecoder().decode(SafariJobManifest.self, from: manifestData),
              manifest.version == SafariBridge.jobVersion,
              manifest.id == id,
              let jpeg = try? Data(contentsOf: imageURL),
              !jpeg.isEmpty
        else { return nil }
        return LoadedSafariJob(manifest: manifest, jpeg: jpeg)
    }

    private static func removeOldJobs(in root: URL, keeping id: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name != id && name != currentName && name != resultName {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
    }

    // MARK: - Pasteboard

    /// Personal Team fallback. `localOnly` keeps the image off Universal Clipboard.
    private static func writePasteboard(manifest: Data, jpeg: Data, lifetime: TimeInterval) -> Bool {
        UIPasteboard.general.setItems(
            [[
                SafariBridge.manifestPasteboardType: manifest,
                SafariBridge.imagePasteboardType: jpeg,
            ]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(lifetime),
            ]
        )
        return UIPasteboard.general.data(forPasteboardType: SafariBridge.manifestPasteboardType) != nil
    }

    private static func readGroupResult() -> SafariResult? {
        guard let root = containerRoot() else { return nil }
        let url = root.appendingPathComponent(resultName)
        guard let data = try? Data(contentsOf: url),
              let result = try? jsonDecoder().decode(SafariResult.self, from: data),
              result.version == SafariBridge.jobVersion
        else { return nil }
        return result
    }

    private static func readPasteboardResult() -> SafariResult? {
        guard let data = UIPasteboard.general.data(forPasteboardType: SafariBridge.resultPasteboardType),
              let result = try? jsonDecoder().decode(SafariResult.self, from: data),
              result.version == SafariBridge.jobVersion
        else { return nil }
        return result
    }

    private static func clearPasteboardManifestIfOurs() {
        guard UIPasteboard.general.contains(pasteboardTypes: [SafariBridge.manifestPasteboardType]) else {
            return
        }
        UIPasteboard.general.setItems([], options: [.localOnly: true])
    }

    private static func writePasteboardResult(_ data: Data) {
        UIPasteboard.general.setItems(
            [[SafariBridge.resultPasteboardType: data]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(resultLifetime),
            ]
        )
    }

    private static func readPasteboardPending() -> LoadedSafariJob? {
        guard let manifestData = UIPasteboard.general.data(forPasteboardType: SafariBridge.manifestPasteboardType),
              let manifest = try? jsonDecoder().decode(SafariJobManifest.self, from: manifestData),
              manifest.version == SafariBridge.jobVersion,
              let jpeg = UIPasteboard.general.data(forPasteboardType: SafariBridge.imagePasteboardType),
              !jpeg.isEmpty
        else { return nil }
        return LoadedSafariJob(manifest: manifest, jpeg: jpeg)
    }

    private static func writeAtomic(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    private static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func jsonDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}

enum SafariPageImage {
    /// One JPEG whose long edge is at most `maxEdge`. The app stretches this
    /// back onto the CSS viewport before OCR, so the boxes stay in CSS pixels.
    static func jpeg(from image: UIImage, maxEdge: CGFloat) -> Data? {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longest = max(pixelWidth, pixelHeight)
        let fitted: UIImage
        if longest > maxEdge, longest > 1 {
            let scale = maxEdge / longest
            let size = CGSize(width: pixelWidth * scale, height: pixelHeight * scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            fitted = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        } else {
            fitted = image
        }
        return fitted.jpegData(compressionQuality: 0.72)
    }

    /// Draws fetched `<img>` / canvas bitmaps into one viewport image when
    /// `tabs.captureVisibleTab` did not return a screenshot.
    static func composeJPEG(
        pieces: [(image: UIImage, rect: CGRect)],
        cssWidth: CGFloat,
        cssHeight: CGFloat,
        scale: CGFloat
    ) -> Data? {
        guard cssWidth > 1, cssHeight > 1, !pieces.isEmpty else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(max(scale, 1), 2)
        format.opaque = true
        let canvas = CGSize(width: cssWidth, height: cssHeight)
        let image = UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: canvas))
            for piece in pieces {
                piece.image.draw(in: piece.rect)
            }
        }
        return image.jpegData(compressionQuality: 0.75)
    }

    /// OCR space is the CSS viewport: `UIImage.size` matches `cssWidth` × `cssHeight`.
    /// A capture that does not share the viewport's aspect (the iOS address bar
    /// sometimes crops the top) is stretched into that rectangle so a box at
    /// `(x, y)` is the same point the content script measured.
    static func forOCR(jpeg: Data, cssWidth: Double, cssHeight: Double) -> UIImage? {
        guard cssWidth > 1, cssHeight > 1, let source = UIImage(data: jpeg) else { return nil }
        let canvas = CGSize(width: cssWidth, height: cssHeight)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: canvas))
        }
    }
}
