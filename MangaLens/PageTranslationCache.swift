import UIKit

/// One visible-viewport snapshot plus the scroll position it was taken at.
struct ViewportCapture {
    let image: UIImage
    /// Canonical page URL without the fragment.
    let pageURL: String
    let contentOffset: CGPoint
    let zoomScale: CGFloat
    let viewportSize: CGSize
}

enum ViewportCaptureResult {
    case ready(ViewportCapture)
    case skipped
    case failed(Error)
}

/// A translated box anchored in the scroll view's content coordinates.
struct LiveAnchor: Identifiable {
    let id: UUID
    let text: String
    /// OCR box in the snapshot's point space (top-left origin).
    let rectInSnapshot: CGRect
    let snapshotSize: CGSize
    /// `scrollView.contentOffset` when this box was captured.
    let contentOffset: CGPoint
    let zoomScale: CGFloat
}

func canonicalPageURL(_ url: URL?) -> String {
    guard let url else { return "" }
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return url.absoluteString
    }
    components.fragment = nil
    return components.string ?? url.absoluteString
}

/// 64-bit difference hash of a 9×8 downsample. Used only to recognize a viewport
/// we have already translated, not as a cryptographic digest.
enum ImageFingerprint {
    static func dHash(_ image: UIImage) -> UInt64? {
        let width = 9
        let height = 8
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        )
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let cgImage = rendered.cgImage else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        func luma(_ x: Int, _ y: Int) -> Int {
            let index = y * bytesPerRow + x * bytesPerPixel
            let red = Int(pixels[index])
            let green = Int(pixels[index + 1])
            let blue = Int(pixels[index + 2])
            return (red * 3 + green * 6 + blue) / 10
        }

        var hash: UInt64 = 0
        var bitIndex = 0
        for y in 0..<height {
            for x in 0..<(width - 1) {
                if luma(x, y) > luma(x + 1, y) {
                    hash |= (UInt64(1) << bitIndex)
                }
                bitIndex += 1
            }
        }
        return hash
    }

    static func hamming(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }
}

/// LRU of recent viewport translations. Lookup is URL + source language + image
/// hash, and a loose hash match also has to sit near the same scroll offset.
@MainActor
final class PageTranslationCache {
    static let capacity = 20
    static let maxHamming = 4

    private struct Entry {
        let url: String
        let language: SourceLanguage
        let fingerprint: UInt64
        let contentOffset: CGPoint
        let viewportSize: CGSize
        let snapshotSize: CGSize
        let lines: [TranslatedLine]
    }

    private var entries: [Entry] = []

    var count: Int { entries.count }

    func lookup(
        url: String,
        language: SourceLanguage,
        fingerprint: UInt64,
        contentOffset: CGPoint,
        viewportSize: CGSize
    ) -> (lines: [TranslatedLine], snapshotSize: CGSize, distance: Int)? {
        var bestIndex: Int?
        var bestDistance = Int.max
        for index in entries.indices {
            let entry = entries[index]
            guard entry.url == url, entry.language == language else { continue }
            let distance = ImageFingerprint.hamming(entry.fingerprint, fingerprint)
            guard distance <= Self.maxHamming else { continue }
            if distance > 0 && !isNear(entry, offset: contentOffset, viewport: viewportSize) {
                continue
            }
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        guard let bestIndex else { return nil }
        let entry = entries.remove(at: bestIndex)
        entries.insert(entry, at: 0)
        return (entry.lines, entry.snapshotSize, bestDistance)
    }

    func store(
        url: String,
        language: SourceLanguage,
        fingerprint: UInt64,
        capture: ViewportCapture,
        lines: [TranslatedLine]
    ) {
        guard !url.isEmpty, !lines.isEmpty else { return }
        entries.removeAll { entry in
            entry.url == url
                && entry.language == language
                && ImageFingerprint.hamming(entry.fingerprint, fingerprint) <= Self.maxHamming
        }
        entries.insert(
            Entry(
                url: url,
                language: language,
                fingerprint: fingerprint,
                contentOffset: capture.contentOffset,
                viewportSize: capture.viewportSize,
                snapshotSize: capture.image.size,
                lines: lines
            ),
            at: 0
        )
        if entries.count > Self.capacity {
            entries.removeLast(entries.count - Self.capacity)
        }
    }

    private func isNear(_ entry: Entry, offset: CGPoint, viewport: CGSize) -> Bool {
        let width = max(viewport.width, entry.viewportSize.width, 1)
        let height = max(viewport.height, entry.viewportSize.height, 1)
        return abs(entry.contentOffset.x - offset.x) < width * 1.25
            && abs(entry.contentOffset.y - offset.y) < height * 1.25
    }
}
