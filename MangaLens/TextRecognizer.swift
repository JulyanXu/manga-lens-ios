import UIKit
import Vision

struct RecognizedLine: Identifiable, Sendable {
    let id: UUID
    let sourceText: String
    /// Top-left origin, in `UIImage.size` points — the same space SwiftUI `Image` uses.
    let rect: CGRect
}

enum TextRecognitionError: LocalizedError {
    case unreadableImage
    case languageUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return "这张截图无法读取。"
        case .languageUnavailable(let name):
            return "这台设备的文字识别暂不支持\(name)。"
        }
    }
}

enum TextRecognizer {
    static func recognize(image: UIImage, language: SourceLanguage) async throws -> [RecognizedLine] {
        guard let cgImage = image.cgImage else {
            throw TextRecognitionError.unreadableImage
        }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        let imageSize = image.size
        let hints = language.visionLanguageHints
        let detectsLanguage = language.detectsLanguage
        let languageTitle = language.title

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let lines = try perform(
                        cgImage: cgImage,
                        orientation: orientation,
                        imageSize: imageSize,
                        hints: hints,
                        detectsLanguage: detectsLanguage,
                        languageTitle: languageTitle
                    )
                    continuation.resume(returning: lines)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func perform(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation,
        imageSize: CGSize,
        hints: [String],
        detectsLanguage: Bool,
        languageTitle: String
    ) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Manga bubbles are often shorter than the default 1/32 of the image.
        request.minimumTextHeight = 0.006

        let supported = try VNRecognizeTextRequest.supportedRecognitionLanguages(
            for: .accurate,
            revision: VNRecognizeTextRequest.currentRevision
        )
        let languages = match(hints, in: supported)
        guard !languages.isEmpty else {
            throw TextRecognitionError.languageUnavailable(languageTitle)
        }
        // Explicit modes use one language so Japanese manga is not read as English UI chrome.
        request.recognitionLanguages = detectsLanguage ? languages : Array(languages.prefix(1))
        request.automaticallyDetectsLanguage = detectsLanguage

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        try handler.perform([request])

        let observations = request.results ?? []
        let lines: [RecognizedLine] = observations.compactMap { observation in
            guard let raw = observation.topCandidates(1).first?.string else { return nil }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            let rect = imageRect(for: observation.boundingBox, imageSize: imageSize)
            guard rect.width > 1, rect.height > 1 else { return nil }
            return RecognizedLine(id: UUID(), sourceText: text, rect: rect)
        }

        return lines.sorted { lhs, rhs in
            if abs(lhs.rect.minY - rhs.rect.minY) > 8 {
                return lhs.rect.minY < rhs.rect.minY
            }
            return lhs.rect.minX < rhs.rect.minX
        }
    }

    /// Vision boxes are normalized with the origin at the bottom-left.
    /// `UIImage` / SwiftUI use a top-left origin in points.
    private static func imageRect(for normalized: CGRect, imageSize: CGSize) -> CGRect {
        let rect = CGRect(
            x: normalized.minX * imageSize.width,
            y: (1 - normalized.maxY) * imageSize.height,
            width: normalized.width * imageSize.width,
            height: normalized.height * imageSize.height
        )
        let padX = max(1, rect.height * 0.15)
        let padY = max(1, rect.height * 0.2)
        let expanded = rect.insetBy(dx: -padX, dy: -padY)
        return expanded.intersection(CGRect(origin: .zero, size: imageSize))
    }

    private static func match(_ requested: [String], in supported: [String]) -> [String] {
        var resolved: [String] = []
        var seen = Set<String>()
        for code in requested {
            let match = supported.first { $0.caseInsensitiveCompare(code) == .orderedSame }
                ?? supported.first { candidate in
                    let stem = code.split(separator: "-").first.map(String.init)?.lowercased() ?? code.lowercased()
                    let lowered = candidate.lowercased()
                    return lowered == stem || lowered.hasPrefix(stem + "-")
                }
            if let match, seen.insert(match).inserted {
                resolved.append(match)
            }
        }
        return resolved
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
