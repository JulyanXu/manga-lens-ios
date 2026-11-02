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
    @StateObject private var session = PageSession()
    @FocusState private var addressFocused: Bool

    private let logger = Logger(subsystem: "com.julyanxu.MangaLens", category: "pipeline")

    private var isBusy: Bool {
        isCapturing || session.isBusy
    }

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            ZStack(alignment: .top) {
                BrowserWebView(
                    url: pageURL,
                    loadID: loadID,
                    captureToken: captureToken,
                    onLoadingChange: { isLoading = $0 },
                    onCapture: handleCapture
                )
                if isLoading {
                    ProgressView()
                        .padding(10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 12)
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
                .disabled(isBusy)
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
                    .disabled(isBusy)
            }

            HStack(spacing: 8) {
                Button(action: requestCapture) {
                    Text("截取并翻译")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)

                Button(action: rerunTranslation) {
                    Text("重新翻译")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .disabled(session.snapshot == nil || isBusy)

                if isBusy {
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
                    .accessibilityLabel("查看译文")
                    .disabled(session.isBusy)
                }
            }

            Text(session.statusMessage)
                .font(.caption)
                .foregroundStyle(session.phase == .failed ? Color.red : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        isCapturing = true
        captureToken = UUID()
    }

    private func rerunTranslation() {
        guard session.snapshot != nil, !isBusy else { return }
        addressFocused = false
        session.beginRecognition()
        Task { await runPipeline() }
    }

    private func handleCapture(_ result: Result<UIImage, Error>) {
        isCapturing = false
        switch result {
        case .success(let image):
            session.noteSnapshot(image)
            let width = Int(image.size.width.rounded())
            let height = Int(image.size.height.rounded())
            let pixelsW = Int((image.size.width * image.scale).rounded())
            let pixelsH = Int((image.size.height * image.scale).rounded())
            let line = "[MangaLens] visible viewport \(width) × \(height) pt, \(pixelsW) × \(pixelsH) px, scale \(image.scale)"
            print(line)
            logger.info("\(line, privacy: .public)")
            Task { await runPipeline() }
        case .failure(let error):
            let line = "[MangaLens] visible snapshot failed: \(error.localizedDescription)"
            print(line)
            logger.error("\(line, privacy: .public)")
            presentAlert(title: "截取失败", message: error.localizedDescription)
        }
    }

    private func runPipeline() async {
        guard let image = session.snapshot else { return }
        let language = session.sourceLanguage
        session.beginRecognition()

        do {
            let recognized = try await TextRecognizer.recognize(image: image, language: language)
            guard !recognized.isEmpty else {
                session.fail("没有识别到文字。可以换「原文」语言，或换一页再截。")
                log("OCR found no text (\(language.rawValue))")
                return
            }
            session.storeRecognition(recognized)
            log("OCR \(recognized.count) regions, source \(language.rawValue)")

            switch await languagePackStatus(for: language) {
            case .unsupported:
                session.fail("这台系统不能把\(language.title)译成简体中文。请换语言，或确认系统版本是 iOS 18 及以上。")
                return
            case .needsDownload:
                session.markNeedsDownload()
            case .installed:
                break
            }

            session.mailbox.generation += 1
            session.mailbox.lines = recognized
            session.mailbox.sourceLanguage = language
            session.markTranslating()
            armTranslation(for: language)
        } catch {
            session.fail("识别失败：\(error.localizedDescription)")
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
        guard generation > 0, !recognized.isEmpty else { return }

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
            guard session.mailbox.generation == generation else { return }

            let translated = match(recognized: recognized, responses: responses)
            session.applyTranslations(translated)
            log("translated \(translated.count) lines to zh-Hans")
        } catch {
            guard session.mailbox.generation == generation else { return }
            session.fail(translationFailureMessage(error))
            log("translation failed: \(error.localizedDescription)")
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
