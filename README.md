# Manga Lens

iPhone 上的漫画网页即时翻译。当前做到 **M1 + M2 + M3**：

- 应用内浏览器打开任意网页，截取可视区域
- 设备上的 Vision 识别文字，系统 Translation 译成简体中文
- 滚动停稳或打开新页面后自动再跑一遍
- 译文可以盖在正在看的网页上，并跟着滚动走

工程是在没有 Xcode 的 Linux 环境里整理的，**没有编译，也没有打出 IPA**。仓库里也没有 Mac CI。请在 Mac 上用 Xcode 打开后第一次构建。

## 环境

- Mac
- Xcode 16 或更新（需要 iOS 18 SDK）
- iOS 18 及以上的 iPhone。翻译请用真机

部署目标是 **iOS 18**。M2 用的 `TranslationSession`（WWDC24 那套可编程翻译）从 iOS 18 才有。

## 在 Xcode 里打开并运行

1. 克隆这个仓库。
2. 双击打开根目录的 `MangaLens.xcodeproj`。不需要先装 XcodeGen。
3. 左侧选中 **MangaLens** target，打开 **Signing & Capabilities**。
4. 保持 **Automatically manage signing** 打开，**Team** 选你的 **Personal Team**（免费 Apple ID 即可）。
5. 如果报 Bundle Identifier 已被占用，把 `com.julyanxu.MangaLens` 改成只属于你的 ID。
6. 顶部方案选 **MangaLens**，设备选一台 **iOS 18+ 真机**。按 Run。
7. 默认打开 `https://www.apple.com`。地址栏可以换成任意网页，点「前往」。没写协议时会自动补 `https://`。任意 http/https 都可以，没有站点适配器。
8. 「原文」默认是 **日语**，也可以选韩语、英语或自动。目标语言固定是简体中文。
9. 「自动」默认开着。页面打开后，或你滚动停下来大约半秒，会自己截取、识别、翻译。「自动」关掉之后，只有「截取并翻译」会跑。
10. 「网页 / 截图」选显示方式。网页：中文盖在当前页面上，滚动时跟着走。截图：沿用 M2，结果打开预览页。缩略图随时可以打开最近一次截图。
11. 换了原文语言后，点「重新翻译」会忽略缓存重跑。Xcode 调试控制台会有尺寸、识别条数、缓存命中，例如：

   ```text
   [MangaLens] visible viewport 390 × 844 pt, 1170 × 2532 px, scale 3.0
   [MangaLens] OCR 12 regions, source japanese
   [MangaLens] translated 12 lines to zh-Hans, cache=1
   [MangaLens] cache hit hamming=0 entries=1
   ```

如果 Xcode 提示 “Update to recommended settings”，那是版本升级提示，接受即可，不是工程损坏。

可选：在 Mac 上安装 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 后，于仓库根目录执行 `xcodegen generate`，会按 `project.yml` 重新生成工程。日常直接打开已经提交的 `MangaLens.xcodeproj` 即可。

## 个人团队签名，大约 7 天

免费 Apple ID 的 Personal Team 装到真机上的描述文件大约 **7 天**后过期。过期后图标还在，点开却打不开。用同一台 Mac 打开这个工程再 Run 一次，就会重新签名，不需要付费的 Apple Developer Program。

模拟器不受这 7 天限制。

## 语言包

翻译在设备上完成，不经过自建服务器，也没有付费云端 OCR / MT。

第一次使用某种语言时，系统会弹出语言包下载。需要联网点允许。下载界面是系统画的。如果点了取消，状态栏会提示再点「重新翻译」。

日语、韩语、英语到简体中文走同一条管道。Vision 的 `recognitionLanguages` 换成对应语言，`TranslationSession.Configuration` 的 `source` 换成 `ja` / `ko` / `en`，目标始终是 `zh-Hans`。「自动」会在这三种语言里做文字识别，翻译时 `source` 传 `nil`。同一批翻译必须是同一种语言，混合页面更适合手动指定。默认是日语。

Vision 在模拟器里一般可以识别。`TranslationSession` **在模拟器里不可用**，请用真机看翻译、语言包和网页上的译文。模拟器里翻译失败，不代表工程没接上。

识别和翻译进行时，不主动弹出预览，避免挡住系统的语言包窗口。选了「截图」时，完成或失败才会打开预览。

如果 `LanguageAvailability` 报告这个方向 `.unsupported`，不会硬调翻译。

## M3 怎么自动跑

不会每一帧都识别。

- 主滚动：观察 `WKWebView.scrollView.contentOffset`，**不替换** scrollView 的 delegate（换掉会弄坏 WebKit 自己的滚动）。位移用来移动已经画好的标签，不触发 OCR。
- 相对上次翻译的位置移动超过 **12pt** 之后，再安静 **0.5 秒** 才截一张图。拖动和惯性滚动都会不断重置这个计时，所以只在停稳后跑一次。
- `didFinish` 导航后再等 **0.6 秒**（给图片一点时间画出来）走同一条路径。
- 页面里如果是内层 div 在滚，而不是 WebView 自己的 scrollView，会靠一段通用脚本在捕获阶段听 `scroll`，安静约 0.4 秒后通知应用。这不是某个网站的适配器，不读页面内容。
- 缩放超过约 1% 会先藏起标签（旧坐标对不上），停稳后再截。
- 开始跳转时立刻清掉旧标签，并作废还在跑的识别或翻译。后返回的结果如果世代号对不上，直接丢掉。
- 截图回调时如果 contentOffset 已经漂了 24pt 以上，这张图作废，等下一次停稳。

手动的「截取并翻译」不受「自动」开关影响。

## 缓存

每次准备 OCR 之前，先把截图缩成 9×8，做 64 位差值哈希（dHash）。

命中条件同时满足：

- 同一个页面 URL（去掉 fragment）
- 同一个原文语言
- 哈希的汉明距离 ≤ 4
- 距离大于 0 时，滚动位置还要落在大约 1.25 个视口以内；距离为 0 表示像素几乎一样，忽略偏移

命中就直接把上次的译文框套到这一次的 contentOffset 上，不再跑 Vision 和 Translation。「重新翻译」会跳过缓存。

缓存最多 **20** 条，最近使用的留在前面，多出来的从末尾丢掉。条目里是文字和框，不存整张图。

## 译文盖在哪

两种模式可以切换。

**网页叠加（默认）** 把标签画在 WebView 上面的一个不接收触摸的 `UIView` 里。OCR 框先落在截图像素上（和 M2 一样，Vision 归一化坐标、左下角原点，再翻成图片左上角的 point）。截图矩形就是当时 WebView 的 bounds，所以：

`内容坐标 = 截图时的 contentOffset + 框在视口里的位置`

滚动之后：

`屏幕位置 = 内容坐标 - 现在的 contentOffset`

标签因此跟着主滚动走。滚出屏幕的会被裁掉。新滚进屏幕的区域要等这次滚动停稳、重新截取之后才有字。缩放中先藏起来。

没有把标签插进页面 DOM。漫画站常用 canvas、transform 和内层滚动，脚本坐标和 Vision 对不齐，CSP 也可能拦住。内层滚动靠上面的脚本发现「该刷新了」，而不是靠脚本去画字。

**截图预览** 仍是 M2：中文画在刚截到的那张图上，用和 `scaledToFit` 相同的矩形对齐。适合对一下框准不准。

## M1 仍然在

- SwiftUI App 生命周期，只做 iPhone。
- 地址栏 +「前往」+ 占满剩余空间的 `WKWebView`。
- 任意 `http` / `https`。`Info.plist` 打开了 `NSAllowsArbitraryLoads`，没有 `WKAppBoundDomains`，也没有站点适配器。
- 截图只包含 WebView 当前可视区域，不是整页，也不是整个窗口。实现是 `WKWebView.takeSnapshot(with:)`，`rect` 为 WebView 的 `bounds`。

## 还没做

- 不做 Safari Web Extension。
- 不调用云端 OCR 或机器翻译。
- 不上架 App Store。
- 不给每个网站写选择器或翻页脚本。

## 目录

| 路径 | 作用 |
| --- | --- |
| `MangaLens.xcodeproj` | 直接用 Xcode 打开的工程 |
| `project.yml` | 同一工程的 XcodeGen 描述，部署目标 iOS 18 |
| `MangaLens/MangaLensApp.swift` | `@main` 入口 |
| `MangaLens/ContentView.swift` | 地址栏、语言、自动开关、显示方式、`translationTask` |
| `MangaLens/BrowserWebView.swift` | `WKWebView`、截图、停稳计时、内层滚动通知 |
| `MangaLens/LiveTranslationOverlay.swift` | 盖在网页上、随 contentOffset 移动的标签 |
| `MangaLens/PageTranslationCache.swift` | 视口描述、dHash、最多 20 条的 LRU |
| `MangaLens/SourceLanguage.swift` | 日语 / 韩语 / 英语 / 自动，以及语言包是否可装 |
| `MangaLens/TextRecognizer.swift` | Vision OCR，框换算到图片坐标 |
| `MangaLens/PageSession.swift` | 这一次截图的进度、译文和实时标签 |
| `MangaLens/SnapshotOverlayView.swift` | 截图预览里的中文叠加 |
| `MangaLens/Info.plist` | 允许加载任意 http(s) |
| `MangaLens/Assets.xcassets` | 图标和强调色 |
