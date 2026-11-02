import UIKit

enum TranslationPhase: Equatable {
    case idle
    case recognizing
    case translating
    case done
    case failed
}

enum OverlayPresentation: String, CaseIterable, Identifiable {
    case live
    case preview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: "网页"
        case .preview: "截图"
        }
    }
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
    @Published var autoEnabled = true
    @Published var displayMode: OverlayPresentation = .live
    @Published var snapshot: UIImage?
    @Published var recognized: [RecognizedLine] = []
    @Published var lines: [TranslatedLine] = []
    @Published var liveAnchors: [LiveAnchor] = []
    @Published var phase: TranslationPhase = .idle
    @Published var statusMessage = "自动翻页已开。滚动停稳或打开新页面后会翻译，并盖在网页上。"
    @Published var isShowingResult = false

    let mailbox = TranslationMailbox()
    private(set) var lastCapture: ViewportCapture?
    private(set) var pendingCapture: ViewportCapture?
    private var awaitingLanguageDownload = false

    var isBusy: Bool {
        phase == .recognizing || phase == .translating
    }

    func noteSnapshot(_ capture: ViewportCapture) {
        lastCapture = capture
        snapshot = capture.image
    }

    func beginRecognition() {
        mailbox.generation += 1
        mailbox.lines = []
        pendingCapture = nil
        recognized = []
        lines = []
        awaitingLanguageDownload = false
        phase = .recognizing
        statusMessage = "正在识别\(sourceLanguage.progressName)…"
        if displayMode == .preview {
            isShowingResult = false
        }
    }

    /// A navigation replaced the document. Drop in-flight work and the old labels.
    func pageWillChange() {
        mailbox.generation += 1
        mailbox.lines = []
        pendingCapture = nil
        recognized = []
        lines = []
        liveAnchors = []
        awaitingLanguageDownload = false
        if phase == .recognizing || phase == .translating {
            phase = .idle
        }
        statusMessage = autoEnabled
            ? "打开了新页面，停稳后会自动翻译。"
            : "打开了新页面。点「截取并翻译」可以翻译这一屏。"
    }

    func storeRecognition(_ lines: [RecognizedLine]) {
        recognized = lines
    }

    func markNeedsDownload() {
        awaitingLanguageDownload = true
        statusMessage = "需要下载语言包。请在系统提示里允许下载，完成后会自动翻译。"
    }

    func stageTranslation(lines: [RecognizedLine], capture: ViewportCapture, language: SourceLanguage) {
        mailbox.generation += 1
        mailbox.lines = lines
        mailbox.sourceLanguage = language
        pendingCapture = capture
    }

    func markTranslating() {
        phase = .translating
        if !awaitingLanguageDownload {
            statusMessage = "正在翻译成简体中文…"
        }
    }

    func applyResult(lines: [TranslatedLine], capture: ViewportCapture, cacheHit: Bool) {
        self.lines = lines
        liveAnchors = lines.map { line in
            LiveAnchor(
                id: line.id,
                text: line.translatedText,
                rectInSnapshot: line.rect,
                snapshotSize: capture.image.size,
                contentOffset: capture.contentOffset,
                zoomScale: capture.zoomScale
            )
        }
        phase = .done
        let place = displayMode == .live ? "已盖在网页上" : "在截图预览里"
        if cacheHit {
            statusMessage = "这屏翻译过，直接用了缓存（\(lines.count) 处），\(place)。"
        } else {
            statusMessage = "已翻译 \(lines.count) 处（\(sourceLanguage.title) → 简体中文），\(place)。"
        }
    }

    func fail(_ message: String) {
        phase = .failed
        statusMessage = message
    }
}
