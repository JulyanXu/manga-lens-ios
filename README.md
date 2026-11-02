# Manga Lens

iPhone 上的漫画网页即时翻译。这个仓库目前只做 **里程碑 M1**：应用内浏览器，以及截取 `WKWebView` 当前看得见的那一块画面。

工程是在没有 Xcode 的环境里整理的，**没有编译，也没有打出 IPA**。请在 Mac 上用 Xcode 打开后第一次构建。

## 环境

- Mac
- Xcode 16 或更新（带 iOS 17 SDK；更新的 Xcode 也可以）
- iOS 17 及以上的 iPhone 模拟器，或一台 iOS 17+ 的 iPhone

## 在 Xcode 里打开并运行

1. 克隆这个仓库。
2. 双击打开根目录的 `MangaLens.xcodeproj`。不需要先装 XcodeGen，也不用改工程格式。
3. 左侧选中 **MangaLens** target，打开 **Signing & Capabilities**。
4. 保持 **Automatically manage signing** 打开，**Team** 选你的 **Personal Team**（免费 Apple ID 即可）。
5. 如果报 Bundle Identifier 已被占用，把 `com.julyanxu.MangaLens` 改成只属于你的 ID，例如 `com.yourname.MangaLens`。
6. 顶部方案选 **MangaLens**，设备选一台 iPhone 模拟器，或接上已信任的 iPhone，按 Run。
7. 应用打开后默认进入 `https://www.apple.com`。地址栏可以换成任意网页，点「前往」。没写 `http://` 或 `https://` 时会自动补 `https://`。
8. 点「截取可视区域」。应用会记下这张图，弹出预览，地址栏下方也会写出尺寸。Xcode 调试控制台同时有一行日志，例如：

   ```text
   [MangaLens] visible viewport 390 × 844 pt, 1170 × 2532 px, scale 3.0
   ```

如果 Xcode 提示 “Update to recommended settings”，那是版本升级提示，接受即可，不是工程损坏。

可选：在 Mac 上安装 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 后，于仓库根目录执行 `xcodegen generate`，会按 `project.yml` 重新生成 `MangaLens.xcodeproj`。日常直接打开已经提交的工程即可。这次提交的工程文件是按 `project.yml` 对齐手写的，不是在本机跑 XcodeGen 生成的。

## 个人团队签名，大约 7 天

免费 Apple ID 的 Personal Team 装到真机上的描述文件大约 **7 天**后过期。过期后图标还在，点开却打不开。用同一台 Mac 打开这个工程再 Run 一次，就会重新签名，不需要付费的 Apple Developer Program。

模拟器不受这 7 天限制。

## M1 做了什么

- SwiftUI App 生命周期，部署目标 iOS 17，只做 iPhone。
- 主界面是地址栏、「前往」，下面一整块 `WKWebView`。
- 可以打开任意 `http` / `https` 网址。没有按网站写适配器，也不是 Safari 扩展。
- `Info.plist` 里打开了 `NSAppTransportSecurity` / `NSAllowsArbitraryLoads`，这样 `http://` 页面也能进。没有设置 `WKAppBoundDomains`。
- 「截取可视区域」只截 **这个 WKWebView 当前的可视范围**。不是整页长图，也不是整个 App 窗口（地址栏不在图里）。
- 实现用的是 `WKWebView.takeSnapshot(with:)`。`WKSnapshotConfiguration.rect` 设成 WebView 的 `bounds`。WebKit 在单独进程里画页面，对 WKWebView 调用 `drawHierarchy` 经常是一张空白图，所以用系统这个 API。说明写在 `MangaLens/BrowserWebView.swift`。
- 截图留在内存里：按钮旁边有缩略图，点开是预览 sheet，上面标着点尺寸和像素尺寸。控制台用 `print` 和 `Logger`（子系统 `com.julyanxu.MangaLens`）各记一行。

## M1 不做

- 不做 Vision OCR，不认识气泡里的字。
- 不做 Apple Translation，不把日文翻成中文。
- 不在气泡上盖中文。
- 不在翻页或跳转时自动截图。
- 不调用付费或云端 OCR / 翻译接口。
- 不做站点爬虫，也不做站点专用适配器。
- 不做 Safari Web Extension。

## 路线图

### M2 — 识别、翻译、叠到画面上

拿 M1 截到的可视区域做 Vision 文字识别，再用系统 Translation 框架翻译，把中文盖回对应位置。仍然不把图上传到第三方。

### M3 — 翻页时自动做

监听 WebView 的导航或页面停稳，用户翻到新的一页时自动走「截取 → 识别 → 翻译」，不用每次点按钮。

## 目录

| 路径 | 作用 |
| --- | --- |
| `MangaLens.xcodeproj` | 直接用 Xcode 打开的工程 |
| `project.yml` | 同一工程的 XcodeGen 描述 |
| `MangaLens/MangaLensApp.swift` | `@main` 入口 |
| `MangaLens/ContentView.swift` | 地址栏、截取按钮、预览 |
| `MangaLens/BrowserWebView.swift` | `WKWebView` 和可视区域截图 |
| `MangaLens/Info.plist` | 允许加载任意 http(s) |
| `MangaLens/Assets.xcassets` | 图标和强调色 |
