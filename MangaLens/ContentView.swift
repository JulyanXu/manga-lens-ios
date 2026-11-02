import os
import SwiftUI
import Translation
import UIKit

struct ContentView: View {
    @State private var address = "https://www.apple.com"
    @State private var pageURL = URL(string: "https://www.apple.com")!
    @State private var loadID = 0
    @State private var captureToken: UUID?
    @State private var isLoading = false
    @State private var isCapturing = false
    @State private var alertTitle = "提示"
    @State private var alertMessage: String?
    @State private var configuration: TranslationSession.Configuration?
    @State private var armedLanguageKey: String?
    @State private var pageCache = PageTranslationCache()
    @StateObject private var session = PageSession()
    @FocusState private var addressFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    private let logger = Logger(subsystem: "com.julyanxu.MangaLens", category: "pipeline")

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            ZStack(alignment: .top) {
                BrowserWebView(
                    url: pageURL,
                    loadID: loadID,
                    captureToken: captureToken,
                    liveAnchors: session.liveAnchors,
                    showsLiveOverlay: session.displayMode == .live,
                    autoEnabled: session.autoEnabled,
                    onLoadingChange: { isLoading = $0 },
                    onCapture: handleCapture,
                    onNavigationStarted: navigationStarted,
                    onViewportSettled: viewportSettled
                )
                if isLoading {
                    ProgressView()
                        .padding(10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 12)
                        .allowsHitTesting(false)
                }
            }
        }
        .ignoresSafeArea(.keyboard)
        .background(Color(uiColor: .systemBackground))
        .sheet(isPresented: $session.isShowingResult) {
            SnapshotResultSheet(session: session)
        }
        .alert(alertTitle, isPresented: alertIsPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        .translationTask(configuration) { @MainActor translationSession in
            await performTranslation(translationSession)
        }
        .onOpenURL { url in
            guard SafariBridge.isOpenURL(url) else { return }
            Task { await consumePendingSafariJob(fromURL: true) }
        }
        .onAppear {
            Task { await consumePendingSafariJob(fromURL: false) }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await consumePendingSafariJob(fromURL: false) }
        }
    }

    private var controlBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Manga Lens")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("原文")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("原文语言", selection: $session.sourceLanguage) {
                    ForEach(SourceLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(session.isBusy)
            }

            HStack(spacing: 12) {
                Toggle("自动", isOn: $session.autoEnabled)
                    .font(.subheadline)
                    .fixedSize()
                Picker("显示", selection: $session.displayMode) {
                    ForEach(OverlayPresentation.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("译文显示方式")
            }

            HStack(spacing: 8) {
                TextField("输入网址", text: $address)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit(openAddress)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )

                Button("前往", action: openAddress)
                    .buttonStyle(.bordered)
            }

            HStack(spacing: 8) {
                Button(action: requestCapture) {
                    Text("截取并翻译")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCapturing)

                Button(action: rerunTranslation) {
                    Text("重新翻译")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .disabled(session.lastCapture == nil || session.isBusy)

                if isCapturing || session.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer(minLength: 8)

                if let image = session.snapshot {
                    Button {
                        session.isShowingResult = true
                    } label: {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                            }
                    }
                    .accessibilityLabel("打开截图预览")
                }
            }

            Text(session.statusMessage)
                .font(.caption)
                .foregroundStyle(session.phase == .failed ? Color.red : Color.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var alertIsPresented: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { isPresented in
                if !isPresented {
                    alertMessage = nil
                }
            }
        )
    }

    private func openAddress() {
        addressFocused = false
        guard let url = Self.normalizedWebURL(from: address) else {
            presentAlert(title: "无法打开", message: "请输入 http 或 https 网址。没有写协议时会自动补上 https://。")
            return
        }
        address = url.absoluteString
        pageURL = url
        loadID += 1
    }

    private func requestCapture() {
        addressFocused = false
        session.endSafariJob()
        isCapturing = true
        captureToken = UUID()
    }

    private func rerunTranslation() {
        guard let capture = session.lastCapture, !session.isBusy else { return }
        addressFocused = false
        Task { await runPipeline(capture: capture, bypassCache: true) }
    }

    private func viewportSettled() {
        guard session.autoEnabled, session.safariContext == nil else { return }
        addressFocused = false
        isCapturing = true
        captureToken = UUID()
    }

    private func navigationStarted() {
        session.pageWillChange()
    }

    private func handleCapture(_ result: ViewportCaptureResult) {
        switch result {
        case .ready(let capture):
            isCapturing = false
            // A settle that was already in flight must not replace the Safari snapshot.
            guard session.safariContext == nil else {
                log("ignored in-app snapshot while Safari capture is active")
                return
            }
            session.noteSnapshot(capture)
            let image = capture.image
            let width = Int(image.size.width.rounded())
            let height = Int(image.size.height.rounded())
            let pixelsW = Int((image.size.width * image.scale).rounded())
            let pixelsH = Int((image.size.height * image.scale).rounded())
            log("visible viewport \(width) × \(height) pt, \(pixelsW) × \(pixelsH) px, scale \(image.scale)")
            Task { await runPipeline(capture: capture, bypassCache: false) }
        case .skipped:
            isCapturing = false
            log("snapshot skipped because the page moved")
        case .failed(let error):
            isCapturing = false
            log("visible snapshot failed: \(error.localizedDescription)")
            presentAlert(title: "截取失败", message: error.localizedDescription)
        }
    }

    private func runPipeline(capture: ViewportCapture, bypassCache: Bool) async {
        let language = session.sourceLanguage
        session.beginRecognition()
        let generation = session.mailbox.generation

        if !bypassCache,
           let fingerprint = ImageFingerprint.dHash(capture.image),
           let hit = pageCache.lookup(
               url: capture.pageURL,
               language: language,
               fingerprint: fingerprint,
               contentOffset: capture.contentOffset,
               viewportSize: capture.viewportSize
           ) {
            guard session.mailbox.generation == generation else {
                log("dropped stale cache hit")
                return
            }
            let lines = fitted(hit.lines, from: hit.snapshotSize, to: capture.image.size)
            session.applyResult(lines: lines, capture: capture, cacheHit: true)
            showPreviewIfNeeded()
            log("cache hit hamming=\(hit.distance) entries=\(pageCache.count)")
            return
        }

        do {
            let recognized = try await TextRecognizer.recognize(image: capture.image, language: language)
            guard session.mailbox.generation == generation else {
                log("dropped stale OCR")
                return
            }
            guard !recognized.isEmpty else {
                session.fail("没有识别到文字。可以换「原文」语言，或换一页再截。")
                showPreviewIfNeeded()
                log("OCR found no text (\(language.rawValue))")
                return
            }
            session.storeRecognition(recognized)
            log("OCR \(recognized.count) regions, source \(language.rawValue)")

            switch await languagePackStatus(for: language) {
            case .unsupported:
                guard session.mailbox.generation == generation else { return }
                session.fail("这台系统不能把\(language.title)译成简体中文。请换语言，或确认系统版本是 iOS 18 及以上。")
                showPreviewIfNeeded()
                return
            case .needsDownload:
                session.markNeedsDownload()
            case .installed:
                break
            }

            guard session.mailbox.generation == generation else {
                log("dropped stale OCR before translation")
                return
            }
            session.stageTranslation(lines: recognized, capture: capture, language: language)
            session.markTranslating()
            armTranslation(for: language)
        } catch {
            guard session.mailbox.generation == generation else { return }
            session.fail("识别失败：\(error.localizedDescription)")
            showPreviewIfNeeded()
            log("OCR failed: \(error.localizedDescription)")
        }
    }

    /// Starts or repeats the SwiftUI translation task.
    /// A new configuration is required when the source language changes.
    /// The same languages only run again after `invalidate()`.
    private func armTranslation(for language: SourceLanguage) {
        let key = language.rawValue
        if configuration == nil || armedLanguageKey != key {
            armedLanguageKey = key
            configuration = TranslationSession.Configuration(
                source: language.translationSource,
                target: Locale.Language(identifier: "zh-Hans")
            )
            return
        }
        configuration?.invalidate()
    }

    private func performTranslation(_ translationSession: TranslationSession) async {
        let generation = session.mailbox.generation
        let recognized = session.mailbox.lines
        let capture = session.pendingCapture
        guard generation > 0, !recognized.isEmpty, let capture else { return }

        do {
            // `prepareTranslation()` needs a known source. Automatic mode passes
            // nil and lets `translations(from:)` identify the language from the text.
            if session.mailbox.sourceLanguage != .automatic {
                try await translationSession.prepareTranslation()
            }
            let requests = recognized.map { line in
                TranslationSession.Request(
                    sourceText: line.sourceText,
                    clientIdentifier: line.id.uuidString
                )
            }
            let responses = try await translationSession.translations(from: requests)
            guard session.mailbox.generation == generation else {
                log("dropped stale translation")
                return
            }

            let translated = match(recognized: recognized, responses: responses)
            session.applyResult(lines: translated, capture: capture, cacheHit: false)
            showPreviewIfNeeded()
            if let fingerprint = ImageFingerprint.dHash(capture.image) {
                pageCache.store(
                    url: capture.pageURL,
                    language: session.mailbox.sourceLanguage,
                    fingerprint: fingerprint,
                    capture: capture,
                    lines: translated
                )
            }
            log("translated \(translated.count) lines to zh-Hans, cache=\(pageCache.count)")
        } catch {
            guard session.mailbox.generation == generation else { return }
            session.fail(translationFailureMessage(error))
            showPreviewIfNeeded()
            log("translation failed: \(error.localizedDescription)")
        }
    }

    private func showPreviewIfNeeded() {
        if session.displayMode == .preview {
            session.isShowingResult = true
        }
    }

    private func fitted(_ lines: [TranslatedLine], from source: CGSize, to target: CGSize) -> [TranslatedLine] {
        guard source.width > 1, source.height > 1 else { return lines }
        let scaleX = target.width / source.width
        let scaleY = target.height / source.height
        if abs(scaleX - 1) < 0.02, abs(scaleY - 1) < 0.02 {
            return lines
        }
        return lines.map { line in
            TranslatedLine(
                id: line.id,
                sourceText: line.sourceText,
                translatedText: line.translatedText,
                rect: CGRect(
                    x: line.rect.minX * scaleX,
                    y: line.rect.minY * scaleY,
                    width: line.rect.width * scaleX,
                    height: line.rect.height * scaleY
                )
            )
        }
    }

    private func match(
        recognized: [RecognizedLine],
        responses: [TranslationSession.Response]
    ) -> [TranslatedLine] {
        var byID: [String: String] = [:]
        for response in responses {
            if let identifier = response.clientIdentifier {
                byID[identifier] = response.targetText
            }
        }

        if !byID.isEmpty {
            return recognized.map { line in
                translatedLine(line, target: byID[line.id.uuidString] ?? "")
            }
        }

        return recognized.enumerated().map { index, line in
            let target = index < responses.count ? responses[index].targetText : ""
            return translatedLine(line, target: target)
        }
    }

    private func translatedLine(_ line: RecognizedLine, target: String) -> TranslatedLine {
        let cleaned = target.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranslatedLine(
            id: line.id,
            sourceText: line.sourceText,
            translatedText: cleaned.isEmpty ? line.sourceText : cleaned,
            rect: line.rect
        )
    }

    private func translationFailureMessage(_ error: Error) -> String {
        if error is CancellationError {
            return "已取消。语言包没有装好，所以没有翻译。点「重新翻译」可再试。"
        }
        return "翻译没有完成：\(error.localizedDescription)。如果系统刚询问语言包，请允许下载后再点「重新翻译」。"
    }

    private func presentAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
    }

    private func consumePendingSafariJob(fromURL: Bool) async {
        var loaded = SafariJobStore.peekPending()
        if loaded == nil, fromURL {
            try? await Task.sleep(nanoseconds: 400_000_000)
            loaded = SafariJobStore.peekPending()
        }
        guard let loaded else {
            if fromURL {
                presentAlert(
                    title: "没有接到画面",
                    message: "Safari 扩展还没有把这一屏放进共享位置。回到 Safari，再点一次「翻译可视区域」。如果提示走了剪贴板，中途不要复制别的内容。"
                )
            }
            return
        }
        guard session.claimSafariJob(loaded.manifest.id) else { return }

        let manifest = loaded.manifest
        let context = SafariPageContext(
            jobID: manifest.id,
            pageURL: manifest.pageURL,
            cssWidth: manifest.cssWidth,
            cssHeight: manifest.cssHeight,
            anchors: manifest.anchors,
            channel: manifest.channel
        )
        guard let image = SafariPageImage.forOCR(
            jpeg: loaded.jpeg,
            cssWidth: manifest.cssWidth,
            cssHeight: manifest.cssHeight
        ) else {
            session.beginSafariJob(context)
            session.fail("Safari 传来的画面无法读取。回到 Safari 再截一次。")
            return
        }

        if let language = SourceLanguage(rawValue: manifest.language) {
            session.sourceLanguage = language
        }
        let capture = ViewportCapture(
            image: image,
            pageURL: manifest.pageURL,
            contentOffset: .zero,
            zoomScale: 1,
            viewportSize: image.size
        )
        session.beginSafariJob(context)
        session.noteSnapshot(capture)
        let width = Int(image.size.width.rounded())
        let height = Int(image.size.height.rounded())
        log("safari viewport \(width) × \(height) pt, channel \(manifest.channel)")
        await runPipeline(capture: capture, bypassCache: false)
    }

    private func log(_ message: String) {
        let line = "[MangaLens] \(message)"
        print(line)
        logger.info("\(line, privacy: .public)")
    }

    /// Accepts any http(s) URL. A bare host such as `example.com/path` becomes `https://…`.
    static func normalizedWebURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              let url = components.url
        else {
            return nil
        }
        return url
    }
}

#Preview {
    ContentView()
}
