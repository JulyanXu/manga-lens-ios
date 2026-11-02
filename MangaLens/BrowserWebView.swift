import SwiftUI
import UIKit
import WebKit

/// In-app browser surface. Loads any http(s) URL the caller hands it and can
/// snapshot only the web view's current on-screen bounds.
struct BrowserWebView: UIViewRepresentable {
    let url: URL
    /// Bumps when the user hits Go, including a reload of the same URL.
    var loadID: Int
    /// New value requests one visible-viewport snapshot.
    var captureToken: UUID?
    var onLoadingChange: (Bool) -> Void
    var onCapture: (Result<UIImage, Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onLoadingChange: onLoadingChange)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.backgroundColor = .systemBackground
        webView.underPageBackgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.keyboardDismissMode = .onDrag
        #if DEBUG
        webView.isInspectable = true
        #endif

        context.coordinator.lastLoadID = loadID
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onCapture = onCapture
        coordinator.onLoadingChange = onLoadingChange

        if coordinator.lastLoadID != loadID {
            coordinator.lastLoadID = loadID
            webView.load(URLRequest(url: url))
        }

        if let captureToken, coordinator.lastCaptureToken != captureToken {
            coordinator.lastCaptureToken = captureToken
            coordinator.captureVisibleViewport(of: webView)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onCapture: (Result<UIImage, Error>) -> Void
        var onLoadingChange: (Bool) -> Void
        var lastLoadID: Int?
        var lastCaptureToken: UUID?

        init(
            onCapture: @escaping (Result<UIImage, Error>) -> Void,
            onLoadingChange: @escaping (Bool) -> Void
        ) {
            self.onCapture = onCapture
            self.onLoadingChange = onLoadingChange
        }

        /// Visible viewport only — not the scrolled document, and not the app window.
        ///
        /// `WKWebView` composites in a separate process, so `drawHierarchy` and
        /// `layer.render` often return a blank image. `takeSnapshot(with:)` is the
        /// supported API. `WKSnapshotConfiguration.rect` is in the web view's own
        /// coordinate space; `bounds` (origin at the view's top-left, size equal to
        /// what is on screen) is that visible area. `CGRect.null` is the same default.
        /// Leave `snapshotWidth` at 0 so the image width matches this rect.
        /// Do not switch the rect to `scrollView.contentSize` — that would stitch the
        /// whole page, which M1 does not do.
        func captureVisibleViewport(of webView: WKWebView) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let bounds = webView.bounds
                guard bounds.width > 1, bounds.height > 1 else {
                    self.deliver(.failure(VisibleCaptureError.webViewNotReady))
                    return
                }

                let configuration = WKSnapshotConfiguration()
                configuration.rect = CGRect(origin: .zero, size: bounds.size)
                configuration.afterScreenUpdates = true

                webView.takeSnapshot(with: configuration) { [weak self] image, error in
                    if let image {
                        self?.deliver(.success(image))
                    } else {
                        self?.deliver(.failure(error ?? VisibleCaptureError.emptyImage))
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
            notifyLoading(true)
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            notifyLoading(false)
        }

        func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError _: Error) {
            notifyLoading(false)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation _: WKNavigation!,
            withError _: Error
        ) {
            notifyLoading(false)
        }

        private func notifyLoading(_ isLoading: Bool) {
            DispatchQueue.main.async { [weak self] in
                self?.onLoadingChange(isLoading)
            }
        }

        private func deliver(_ result: Result<UIImage, Error>) {
            DispatchQueue.main.async { [weak self] in
                self?.onCapture(result)
            }
        }
    }
}

enum VisibleCaptureError: LocalizedError {
    case webViewNotReady
    case emptyImage

    var errorDescription: String? {
        switch self {
        case .webViewNotReady:
            return "页面还没有完成布局，请稍后再截取。"
        case .emptyImage:
            return "WebKit 没有返回图像。"
        }
    }
}
