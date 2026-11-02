import UIKit

/// Non-interactive labels drawn above the WKWebView.
///
/// Each box is stored in snapshot points plus the contentOffset at capture time.
/// A point in the web view's bounds maps to content as `contentOffset + point`,
/// so while the main scroll view moves, the label's on-screen origin is
/// `snapshotPoint + (captureOffset - currentOffset)`. They are not injected into
/// the page: manga sites use canvases, transforms, and nested scrollers, and a
/// script would not share Vision's coordinate space. WKWebView.scrollView.delegate
/// is left alone — replacing it breaks WebKit's own scrolling.
final class LiveTranslationOverlay: UIView {
    private var anchors: [LiveAnchor] = []
    private var labelIDs: [UUID] = []
    private var labels: [UUID: UILabel] = [:]
    private var contentOffset: CGPoint = .zero
    private var zoomScale: CGFloat = 1
    private var wantsVisible = false
    private var staleHidden = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = true
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setAnchors(_ anchors: [LiveAnchor], visible: Bool) {
        wantsVisible = visible
        let changed = anchors.count != self.anchors.count
            || zip(anchors, self.anchors).contains { lhs, rhs in
                lhs.id != rhs.id
                    || lhs.text != rhs.text
                    || lhs.zoomScale != rhs.zoomScale
                    || lhs.contentOffset != rhs.contentOffset
                    || lhs.rectInSnapshot != rhs.rectInSnapshot
            }
        self.anchors = anchors
        if changed {
            // A real new result, not a SwiftUI refresh of the same anchors.
            staleHidden = false
            labelIDs = anchors.map(\.id)
            rebuildLabels()
        }
        layoutLabels()
    }

    func clear() {
        anchors = []
        labelIDs = []
        labels.values.forEach { $0.removeFromSuperview() }
        labels.removeAll()
        staleHidden = false
        isHidden = true
    }

    /// Zoom invalidates the snapshot-to-content mapping until the next capture.
    func setStaleHidden(_ hidden: Bool) {
        staleHidden = hidden
        layoutLabels()
    }

    func sync(offset: CGPoint, zoom: CGFloat) {
        contentOffset = offset
        zoomScale = zoom
        layoutLabels()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutLabels()
    }

    private func rebuildLabels() {
        labels.values.forEach { $0.removeFromSuperview() }
        labels.removeAll()
        for anchor in anchors {
            let label = UILabel()
            label.text = anchor.text
            label.textAlignment = .center
            label.textColor = .black
            label.backgroundColor = UIColor.white.withAlphaComponent(0.9)
            label.numberOfLines = 4
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.3
            label.baselineAdjustment = .alignCenters
            label.layer.cornerRadius = 3
            label.layer.masksToBounds = true
            label.layer.borderWidth = 0.5
            label.layer.borderColor = UIColor.black.withAlphaComponent(0.35).cgColor
            label.isAccessibilityElement = false
            addSubview(label)
            labels[anchor.id] = label
        }
    }

    private func layoutLabels() {
        let show = wantsVisible && !staleHidden && !anchors.isEmpty
        isHidden = !show
        guard show else { return }

        let viewport = bounds.size
        let visible = bounds.insetBy(dx: -32, dy: -32)
        for anchor in anchors {
            guard let label = labels[anchor.id],
                  let rect = viewRect(for: anchor, viewport: viewport) else {
                labels[anchor.id]?.isHidden = true
                continue
            }
            label.isHidden = !visible.intersects(rect)
            label.frame = rect
            let fontSize = max(9, min(rect.height * 0.62, 22))
            label.font = .systemFont(ofSize: fontSize, weight: .semibold)
        }
    }

    private func viewRect(for anchor: LiveAnchor, viewport: CGSize) -> CGRect? {
        guard abs(zoomScale - anchor.zoomScale) < 0.02 else { return nil }
        guard anchor.snapshotSize.width > 1, anchor.snapshotSize.height > 1 else { return nil }
        let scaleX = viewport.width / anchor.snapshotSize.width
        let scaleY = viewport.height / anchor.snapshotSize.height
        let width = anchor.rectInSnapshot.width * scaleX
        let height = anchor.rectInSnapshot.height * scaleY
        let origin = CGPoint(
            x: anchor.rectInSnapshot.minX * scaleX + anchor.contentOffset.x - contentOffset.x,
            y: anchor.rectInSnapshot.minY * scaleY + anchor.contentOffset.y - contentOffset.y
        )
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }
}
