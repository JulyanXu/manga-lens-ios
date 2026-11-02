# Manga Lens

iPhone 上的漫画网页即时翻译。当前做到 **M1 + M2**：应用内浏览器截取可视区域，再用设备上的 Vision 识别文字，并用系统 Translation 译成简体中文，盖回截图里的原位置。

工程是在没有 Xcode 的 Linux 环境里整理的，**没有编译，也没有打出 IPA**。仓库里也没有 Mac CI。请在 Mac 上用 Xcode 打开后第一次构建。

## 环境

- Mac
- Xcode 16 或更新（需要 iOS 18 SDK）
- iOS 18 及以上的 iPhone 模拟器，或一台 iOS 18+ 的 iPhone

部署目标是 **iOS 18**，不是 iOS 17。M2 用的 `TranslationSession`（WWDC24 那套可编程翻译 API）从 iOS 18 才有。只做系统翻译弹层的话 iOS 17.4 就够，但气泡上要自己画译文，必须用 `translationTask` 拿 `TranslationSession`。

## 在 Xcode 里打开并运行

1. 克隆这个仓库。
2. 双击打开根目录的 `MangaLens.xcodeproj`。不需要先装 XcodeGen。
3. 左侧选中 **MangaLens** target，打开 **Signing & Capabilities**。
4. 保持 **Automatically manage signing** 打开，**Team** 选你的 **Personal Team**（免费 Apple ID 即可）。
5. 如果报 Bundle Identifier 已被占用，把 `com.julyanxu.MangaLens` 改成只属于你的 ID。
6. 顶部方案选 **MangaLens**，设备优先选一台 **iOS 18+ 的真机**（模拟器也能编译运行，见下面「语言包」）。按 Run。
7. 默认打开 `https://www.apple.com`。地址栏可以换成任意网页，点「前往」。没写协议时会自动补 `https://`。任意 http/https 都可以，没有站点适配器。
8. 「原文」默认是 **日语**。也可以选韩语、英语或自动。
9. 点「截取并翻译」。应用会：
   - 只截当前 `WKWebView` 看得见的区域
   - 用 Vision 找出文字和框
   - 用系统 Translation 译成简体中文
   - 打开「译文」页，把中文盖在这些框上
10. 换了原文语言后，点「重新翻译」即可，不用再截一次。Xcode 调试控制台会有尺寸、识别条数和翻译条数，例如：

   ```text
   [MangaLens] visible viewport 390 × 844 pt, 1170 × 2532 px, scale 3.0
   [MangaLens] OCR 12 regions, source japanese
   [MangaLens] translated 12 lines to zh-Hans
   ```

如果 Xcode 提示 “Update to recommended settings”，那是版本升级提示，接受即可，不是工程损坏。

可选：在 Mac 上安装 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 后，于仓库根目录执行 `xcodegen generate`，会按 `project.yml` 重新生成工程。日常直接打开已经提交的 `MangaLens.xcodeproj` 即可。

## 个人团队签名，大约 7 天

免费 Apple ID 的 Personal Team 装到真机上的描述文件大约 **7 天**后过期。过期后图标还在，点开却打不开。用同一台 Mac 打开这个工程再 Run 一次，就会重新签名，不需要付费的 Apple Developer Program。

模拟器不受这 7 天限制。

## 语言包

翻译在设备上完成，不经过自建服务器，也没有付费云端 OCR / MT。

第一次使用某种语言时，系统会弹出语言包下载。需要联网点允许。下载界面是系统画的，下载结束后会继续翻译。如果点了取消，页面上会提示再点「重新翻译」。

日语、韩语、英语到简体中文，走的是同一条管道：Vision 的 `recognitionLanguages` 换成对应语言，`TranslationSession.Configuration` 的 `source` 换成 `ja` / `ko` / `en`，目标始终是 `zh-Hans`。「自动」会在日语、韩语、英语之间做文字识别，翻译时 `source` 传 `nil`，让系统根据这批文字判断原文。同一批翻译必须是同一种语言，所以混合页面更适合手动选日语、韩语或英语。默认选中的是日语。

Vision 在模拟器里一般可以识别。`TranslationSession` 这套接口苹果标明 **在模拟器里不可用**，请用真机看翻译和语言包弹窗。模拟器里翻译失败，不代表工程没接上。

识别和翻译进行时，主界面只显示进度，不先盖住页面，这样系统语言包窗口才能弹出来。完成后才会打开「译文」。

如果 `LanguageAvailability` 报告这个方向 `.unsupported`，不会硬调翻译，而是直接说明这台系统不支持。

## 译文为什么盖在截图上，而不是盖在网页上

M2 把中文画在 **刚截到的那张图** 上，和每个 OCR 框对齐。

不盖在正在显示的 `WKWebView` 上。网页随时会滚动，WebKit 又是单独进程在画，SwiftUI 盖上去对不齐气泡。截图的坐标是固定的：Vision 给出归一化、左下角为原点的框，代码翻成图片左上角、以 point 为单位的矩形，再按「译文」页里 `scaledToFit` 的同一块区域缩放。开关「在画面上显示译文」可以拿掉中文，对照原图。翻译还没回来或失败时，框上会暂时显示原文，方便确认识别位置。

实现分别在：

- `MangaLens/BrowserWebView.swift`：`WKWebView.takeSnapshot(with:)`，`rect` 为 WebView 的 `bounds`
- `MangaLens/TextRecognizer.swift`：Vision `VNRecognizeTextRequest`（`.accurate`）
- `MangaLens/ContentView.swift`：`.translationTask` + `TranslationSession`
- `MangaLens/SnapshotOverlayView.swift`：按框画半透明圆角标签

## M1 仍然在

- SwiftUI App 生命周期，只做 iPhone。
- 地址栏 +「前往」+ 占满剩余空间的 `WKWebView`。
- 任意 `http` / `https`。`Info.plist` 打开了 `NSAllowsArbitraryLoads`，没有 `WKAppBoundDomains`，也没有站点适配器。
- 截图只包含 WebView 当前可视区域，不是整页，也不是整个窗口。

## M2 做了什么

- 截完就自动识别、翻译、打开叠了中文的预览。
- 日语 → 简体中文是默认路径，调用的是真的 Vision 和 Translation，不是占位字符串。
- 韩语、英语、自动识别接到同一条管道上，不是空按钮。
- 每个译文标签对应一个 OCR 框。
- 识别、下载语言包、翻译失败，都会在主界面和「译文」页写出来。

## 还没做

- 不在翻页、跳转或滚动停止时自动截图（那是 M3）。
- 不做 Safari Web Extension。
- 不调用云端 OCR 或机器翻译。
- 不上架 App Store。

## 路线图

### M3 — 翻页时自动做

监听 WebView 导航或页面停稳，用户翻到新的一页时自动走现在这条「截取 → 识别 → 翻译」，不用每次点按钮。

## 目录

| 路径 | 作用 |
| --- | --- |
| `MangaLens.xcodeproj` | 直接用 Xcode 打开的工程 |
| `project.yml` | 同一工程的 XcodeGen 描述，部署目标 iOS 18 |
| `MangaLens/MangaLensApp.swift` | `@main` 入口 |
| `MangaLens/ContentView.swift` | 地址栏、语言选择、截取并翻译、`translationTask` |
| `MangaLens/BrowserWebView.swift` | `WKWebView` 和可视区域截图 |
| `MangaLens/SourceLanguage.swift` | 日语 / 韩语 / 英语 / 自动，以及语言包是否可装 |
| `MangaLens/TextRecognizer.swift` | Vision OCR，框换算到图片坐标 |
| `MangaLens/PageSession.swift` | 这次截图的进度和译文 |
| `MangaLens/SnapshotOverlayView.swift` | 把简体中文盖到截图的 OCR 框上 |
| `MangaLens/Info.plist` | 允许加载任意 http(s) |
| `MangaLens/Assets.xcassets` | 图标和强调色 |
