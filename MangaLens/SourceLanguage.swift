import Foundation
import Translation

/// Source text for the on-device pipeline. Japanese is the default happy path.
/// Korean, English, and automatic detection use the same OCR and Translation calls.
enum SourceLanguage: String, CaseIterable, Identifiable {
    case japanese
    case korean
    case english
    case automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .japanese: "日语"
        case .korean: "韩语"
        case .english: "英语"
        case .automatic: "自动"
        }
    }

    /// Wording used while Vision is running.
    var progressName: String {
        switch self {
        case .japanese: "日语文字"
        case .korean: "韩语文字"
        case .english: "英语文字"
        case .automatic: "文字"
        }
    }

    /// BCP-47 tags Vision accepts for `.accurate` recognition. Resolved against
    /// the device list at runtime in case the OS reports `ja` instead of `ja-JP`.
    var visionLanguageHints: [String] {
        switch self {
        case .japanese: ["ja-JP", "ja"]
        case .korean: ["ko-KR", "ko"]
        case .english: ["en-US", "en"]
        case .automatic: ["ja-JP", "ja", "ko-KR", "ko", "en-US", "en"]
        }
    }

    var detectsLanguage: Bool { self == .automatic }

    /// `nil` lets TranslationSession identify the source language.
    var translationSource: Locale.Language? {
        switch self {
        case .japanese: Locale.Language(identifier: "ja")
        case .korean: Locale.Language(identifier: "ko")
        case .english: Locale.Language(identifier: "en")
        case .automatic: nil
        }
    }

    /// Pairs to check before opening a session. Automatic mode is usable when
    /// any of these directions can be installed.
    var availabilitySources: [Locale.Language] {
        switch self {
        case .japanese, .korean, .english:
            return translationSource.map { [$0] } ?? []
        case .automatic:
            return [
                Locale.Language(identifier: "ja"),
                Locale.Language(identifier: "ko"),
                Locale.Language(identifier: "en"),
            ]
        }
    }
}

enum LanguagePackStatus {
    case installed
    case needsDownload
    case unsupported
}

func languagePackStatus(for language: SourceLanguage) async -> LanguagePackStatus {
    let availability = LanguageAvailability()
    let target = Locale.Language(identifier: "zh-Hans")
    var installed = 0
    var downloadable = 0

    for source in language.availabilitySources {
        let status = await availability.status(from: source, to: target)
        switch status {
        case .installed:
            installed += 1
        case .supported:
            downloadable += 1
        case .unsupported:
            break
        @unknown default:
            break
        }
    }

    if installed > 0 {
        return .installed
    }
    if downloadable > 0 {
        return .needsDownload
    }
    return .unsupported
}
