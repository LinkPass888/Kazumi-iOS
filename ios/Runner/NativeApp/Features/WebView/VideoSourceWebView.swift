//
//  VideoSourceWebView.swift
//  Kazumi
//
//  1:1 翻译 lib/webview/video/{video_webview_controller,impl/video_webview_apple_impl}.dart。
//
//  用隐藏的 WKWebView 加载播放页，通过注入脚本嗅探真实媒体地址：
//   * 旧版解析器（useLegacyParser）：收集 iframe src，命中中转页时用
//     MediaUtility.decodeVideoSource 还原 m3u8/mp4；
//   * 新版解析器：拦截 fetch / XHR 响应体（#EXTM3U）、观察 video/source 标签；
//   * 加载结束 4 秒仍无结果时重试一次（与原实现的重试计数一致）。
//

import Foundation
import WebKit

struct VideoParserEvent: Sendable {
    var url: String
    var offset: Int
    var format: VideoSourceFormat
    /// 这一次 `load()` 的代号：换集 / 重试后旧页面迟到的回调靠它丢掉。
    var loadID: Int

    init(url: String, offset: Int = 0, format: VideoSourceFormat = .auto, loadID: Int = 0) {
        self.url = url
        self.offset = offset
        self.format = format
        self.loadID = loadID
    }
}

enum VideoSourceFormat: Sendable {
    case auto
    case hls
}

@MainActor
final class VideoSourceWebView: NSObject {
    private static let logBridge = "LogBridge"
    private static let legacyBridge = "JSBridgeDebug"
    private static let modernBridge = "VideoBridgeDebug"

    var onLog: ((String) -> Void)?
    var onVideoLoading: ((Bool) -> Void)?
    var onVideoURLParser: ((VideoParserEvent) -> Void)?
    /// 网页真的加载完了一次（`didFinish`，含它自己那次重试）。
    /// 下载解析靠它判断「完了却没有地址」——`load(url:)` 那个 await 在请求
    /// 刚发出时就返回了，拿它当「加载完」会让解析秒退（无地址就直接判失败）。
    var onPageLoaded: (() -> Void)?

    private var webView: WKWebView?
    private var hasInjectedScripts = false
    private var retryCount = 0
    private var offset = 0
    private var isIframeLoaded = false
    private var isVideoSourceLoaded = false
    private var useLegacyParser = false
    private var isLoading = false
    /// 每次 `load()` 自增：解析事件带上它，页面换掉之后旧事件就失效。
    private var loadGeneration = 0

    private let userAgent = HTTPHeaders.randomUserAgent()

    /// 规则登录留下的 Cookie 与 UA（LP 5447）：
    /// 播放页要登录才给真地址，这个 WebView 原来是一次性会话、自己的随机 UA，
    /// 登录态永远到不了这儿，页面停在登录墙，解析就一直「正在解析播放地址」。
    private var sessionCookies: [HTTPCookie] = []
    private var sessionUserAgent: String?
    /// 这条规则登录过就用 App 那个持久仓库：登录态不只在 Cookie 里，
    /// 播放页常常把 token 放在 localStorage / IndexedDB，一次性仓库是空的，
    /// 光塞 Cookie 页面还是当没登录（LP 5476 仍然卡在解析）。
    private var usesPersistentStore = false

    func initialize() async {
        guard webView == nil else { return }
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.websiteDataStore = usesPersistentStore ? .default() : .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let controller = WKUserContentController()
        for name in [Self.logBridge, Self.legacyBridge, Self.modernBridge] {
            controller.add(self, name: name)
        }
        controller.addUserScript(WKUserScript(
            source: VideoSourceWebView.callHandlerShim,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        controller.addUserScript(WKUserScript(
            source: VideoSourceWebView.removeLazyLoadingScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        ))
        configuration.userContentController = controller

        // 与原实现一致：图片与广告 document 直接阻断。
        if let rules = await WebViewContentRules.ruleList() {
            configuration.userContentController.add(rules)
        }

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.customUserAgent = userAgent
        webView = view
        emit("WebView: created")
    }

    /// 把某条规则的登录态交给解析用的 WebView：Cookie 按目标地址的域和路径筛，
    /// UA 用登录时那个（站点把 Cookie 绑 UA 时才对得上）。
    func configureSession(pluginName: String, url: String) {
        let store = PluginCookieStore.shared
        let wantsPersistent = store.hasCookies(pluginName: pluginName)
            || store.userAgent(for: pluginName) != nil
        if wantsPersistent != usesPersistentStore {
            usesPersistentStore = wantsPersistent
            // 仓库种类变了就得重建：配置定好之后改不了。
            if webView != nil { dispose() }
        }
        sessionCookies = store.cookies(pluginName: pluginName, url: url).compactMap { cookie in
            HTTPCookie(properties: [
                .name: cookie.name,
                .value: cookie.value,
                .domain: cookie.domain,
                .path: cookie.path
            ])
        }
        let storedUA = store.userAgent(for: pluginName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        sessionUserAgent = (storedUA?.isEmpty ?? true) ? nil : storedUA
    }

    @discardableResult
    func load(url: String, useLegacyParser: Bool, offset: Int = 0) async -> Int {
        await initialize()
        guard let webView else { return loadGeneration }
        // 第一次加载时没有旧页面，别先空跑一次 about:blank（会多等一次导航）。
        if webView.url != nil {
            await unloadPage()
        }
        loadGeneration &+= 1
        let generation = loadGeneration
        self.useLegacyParser = useLegacyParser
        if !hasInjectedScripts {
            injectScripts(useLegacyParser: useLegacyParser)
            hasInjectedScripts = true
        }
        retryCount = 0
        self.offset = offset
        isIframeLoaded = false
        isVideoSourceLoaded = false
        isLoading = true
        onVideoLoading?(true)
        guard let target = URL(string: url) else {
            emit("Invalid URL: \(url)")
            return generation
        }
        // 登录态要在导航之前就位：Cookie 先落进这个会话，UA 跟登录时一致。
        // 没有登录态的规则要显式回到原来那个随机 UA：不然换一条不用登录的规则，
        // 会继承上一条登录规则的 UA。
        webView.customUserAgent = sessionUserAgent ?? userAgent
        if !sessionCookies.isEmpty {
            let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
            for cookie in sessionCookies {
                await withCheckedContinuation { continuation in
                    cookieStore.setCookie(cookie) { continuation.resume() }
                }
            }
            emit("applied \(sessionCookies.count) login cookies")
        }
        emit("started loading: \(url)")
        webView.load(URLRequest(url: target))
        return generation
    }

    func unloadPage() async {
        guard let webView, let blank = URL(string: "about:blank") else { return }
        isLoading = false
        webView.load(URLRequest(url: blank))
    }

    /// 起播后把页面里的媒体全停掉，再把 WebView 拆了（LP 4938 Step 2）。
    ///
    /// 只跳一次 `about:blank` 不够：WKWebView 只要还活着，WebContent 子进程就还在，
    /// 它可以继续认领系统的 NowPlaying / 音频路由。所以停媒体、关演示、跳空白页、
    /// 拆视图一起做。
    func releaseMedia() {
        guard let webView else { return }
        if #available(iOS 15.0, *) {
            webView.pauseAllMediaPlayback()
            webView.closeAllMediaPresentations(completionHandler: nil)
        }
        Task { @MainActor in
            await self.unloadPage()
            self.dispose()
        }
    }

    func dispose() {
        if let webView {
            webView.stopLoading()
            webView.navigationDelegate = nil
            let controller = webView.configuration.userContentController
            for name in [Self.logBridge, Self.legacyBridge, Self.modernBridge] {
                controller.removeScriptMessageHandler(forName: name)
            }
            controller.removeAllUserScripts()
        }
        webView = nil
        hasInjectedScripts = false
    }
    // MARK: - 脚本

    private func injectScripts(useLegacyParser: Bool) {
        guard let webView else { return }
        let controller = webView.configuration.userContentController
        if useLegacyParser {
            emit("Adding JSBridgeDebug UserScript")
            controller.addUserScript(WKUserScript(
                source: Self.legacyParserScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false
            ))
        } else {
            emit("Adding VideoBridgeDebug UserScripts")
            controller.addUserScript(WKUserScript(
                source: Self.blobParserScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
            controller.addUserScript(WKUserScript(
                source: Self.videoTagParserScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false
            ))
        }
    }

    private func emit(_ message: String) {
        onLog?(message)
    }

    private func resolveVideoSource(_ message: String) {
        isVideoSourceLoaded = true
        isLoading = false
        onVideoLoading?(false)
        let resolved: String
        if message.contains("://") {
            resolved = message
        } else if let base = webView?.url, let url = URL(string: message, relativeTo: base) {
            resolved = url.absoluteURL.absoluteString
        } else {
            resolved = message
        }
        let event = VideoParserEvent(url: resolved, offset: offset, loadID: loadGeneration)
        onVideoURLParser?(event)
    }

    /// 旧版解析器：iframe src 可能是中转页，需要还原出真正的媒体地址。
    private func handleLegacyMessage(_ message: String) {
        emit("Callback received: \(message)")
        emit("If there is audio but no video, please report it to the rule developer.")
        let isCandidate = message.contains("http") || message.hasPrefix("//")
        guard isCandidate else { return }
        let blocked = ["googleads", "googlesyndication.com", "prestrain.html", "prestrain%2Ehtml", "adtrafficquality"]
        guard !blocked.contains(where: { message.contains($0) }) else { return }

        emit("Parsing video source \(message)")
        let encodedUrl = MediaUtility.encodeFull(message)
        let decoded = MediaUtility.decodeVideoSource(encodedUrl)
        guard decoded != encodedUrl else { return }
        isIframeLoaded = true
        isVideoSourceLoaded = true
        isLoading = false
        onVideoLoading?(false)
        emit("Loading video source \(decoded)")
        Task { @MainActor in await self.unloadPage() }
        onVideoURLParser?(VideoParserEvent(url: decoded, offset: offset, loadID: loadGeneration))
    }

    /// 新版解析器：接受绝对或相对地址，且尚未解析过。
    private func handleModernMessage(_ message: String) {
        emit("Callback received: \(message)")
        guard !message.isEmpty, !isVideoSourceLoaded else { return }
        emit("Loading video source: \(message)")
        isIframeLoaded = true
        Task { @MainActor in await self.unloadPage() }
        resolveVideoSource(message)
    }

    // MARK: - JS 资源

    /// InAppWebView 的 callHandler shim，使 Dart 端脚本可以原样复用。
    private static let callHandlerShim = """
    window.flutter_inappwebview = window.flutter_inappwebview || {};
    window.flutter_inappwebview.callHandler = function(name, ...args) {
      var value = args.length > 0 && args[0] != null ? String(args[0]) : '';
      try { window.webkit.messageHandlers[name].postMessage(value); } catch(e) {}
    };
    """

    private static let removeLazyLoadingScript = """
    function removeLazyLoading() {
      document.querySelectorAll('iframe[loading="lazy"]').forEach(iframe => {
        console.log('Removing lazy loading from:', iframe.src);
        iframe.removeAttribute('loading');
      });
    }
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', removeLazyLoading);
    } else {
      removeLazyLoading();
    }
    """

    private static let legacyParserScript = """
    window.flutter_inappwebview.callHandler('LogBridge', 'JSBridgeDebug script loaded: ' + window.location.href);
    var iframes = document.getElementsByTagName('iframe');
    window.flutter_inappwebview.callHandler('LogBridge', 'The number of iframe tags is ' + iframes.length);
    for (var i = 0; i < iframes.length; i++) {
        var iframe = iframes[i];
        var src = iframe.getAttribute('src');
        if (src) {
          window.flutter_inappwebview.callHandler('JSBridgeDebug', src);
        }
    }
    """

    private static let blobParserScript = """
    window.flutter_inappwebview.callHandler('LogBridge', 'BlobParser script loaded: ' + window.location.href);
    const _r_text = window.Response.prototype.text;
    window.Response.prototype.text = function () {
        return new Promise((resolve, reject) => {
            _r_text.call(this).then((text) => {
                resolve(text);
                if (text.trim().startsWith("#EXTM3U")) {
                    window.flutter_inappwebview.callHandler('LogBridge', 'M3U8 source found: ' + this.url);
                    window.flutter_inappwebview.callHandler('VideoBridgeDebug', this.url);
                }
            }).catch(reject);
        });
    }

    const _open = window.XMLHttpRequest.prototype.open;
    window.XMLHttpRequest.prototype.open = function (...args) {
        this.addEventListener("load", () => {
            try {
                let content = this.responseText;
                if (content.trim().startsWith("#EXTM3U")) {
                    window.flutter_inappwebview.callHandler('LogBridge', 'M3U8 source found: ' + args[1]);
                    window.flutter_inappwebview.callHandler('VideoBridgeDebug', args[1]);
                };
            } catch {}
        });
        return _open.apply(this, args);
    };
    """

    private static let videoTagParserScript = """
    window.flutter_inappwebview.callHandler('LogBridge', 'VideoTagParser script loaded: ' + window.location.href);
    function processVideoElement(video) {
      window.flutter_inappwebview.callHandler('LogBridge', 'Scanning video element for source URL');
      let src = video.getAttribute('src');
      if (src && src.trim() !== '' && !src.startsWith('blob:') && !src.includes('googleads')) {
        window.flutter_inappwebview.callHandler('LogBridge', 'VIDEO source found: ' + src);
        window.flutter_inappwebview.callHandler('VideoBridgeDebug', src);
        return;
      }
      const sources = video.getElementsByTagName('source');
      for (let source of sources) {
        src = source.getAttribute('src');
        if (src && src.trim() !== '' && !src.startsWith('blob:') && !src.includes('googleads')) {
          window.flutter_inappwebview.callHandler('LogBridge', 'VIDEO source found (source tag): ' + src);
          window.flutter_inappwebview.callHandler('VideoBridgeDebug', src);
          return;
        }
      }
    }

    document.querySelectorAll('video').forEach(processVideoElement);

    const _observer = new MutationObserver((mutations) => {
      window.flutter_inappwebview.callHandler('LogBridge', 'Scanning for video elements...');
      mutations.forEach(mutation => {
        if (mutation.type === 'attributes' && mutation.target.nodeName === 'VIDEO') {
          processVideoElement(mutation.target);
        }
        mutation.addedNodes.forEach(node => {
          if (node.nodeName === 'VIDEO') processVideoElement(node);
          if (node.querySelectorAll) {
            node.querySelectorAll('video').forEach(processVideoElement);
          }
        });
      });
    });

    _observer.observe(document.body, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['src']
    });
    """
}
// MARK: - WKNavigationDelegate

extension VideoSourceWebView: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        emit("started loading: \(webView.url?.absoluteString ?? "")")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        emit("loading completed: \(webView.url?.absoluteString ?? "")")
        onPageLoaded?()
        guard isLoading, !isVideoSourceLoaded else { return }
        // 与原实现一致：加载完成仍无结果时重试一次，避免 iframe 延迟注入。
        guard retryCount < 1 else { return }
        retryCount += 1
        let message = "No video source found, retrying (\(retryCount))"
        emit(message)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            // 不捕获参数里的 WKWebView（非 Sendable），统一走自身的 webView 引用。
            guard self.isLoading, !self.isVideoSourceLoaded, let target = self.webView?.url else { return }
            self.isLoading = true
            self.onVideoLoading?(true)
            self.webView?.load(URLRequest(url: target))
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        emit("WebView: error: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        emit("WebView: error: \(error.localizedDescription)")
    }
}

// MARK: - WKScriptMessageHandler

extension VideoSourceWebView: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let payload = message.body as? String ?? ""
        switch message.name {
        case Self.logBridge:
            // about:blank 的日志是卸载页面产生的噪声。
            guard !payload.contains("about:blank"), !payload.isEmpty else { return }
            emit(payload)
        case Self.legacyBridge:
            handleLegacyMessage(payload)
        case Self.modernBridge:
            handleModernMessage(payload)
        default:
            break
        }
    }
}
