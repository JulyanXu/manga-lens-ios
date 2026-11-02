import Foundation
import OSLog
import SafariServices
import UIKit

/// Native half of the Safari extension. JavaScript is not allowed to call this
/// from a content script; `background.js` forwards the toolbar action.
///
/// The handler does not run Vision or Translation. Those stay in the app, which
/// can present the system language-pack sheet. This process only stores the
/// viewport JPEG and, when iOS allows it, asks the system to open Manga Lens.
class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private let logger = Logger(subsystem: "com.julyanxu.MangaLens", category: "safari")

    func beginRequest(with context: NSExtensionContext) {
        guard let item = context.inputItems.first as? NSExtensionItem,
              let userInfo = item.userInfo as? [String: Any],
              let message = userInfo[SFExtensionMessageKey] as? [String: Any]
        else {
            complete(context, payload: ["ok": false, "error": "没有收到扩展消息。"])
            return
        }

        switch message["type"] as? String {
        case "store":
            store(message, context: context)
        case "readResult":
            complete(context, payload: resultPayload())
        default:
            complete(context, payload: ["ok": false, "error": "不认识这个请求。"])
        }
    }

    private func store(_ message: [String: Any], context: NSExtensionContext) {
        let saved: SavedSafariJob
        switch makeJob(from: message) {
        case .success(let value):
            saved = value
        case .failure(let error):
            complete(context, payload: ["ok": false, "error": error.localizedDescription])
            return
        }

        let reply: [String: Any] = [
            "ok": true,
            "jobID": saved.jobID,
            "openURL": saved.url.absoluteString,
            "channel": saved.channel.rawValue,
        ]
        let gate = OpenGate()
        let finish: (Bool) -> Void = { opened in
            gate.run {
                var payload = reply
                payload["opened"] = opened
                self.complete(context, payload: payload)
            }
        }

        // `NSExtensionContext.open` is documented for Today and iMessage, not
        // for Safari web extensions. Try it, and always give the popup a link
        // the user can tap if the system ignores the call.
        DispatchQueue.main.async {
            context.open(saved.url, completionHandler: finish)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            finish(false)
        }
    }

    private func makeJob(from message: [String: Any]) -> Result<SavedSafariJob, SafariStoreError> {
        guard let pageURL = message["pageURL"] as? String,
              let cssWidth = doubleValue(message["cssWidth"]),
              let cssHeight = doubleValue(message["cssHeight"]),
              cssWidth > 20, cssHeight > 20, cssWidth < 4000, cssHeight < 6000
        else { return .failure(.badPage) }

        let language = allowedLanguage(message["language"] as? String)
        let title = message["title"] as? String ?? ""
        let anchors = decodeAnchors(message["anchors"])
        let jpeg: Data
        if let screenshot = message["screenshot"] as? String, !screenshot.isEmpty {
            guard screenshot.count < 8_000_000, let data = decodeImage(screenshot) else {
                return .failure(.badImage)
            }
            jpeg = data
        } else if let pieces = composePieces(message["pieces"], cssWidth: cssWidth, cssHeight: cssHeight, dpr: doubleValue(message["dpr"]) ?? 2) {
            jpeg = pieces
        } else {
            return .failure(.badImage)
        }

        return SafariJobStore.save(
            pageURL: pageURL,
            title: title,
            language: language,
            cssWidth: cssWidth,
            cssHeight: cssHeight,
            anchors: anchors,
            jpeg: jpeg
        )
    }

    private func composePieces(_ value: Any?, cssWidth: Double, cssHeight: Double, dpr: Double) -> Data? {
        let raw = pieceDictionaries(value)
        guard !raw.isEmpty else { return nil }
        var pieces: [(image: UIImage, rect: CGRect)] = []
        for entry in raw.prefix(6) {
            guard let dataURL = entry["dataURL"] as? String,
                  dataURL.count < 2_500_000,
                  let data = decodeImage(dataURL),
                  let image = UIImage(data: data),
                  let x = doubleValue(entry["x"]),
                  let y = doubleValue(entry["y"]),
                  let w = doubleValue(entry["w"]),
                  let h = doubleValue(entry["h"]),
                  w > 8, h > 8
            else { continue }
            pieces.append((
                image,
                CGRect(x: x, y: y, width: w, height: h)
            ))
        }
        guard !pieces.isEmpty else { return nil }
        logger.info("composing \(pieces.count, privacy: .public) safari images")
        return SafariPageImage.composeJPEG(
            pieces: pieces,
            cssWidth: cssWidth,
            cssHeight: cssHeight,
            scale: min(max(dpr, 1), 2)
        )
    }

    private func resultPayload() -> [String: Any] {
        guard let result = SafariJobStore.readResult() else {
            return [
                "ok": false,
                "error": "Manga Lens 还没写回译文。先打开 App，等这一屏翻译完再回来。",
            ]
        }
        let lines: [[String: Any]] = result.lines.map { line in
            [
                "text": line.text,
                "source": line.source,
                "x": line.x,
                "y": line.y,
                "w": line.w,
                "h": line.h,
            ]
        }
        let anchors: [[String: Any]] = result.anchors.map { anchor in
            [
                "id": anchor.id,
                "x": anchor.x,
                "y": anchor.y,
                "w": anchor.w,
                "h": anchor.h,
                "kind": anchor.kind,
            ]
        }
        return [
            "ok": true,
            "jobID": result.jobID,
            "pageURL": result.pageURL,
            "cssWidth": result.cssWidth,
            "cssHeight": result.cssHeight,
            "message": result.message,
            "lines": lines,
            "anchors": anchors,
        ]
    }

    private func complete(_ context: NSExtensionContext, payload: [String: Any]) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: payload]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    private func allowedLanguage(_ raw: String?) -> String {
        guard let raw, ["japanese", "korean", "english", "automatic"].contains(raw) else {
            return "japanese"
        }
        return raw
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            let double = number.doubleValue
            return double.isFinite ? double : nil
        }
        if let string = value as? String, let double = Double(string), double.isFinite {
            return double
        }
        return nil
    }

    private func decodeImage(_ value: String) -> Data? {
        let base64: String
        if let range = value.range(of: "base64,") {
            base64 = String(value[range.upperBound...])
        } else {
            base64 = value
        }
        return Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
    }

    private func pieceDictionaries(_ value: Any?) -> [[String: Any]] {
        if let typed = value as? [[String: Any]] { return typed }
        guard let items = value as? [Any] else { return [] }
        return items.compactMap { $0 as? [String: Any] }
    }

    private func decodeAnchors(_ value: Any?) -> [SafariAnchor] {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let decoded = try? JSONDecoder().decode([SafariAnchor].self, from: data)
        else { return [] }
        return decoded.filter { anchor in
            !anchor.id.isEmpty && anchor.w > 1 && anchor.h > 1
                && anchor.x.isFinite && anchor.y.isFinite
        }
    }
}

/// `completeRequest` crashes if it runs twice. The open callback and the
/// timeout can both fire.
private final class OpenGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: @escaping () -> Void) {
        lock.lock()
        let shouldRun = !done
        if shouldRun { done = true }
        lock.unlock()
        guard shouldRun else { return }
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }
}
