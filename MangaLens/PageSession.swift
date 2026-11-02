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
    /// Set while the snapshot came from Safari. Live labels stay off the in-app page.
    private(set) var safariContext: SafariPageContext?
    private var claimedSafariJobs: Set<String> = []
    private var awaitingLanguageDownload = false

    var isBusy: Bool {
        phase == .recognizing || phase == .translating
    }

    func noteSnapshot(_ capture: ViewportCapture) {
        lastCapture = capture
        snapshot = capture.image
    }

    /// One Safari capture is translated once per app launch, even if the URL
    /// and `scenePhase` both wake us.
    func claimSafariJob(_ id: String) -> Bool {
        claimedSafariJobs.insert(id).inserted
    }

    func beginSafariJob(_ context: SafariPageContext) {
        safariContext = context
        liveAnchors = []
    }

    /// The in-app browser took a new screenshot. Drop any Safari handoff so its
    /// boxes are not painted onto this page.
    func endSafariJob() {
        if let id = safariContext?.jobID {
            SafariJobStore.abandon(id)
        }
        safariContext = nil
        mailbox.generation += 1
        mailbox.lines = []
    }

    func beginRecognition() {
        mailbox.generation += 1
        mailbox.lines = []
        pendingCapture = nil
        recognized = []
        lines = []
        awaitingLanguageDownload = false
        phase = .recognizing
        statusMessage = safariContext == nil
            ? "正在识别\(sourceLanguage.progressName)…"
            : "正在识别 Safari 这一屏里的\(sourceLanguage.progressName)…"
        if displayMode == .preview || safariContext != nil {
            isShowingResult = false
        }
    }

    /// A navigation replaced the in-app document. Drop in-flight work and the old labels.
    /// A Safari capture is a different page, so loading the in-app browser must not cancel it.
    func pageWillChange() {
        guard safariContext == nil else {
            liveAnchors = []
            return
        }
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
        statusMessage = safariContext == nil
            ? "需要下载语言包。请在系统提示里允许下载，完成后会自动翻译。"
            : "Safari 这一屏需要语言包。请在系统提示里允许下载，完成后会自动翻译。"
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
        phase = .done
        if let context = safariContext {
            // These boxes belong to a Safari viewport, not the WKWebView on screen.
            liveAnchors = []
            if cacheHit {
                statusMessage = "Safari 这一屏用了缓存（\(lines.count) 处）。回到 Safari，点扩展里的「在页面上显示译文」。"
            } else {
                statusMessage = "Safari 这一屏已翻译 \(lines.count) 处（\(sourceLanguage.title) → 简体中文）。回到 Safari，点扩展里的「在页面上显示译文」。"
            }
            isShowingResult = true
            commitSafariResult(lines: lines, context: context, message: statusMessage)
            return
        }

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
        guard let context = safariContext else { return }
        liveAnchors = []
        isShowingResult = true
        commitSafariResult(lines: [], context: context, message: message)
    }

    private func commitSafariResult(lines: [TranslatedLine], context: SafariPageContext, message: String) {
        let result = SafariResult(
            version: SafariBridge.jobVersion,
            jobID: context.jobID,
            pageURL: context.pageURL,
            cssWidth: context.cssWidth,
            cssHeight: context.cssHeight,
            lines: lines.compactMap { line in
                let rect = line.rect
                guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else {
                    return nil
                }
                let text = line.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return SafariResultLine(
                    text: text,
                    source: line.sourceText,
                    x: Double(rect.minX),
                    y: Double(rect.minY),
                    w: Double(rect.width),
                    h: Double(rect.height)
                )
            },
            anchors: context.anchors,
            message: message,
            createdAt: Date().timeIntervalSince1970
        )
        let channel = SafariChannel(rawValue: context.channel) ?? .appGroup
        SafariJobStore.writeResult(result, channel: channel)
    }
}

struct SafariPageContext {
    let jobID: String
    let pageURL: String
    let cssWidth: Double
    let cssHeight: Double
    let anchors: [SafariAnchor]
    let channel: String
}
