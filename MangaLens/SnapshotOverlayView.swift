import SwiftUI

/// Draws Simplified Chinese on top of the captured snapshot.
///
/// The labels stay in the snapshot's coordinate space, not on the live WKWebView.
/// The page can scroll the moment after capture, and WebKit draws off-process, so a
/// SwiftUI overlay on the web view would drift. Each chip is one Vision box, mapped
/// from image points through the same aspect-fit rect SwiftUI uses for the `Image`.
struct SnapshotOverlayView: View {
    let image: UIImage
    let items: [OverlayItem]

    var body: some View {
        GeometryReader { proxy in
            let canvas = proxy.size
            let display = aspectFitRect(content: image.size, in: canvas)
            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: canvas.width, height: canvas.height)

                ForEach(items) { item in
                    let box = map(item.rect, imageSize: image.size, display: display)
                    if box.width >= 8, box.height >= 8 {
                        TranslationChip(
                            text: item.text,
                            boxHeight: box.height,
                            isTranslation: item.isTranslation
                        )
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)
                    }
                }
            }
            .frame(width: canvas.width, height: canvas.height)
        }
    }
}

struct OverlayItem: Identifiable {
    let id: UUID
    let text: String
    let rect: CGRect
    let isTranslation: Bool
}

struct SnapshotResultSheet: View {
    @ObservedObject var session: PageSession
    @State private var showsTranslations = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let image = session.snapshot {
                    ZStack {
                        SnapshotOverlayView(image: image, items: overlayItems)
                        if session.isBusy {
                            progressCard
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .secondarySystemBackground))

                    Text("\(pointLabel(image)) · \(pixelLabel(image))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }

                Text(session.statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(session.phase == .failed ? Color.red : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                if session.phase == .done, !session.lines.isEmpty {
                    Toggle("在画面上显示译文", isOn: $showsTranslations)
                        .font(.subheadline)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(session.lines) { line in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.sourceText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(line.translatedText)
                                        .font(.body)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                    }
                    .frame(maxHeight: 220)
                }
            }
            .navigationTitle(session.safariContext == nil ? "译文" : "Safari 译文")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var overlayItems: [OverlayItem] {
        if session.phase == .done, showsTranslations {
            return session.lines.map {
                OverlayItem(id: $0.id, text: $0.translatedText, rect: $0.rect, isTranslation: true)
            }
        }
        if session.phase == .translating || session.phase == .failed {
            return session.recognized.map {
                OverlayItem(id: $0.id, text: $0.sourceText, rect: $0.rect, isTranslation: false)
            }
        }
        return []
    }

    private var progressCard: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text(session.statusMessage)
                .font(.subheadline)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 24)
    }
}

private struct TranslationChip: View {
    let text: String
    let boxHeight: CGFloat
    let isTranslation: Bool

    var body: some View {
        Text(text)
            .font(.system(size: max(9, min(boxHeight * 0.62, 22)), weight: .semibold))
            .foregroundStyle(isTranslation ? Color.black : Color.white)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.25)
            .lineLimit(5)
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                (isTranslation ? Color.white.opacity(0.9) : Color.black.opacity(0.72)),
                in: RoundedRectangle(cornerRadius: 3, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Color.black.opacity(0.35), lineWidth: 0.5)
            }
    }
}

private func aspectFitRect(content: CGSize, in container: CGSize) -> CGRect {
    guard content.width > 0, content.height > 0, container.width > 0, container.height > 0 else {
        return .zero
    }
    let scale = min(container.width / content.width, container.height / content.height)
    let size = CGSize(width: content.width * scale, height: content.height * scale)
    let origin = CGPoint(
        x: (container.width - size.width) / 2,
        y: (container.height - size.height) / 2
    )
    return CGRect(origin: origin, size: size)
}

private func map(_ rect: CGRect, imageSize: CGSize, display: CGRect) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
    return CGRect(
        x: display.minX + rect.minX * display.width / imageSize.width,
        y: display.minY + rect.minY * display.height / imageSize.height,
        width: rect.width * display.width / imageSize.width,
        height: rect.height * display.height / imageSize.height
    )
}

private func pointLabel(_ image: UIImage) -> String {
    "\(Int(image.size.width.rounded())) × \(Int(image.size.height.rounded())) pt"
}

private func pixelLabel(_ image: UIImage) -> String {
    let width = image.size.width * image.scale
    let height = image.size.height * image.scale
    return "\(Int(width.rounded())) × \(Int(height.rounded())) px"
}
