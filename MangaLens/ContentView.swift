import os
import SwiftUI
import UIKit

struct ContentView: View {
    @State private var address = "https://www.apple.com"
    @State private var pageURL = URL(string: "https://www.apple.com")!
    @State private var loadID = 0
    @State private var captureToken: UUID?
    @State private var isLoading = false
    @State private var isCapturing = false
    @State private var latestCapture: CapturePreview?
    @State private var presentedCapture: CapturePreview?
    @State private var alertTitle = "提示"
    @State private var alertMessage: String?
    @FocusState private var addressFocused: Bool

    private let captureLogger = Logger(subsystem: "com.julyanxu.MangaLens", category: "capture")

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
        .sheet(item: $presentedCapture) { preview in
            CapturePreviewSheet(preview: preview)
        }
        .alert(alertTitle, isPresented: alertIsPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var controlBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Manga Lens")
                .font(.headline)

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

            HStack(spacing: 10) {
                Button(action: requestCapture) {
                    Label("截取可视区域", systemImage: "viewfinder")
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCapturing)

                if isCapturing {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer(minLength: 8)

                if let latestCapture {
                    Button {
                        presentedCapture = latestCapture
                    } label: {
                        Image(uiImage: latestCapture.image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                            }
                    }
                    .accessibilityLabel("查看最近截图")
                }
            }

            Text(statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var statusLine: String {
        if let latestCapture {
            return "已截取 \(latestCapture.pointLabel) · \(latestCapture.pixelLabel)"
        }
        return "只截取当前网页可视区域，不截整页，也不截整个窗口"
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

    private func handleCapture(_ result: Result<UIImage, Error>) {
        isCapturing = false
        switch result {
        case .success(let image):
            let preview = CapturePreview(image: image)
            latestCapture = preview
            presentedCapture = preview
            let line = "[MangaLens] visible viewport \(preview.pointLabel), \(preview.pixelLabel), scale \(image.scale)"
            print(line)
            captureLogger.info("\(line, privacy: .public)")
        case .failure(let error):
            let line = "[MangaLens] visible snapshot failed: \(error.localizedDescription)"
            print(line)
            captureLogger.error("\(line, privacy: .public)")
            presentAlert(title: "截取失败", message: error.localizedDescription)
        }
    }

    private func presentAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
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

struct CapturePreview: Identifiable {
    let id = UUID()
    let image: UIImage

    var pointSize: CGSize { image.size }

    var pixelSize: CGSize {
        CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    var pointLabel: String {
        "\(Self.rounded(pointSize.width)) × \(Self.rounded(pointSize.height)) pt"
    }

    var pixelLabel: String {
        "\(Self.rounded(pixelSize.width)) × \(Self.rounded(pixelSize.height)) px"
    }

    private static func rounded(_ value: CGFloat) -> Int {
        Int(value.rounded())
    }
}

private struct CapturePreviewSheet: View {
    let preview: CapturePreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(preview.pointLabel) · \(preview.pixelLabel)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("这是 WKWebView 当前可视区域，不是整页，也不是整个 App 窗口。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Image(uiImage: preview.image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                        }
                        .accessibilityLabel("网页可视区域截图")
                }
                .padding()
            }
            .navigationTitle("截取预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    ContentView()
}
