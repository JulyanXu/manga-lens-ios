import SwiftUI
import UIKit
import WebKit

/// In-app browser surface. Loads any http(s) URL, snapshots only the visible
/// web view, and hosts the live translation labels above that web view.
struct BrowserWebView: UIViewRepresentable {
    let url: URL
    /// Bumps when the user hits Go, including a reload of the same URL.
    var loadID: Int
    /// New value requests one visible-viewport snapshot. A newer token drops the older callback.
    var captureToken: UUID?
    var liveAnchors: [LiveAnchor]
    var showsLiveOverlay: Bool
    var autoEnabled: Bool
    var onLoadingChange: (Bool) -> Void
    var onCapture: (ViewportCaptureResult) -> Void
    var onNavigationStarted: () -> Void
    var onViewportSettled: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> BrowserSurface {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        let script = WKUserScript(
            source: Self.innerScrollScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(script)
        configuration.userContentController.add(
            context.coordinator,
            contentWorld: .page,
            name: Coordinator.messageName
        )

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

        let surface = BrowserSurface(webView: webView)
        context.coordinator.attach(surface)
        context.coordinator.bind(
            onCapture: onCapture,
            onLoadingChange: onLoadingChange,
            onNavigationStarted: onNavigationStarted,
            onViewportSettled: onViewportSettled
        )
        context.coordinator.setAutoEnabled(autoEnabled)
        context.coordinator.lastLoadID = loadID
        webView.load(URLRequest(url: url))
        return surface
    }

    func updateUIView(_ surface: BrowserSurface, context: Context) {
        let coordinator = context.coordinator
        coordinator.bind(
            onCapture: onCapture,
            onLoadingChange: onLoadingChange,
            onNavigationStarted: onNavigationStarted,
            onViewportSettled: onViewportSettled
        )
        coordinator.setAutoEnabled(autoEnabled)

        let webView = surface.webView
        if coordinator.lastLoadID != loadID {
            coordinator.lastLoadID = loadID
            webView.load(URLRequest(url: url))
        }

        let scrollView = webView.scrollView
        surface.overlay.sync(offset: scrollView.contentOffset, zoom: scrollView.zoomScale)
        surface.overlay.setAnchors(liveAnchors, visible: showsLiveOverlay)

        if let captureToken, coordinator.lastCaptureToken != captureToken {
            coordinator.lastCaptureToken = captureToken
            coordinator.captureVisibleViewport(of: webView, token: captureToken)
        }
    }

    static func dismantleUIView(_ uiView: BrowserSurface, coordinator: Coordinator) {
        coordinator.teardown()
    }

    /// Generic listener for scrollers that are not `WKWebView.scrollView`.
    /// It only reports that scrolling settled. It does not read site-specific DOM.
    private static let innerScrollScript = """
    (function() {
      if (window.__mangaLensViewport) { return; }
      window.__mangaLensViewport = true;
      var timer = null;
      document.addEventListener('scroll', function() {
        if (timer) { clearTimeout(timer); }
        timer = setTimeout(function() {
          try {
            window.webkit.messageHandlers.mangaLensViewport.postMessage('settled');
          } catch (e) {}
        }, 400);
      }, true);
    })();
    """

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let messageName = "mangaLensViewport"
        /// Movement smaller than this does not start another OCR pass.
        static let settleThreshold: CGFloat = 12
        static let settleDelay: TimeInterval = 0.5

        var onCapture: (ViewportCaptureResult) -> Void = { _ in }
        var onLoadingChange: (Bool) -> Void = { _ in }
        var onNavigationStarted: () -> Void = {}
        var onViewportSettled: () -> Void = {}
        var lastLoadID: Int?
        var lastCaptureToken: UUID?

        private weak var surface: BrowserSurface?
        private var offsetObservation: NSKeyValueObservation?
        private var zoomObservation: NSKeyValueObservation?
        private var settleTimer: Timer?
        private var autoEnabled = false
        private var settleForced = false
        private var hasFiredSettle = false
        private var didApplyAuto = false
        private var offsetAtLastFire: CGPoint = .zero
        private var lastZoom: CGFloat = 1
        private var tornDown = false

        private var webView: WKWebView? { surface?.webView }
        private var overlay: LiveTranslationOverlay? { surface?.overlay }

        func bind(
            onCapture: @escaping (ViewportCaptureResult) -> Void,
            onLoadingChange: @escaping (Bool) -> Void,
            onNavigationStarted: @escaping () -> Void,
            onViewportSettled: @escaping () -> Void
        ) {
            self.onCapture = onCapture
            self.onLoadingChange = onLoadingChange
            self.onNavigationStarted = onNavigationStarted
            self.onViewportSettled = onViewportSettled
        }

        func attach(_ surface: BrowserSurface) {
            self.surface = surface
            let scrollView = surface.webView.scrollView
            lastZoom = scrollView.zoomScale
            offsetAtLastFire = scrollView.contentOffset
            overlay?.sync(offset: scrollView.contentOffset, zoom: scrollView.zoomScale)

            offsetObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                let offset = scrollView.contentOffset
                let zoom = scrollView.zoomScale
                self?.onMain { [weak self] in
                    self?.handleOffset(offset, zoom: zoom)
                }
            }
            zoomObservation = scrollView.observe(\.zoomScale, options: [.new]) { [weak self] scrollView, _ in
                let zoom = scrollView.zoomScale
                let offset = scrollView.contentOffset
                self?.onMain { [weak self] in
                    self?.handleZoom(zoom, offset: offset)
                }
            }
        }

        func setAutoEnabled(_ enabled: Bool) {
            // The first call is the initial value, before the page has loaded.
            // Later off→on should translate the page that is already on screen.
            let turnedOn = enabled && didApplyAuto && !autoEnabled
            didApplyAuto = true
            autoEnabled = enabled
            if turnedOn {
                scheduleSettle(force: true, delay: Self.settleDelay)
            } else if !enabled {
                settleTimer?.invalidate()
                settleTimer = nil
            }
        }

        func teardown() {
            guard !tornDown else { return }
            tornDown = true
            settleTimer?.invalidate()
            settleTimer = nil
            offsetObservation?.invalidate()
            zoomObservation?.invalidate()
            offsetObservation = nil
            zoomObservation = nil
            webView?.configuration.userContentController.removeScriptMessageHandler(
                forName: Self.messageName,
                contentWorld: .page
            )
            surface = nil
        }

        /// Visible viewport only — not the scrolled document, and not the app window.
        ///
        /// `WKWebView` composites in a separate process, so `drawHierarchy` and
        /// `layer.render` often return a blank image. `takeSnapshot(with:)` is the
        /// supported API. `WKSnapshotConfiguration.rect` is the web view's bounds,
        /// which is the on-screen area. `contentOffset` is recorded so labels can
        /// be re-anchored in scroll-view content coordinates. Do not use
        /// `scrollView.contentSize` here; that would capture the whole page.
        func captureVisibleViewport(of webView: WKWebView, token: UUID) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let bounds = webView.bounds
                guard bounds.width > 1, bounds.height > 1 else {
                    self.deliver(.failed(VisibleCaptureError.webViewNotReady), token: token)
                    return
                }

                let scrollView = webView.scrollView
                let offsetAtRequest = scrollView.contentOffset
                let zoomAtRequest = scrollView.zoomScale
                let viewportAtRequest = bounds.size
                let pageURL = canonicalPageURL(webView.url)

                let configuration = WKSnapshotConfiguration()
                configuration.rect = CGRect(origin: .zero, size: bounds.size)
                configuration.afterScreenUpdates = true

                webView.takeSnapshot(with: configuration) { [weak self] image, error in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        guard self.lastCaptureToken == token else { return }
                        let offsetNow = scrollView.contentOffset
                        let drifted = hypot(
                            offsetNow.x - offsetAtRequest.x,
                            offsetNow.y - offsetAtRequest.y
                        )
                        if drifted > 24 {
                            self.deliver(.skipped, token: token)
                            return
                        }
                        if let image {
                            let capture = ViewportCapture(
                                image: image,
                                pageURL: pageURL,
                                contentOffset: offsetAtRequest,
                                zoomScale: zoomAtRequest,
                                viewportSize: viewportAtRequest
                            )
                            self.deliver(.ready(capture), token: token)
                        } else {
                            self.deliver(.failed(error ?? VisibleCaptureError.emptyImage), token: token)
                        }
                    }
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let isMainFrame = navigationAction.targetFrame?.isMainFrame == true
            if isMainFrame {
                let next = canonicalPageURL(navigationAction.request.url)
                let current = canonicalPageURL(webView.url)
                let isReload = navigationAction.navigationType == .reload
                if isReload || (!next.isEmpty && next != current) {
                    // Subframe loads also hit didStart/didFinish. Only a real main-frame
                    // change should wipe labels that still belong to the page on screen.
                    overlay?.clear()
                    DispatchQueue.main.async { [weak self] in
                        self?.onNavigationStarted()
                    }
                }
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
            notifyLoading(true)
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            notifyLoading(false)
            scheduleSettle(force: true, delay: 0.6)
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

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == Self.messageName else { return }
            DispatchQueue.main.async { [weak self] in
                self?.scheduleSettle(force: true, delay: 0.15)
            }
        }

        private func handleOffset(_ offset: CGPoint, zoom: CGFloat) {
            overlay?.sync(offset: offset, zoom: zoom)
            guard autoEnabled else { return }
            let moved = hypot(offset.x - offsetAtLastFire.x, offset.y - offsetAtLastFire.y)
            if hasFiredSettle && moved < Self.settleThreshold { return }
            scheduleSettle(force: false, delay: Self.settleDelay)
        }

        private func handleZoom(_ zoom: CGFloat, offset: CGPoint) {
            guard abs(zoom - lastZoom) > 0.01 else { return }
            lastZoom = zoom
            overlay?.sync(offset: offset, zoom: zoom)
            overlay?.setStaleHidden(true)
            scheduleSettle(force: true, delay: Self.settleDelay)
        }

        private func scheduleSettle(force: Bool, delay: TimeInterval) {
            guard autoEnabled, !tornDown else { return }
            if force { settleForced = true }
            settleTimer?.invalidate()
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                self?.fireSettle()
            }
            settleTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        private func fireSettle() {
            settleTimer = nil
            guard autoEnabled, let webView else { return }
            let offset = webView.scrollView.contentOffset
            let moved = hypot(offset.x - offsetAtLastFire.x, offset.y - offsetAtLastFire.y)
            let force = settleForced || !hasFiredSettle
            settleForced = false
            if !force && moved < Self.settleThreshold { return }
            hasFiredSettle = true
            offsetAtLastFire = offset
            lastZoom = webView.scrollView.zoomScale
            onViewportSettled()
        }

        private func notifyLoading(_ isLoading: Bool) {
            DispatchQueue.main.async { [weak self] in
                self?.onLoadingChange(isLoading)
            }
        }

        private func deliver(_ result: ViewportCaptureResult, token: UUID) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lastCaptureToken == token else { return }
                self.onCapture(result)
            }
        }

        private func onMain(_ work: @escaping () -> Void) {
            if Thread.isMainThread {
                work()
            } else {
                DispatchQueue.main.async(execute: work)
            }
        }
    }
}

final class BrowserSurface: UIView {
    let webView: WKWebView
    let overlay = LiveTranslationOverlay()

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(webView)
        addSubview(overlay)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        webView.frame = bounds
        overlay.frame = bounds
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
