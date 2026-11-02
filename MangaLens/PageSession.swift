import UIKit

enum TranslationPhase: Equatable {
    case idle
    case recognizing
    case translating
    case done
    case failed
}

struct TranslatedLine: Identifiable {
    let id: UUID
    let sourceText: String
    let translatedText: String
    /// Same point space as `RecognizedLine.rect`.
    let rect: CGRect
}

/// Latest OCR batch the `translationTask` closure should translate.
/// A class so the SwiftUI task always reads the current request, not a stale copy.
@MainActor
final class TranslationMailbox {
    var generation = 0
    var lines: [RecognizedLine] = []
    var sourceLanguage: SourceLanguage = .japanese
}

@MainActor
final class PageSession: ObservableObject {
    @Published var sourceLanguage: SourceLanguage = .japanese
    @Published var snapshot: UIImage?
    @Published var recognized: [RecognizedLine] = []
    @Published var lines: [TranslatedLine] = []
    @Published var phase: TranslationPhase = .idle
    @Published var statusMessage = "截取当前网页可视区域，识别后翻译成简体中文"
    @Published var isShowingResult = false

    let mailbox = TranslationMailbox()
    private var awaitingLanguageDownload = false

    var isBusy: Bool {
        phase == .recognizing || phase == .translating
    }

    func noteSnapshot(_ image: UIImage) {
        snapshot = image
        cancelTranslationWork()
        phase = .recognizing
        statusMessage = "已截取。正在识别\(sourceLanguage.progressName)…"
        isShowingResult = false
    }

    func beginRecognition() {
        cancelTranslationWork()
        phase = .recognizing
        statusMessage = "正在识别\(sourceLanguage.progressName)…"
        isShowingResult = false
    }

    func storeRecognition(_ lines: [RecognizedLine]) {
        recognized = lines
    }

    func markNeedsDownload() {
        awaitingLanguageDownload = true
        statusMessage = "需要下载语言包。请在系统提示里允许下载，完成后会自动翻译。"
    }

    func markTranslating() {
        phase = .translating
        if !awaitingLanguageDownload {
            statusMessage = "正在翻译成简体中文…"
        }
    }

    func applyTranslations(_ translated: [TranslatedLine]) {
        lines = translated
        phase = .done
        statusMessage = "已翻译 \(translated.count) 处（\(sourceLanguage.title) → 简体中文）"
        isShowingResult = true
    }

    func fail(_ message: String) {
        phase = .failed
        statusMessage = message
        isShowingResult = true
    }

    private func cancelTranslationWork() {
        mailbox.generation += 1
        mailbox.lines = []
        recognized = []
        lines = []
        awaitingLanguageDownload = false
    }
}
