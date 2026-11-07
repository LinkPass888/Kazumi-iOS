//
//  PlayerController.swift
//  Kazumi
//
//  对应 lib/pages/video/video_controller.dart + player_playback_controller.dart 的原生子集：
//   * 选源进入时先按规则抓取章节（规则引擎已有实现），得到分集页面地址；
//   * 分集页面交给隐藏的 VideoSourceWebView 嗅探真实媒体地址；
//   * 最终媒体地址附带规则要求的 UA / Referer，交给 KSPlayer 播放。
//

import Foundation
import Observation

@MainActor
@Observable
final class PlayerController {
    /// 播放阶段，UI 据此展示加载 / 错误 / 就绪。
    enum Phase: Equatable {
        case idle
        /// 从观看历史进入、没有带播放源时，先按记录里的规则名检索条目。
        case searchingSource
        case resolvingChapters
        case parsingMedia
        case ready
        case failed(String)
    }

    /// 弹幕加载状态。
    enum DanmakuStatus: Equatable {
        case idle
        case loading
        case ready
        case empty
        case unavailable
        case failed
    }

    enum DanmakuManualResult: Equatable {
        case loaded(Int)
        case empty
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var roads: [Road] = []
    private(set) var selectedRoad = 0
    private(set) var episodes: [String] = []
    private(set) var currentEpisode = 1
    private(set) var playbackURL: String?
    private(set) var referer: String?
    private(set) var userAgent: String?
    private(set) var logLines: [String] = []

    /// 当前这一集的弹幕与加载状态（对应 PlayerDanmakuController）。
    /// AniSkip 查到的片头 / 片尾时间轴（对应 main 的 `PlayerController.skipSegments`）。
    private(set) var skipSegments: SkipSegments = .empty
    /// 上次查过时间轴的媒体地址：同一个地址只查一次。
    private var skipSegmentsURL: String?
    private(set) var danmakuComments: [DanmakuComment] = []
    private(set) var danmakuStatus: DanmakuStatus = .idle
    private(set) var danmakuMessage: String?

    let bangumiID: Int
    private(set) var source: PlaybackSource?
    private let plugins: PluginsController
    /// 观看历史存储：仅用于「从历史进入、路由没带播放源」时重建播放源。
    private let library: LibraryStore?
    private let engine = RuleEngine()
    private let webView = VideoSourceWebView()
    private var cancelToken = RuleCancelToken()
    /// 解析的看门狗：页面加载完却一直没拿到地址时，别让圈一直转（LP 5465）。
    private var parseWatchdog: Task<Void, Never>?
    /// 第几次起播：换集 / 重试时自增，旧的章节请求和解析结果一律丢掉。
    private var startGeneration = 0
    /// 当前这次 WebView 解析的代号，和 `VideoParserEvent.loadID` 对齐。
    private var activeParseLoadID = 0

    /// 上次走的线路（历史里记的），以及这次进播放器是不是「接着看」。
    private var resumeRoad: Int?
    private var resumeFromHistory: Bool
    /// 这一集的 WebView 是不是已经放掉了（起播后）。换集会清零，下一集再放一次。
    private var didReleaseWebView = false
    /// 从历史卡片进来时带的那条规则名：重建播放源和取续播位置都按它取。
    let resumeRule: String?
    /// 离线播放入口（Colo 5174）：按集号取本地文件。有就用本地那份，
    /// 跳过网页解析；没有就走原流程。章节列表仍然照常抓，
    /// 所以选集、连播、弹幕、观看历史都还在。
    private let localFile: ((Int) -> URL?)?
    /// 本地已下好的集号（升序）。在线列表抓不到时，用它退回「只显示已下载的」。
    private let downloadedNumbers: (() -> [Int])?
    /// 这份选集是不是「在线列表没抓到、只剩本地」那一份（Colo v3 第 9 条）。
    private(set) var isOfflineEpisodeList = false
    /// 本集加进了下载但还没下完（Camo 5208）：这时走在线解析，画面要说一句
    /// 「本集下载未完成，正在尝试在线播放」。起播成功或失败就收。
    private(set) var isEpisodeIncomplete = false
    private let episodeIncomplete: ((Int) -> Bool)?

    init(
        bangumiID: Int,
        episode: Int,
        source: PlaybackSource?,
        plugins: PluginsController,
        library: LibraryStore? = nil,
        resumeRoad: Int? = nil,
        resumeFromHistory: Bool = false,
        resumeRule: String? = nil,
        localFile: ((Int) -> URL?)? = nil,
        downloadedNumbers: (() -> [Int])? = nil,
        episodeIncomplete: ((Int) -> Bool)? = nil
    ) {
        self.bangumiID = bangumiID
        self.source = source
        self.currentEpisode = max(1, episode)
        self.resumeRoad = resumeRoad
        self.resumeFromHistory = resumeFromHistory
        self.resumeRule = resumeRule
        self.plugins = plugins
        self.library = library
        self.localFile = localFile
        self.downloadedNumbers = downloadedNumbers
        self.episodeIncomplete = episodeIncomplete
        webView.onLog = { [weak self] line in
            self?.appendLog(line)
        }
        webView.onVideoURLParser = { [weak self] event in
            self?.handleParsedMedia(event)
        }
    }

    /// 播放该集：先抓章节（只做一次），再解析媒体地址。
    func start() async {
        startGeneration &+= 1
        let generation = startGeneration
        // 新一次起播还没拿到新的 loadID 之前，先把旧代号置空，旧页面的回调一律丢掉。
        activeParseLoadID = -1
        // 上一次还在跑的章节 / 搜索请求先取消；WebView 由新的 load() 换页。
        cancelToken.cancel()
        cancelToken = RuleCancelToken()
        // 新的一次加载：WebView 可能要再用（换集 / 重试），放开「已释放」这个记号。
        didReleaseWebView = false
        // 从观看历史进入时路由只带 bangumiID / 集数，没有播放源；
        // 先按历史里的规则名把播放源重建出来，再走正常的起播流程。
        if source == nil {
            await resolveSourceFromHistory()
            guard generation == startGeneration else { return }
        }
        guard let source else {
            phase = .failed(String(localized: "没找到这部剧的播放源"))
            return
        }
        guard let plugin = plugins.plugin(named: source.pluginName) else {
            phase = .failed(String(localized: "规则「\(String(describing: source.pluginName))」已不存在，请重新选择"))
            return
        }
        guard generation == startGeneration else { return }

        // 本集加进了下载但还没下完（Camo 5208）：这一轮要走在线解析，
        // 画面得说一句。本地文件能用时下面会把它收掉。
        // 放在这里是因为「列表本来就有」和「要现去抓列表」两条路都要它。
        isEpisodeIncomplete = (episodeIncomplete?(currentEpisode) ?? false)
            && localFile?(currentEpisode) == nil

        if let direct = source.directMediaURL, !direct.isEmpty {
            applyHeaders(plugin: plugin)
            playbackURL = direct
            phase = .ready
            await loadDanmaku()
            return
        }

        if episodes.isEmpty {
            phase = .resolvingChapters
            cancelToken = RuleCancelToken()
            do {
                let trace = try await engine.queryChapters(
                    RuleExecutionConfig(plugin: plugin),
                    source: source.detailURL,
                    cancelToken: cancelToken
                )
                guard generation == startGeneration else { return }
                roads = trace.roads
                applyStartPoint(roads: trace.roads)
                if episodes.isEmpty {
                    isEpisodeIncomplete = false
                    failed(String(localized: "该播放源没有解析到剧集"))
                    return
                }
            } catch {
                guard generation == startGeneration else { return }
                // 抓不到章节（片源挂了、地址变了）时，只要本地有这一集的文件，
                // 照样能放——离线播放不能因为在线那头坏了就跟着废掉。
                if let local = localFile?(currentEpisode) {
                    appendLog(String(localized: "解析剧集失败，改用本地文件：\(String(describing: error.localizedDescription))"))
                    applyHeaders(plugin: plugin)
                    // 在线列表拿不到：选集退回这份下载记录，已下载的集列出来能点，
                    // 其余留空格子由界面画灰（Colo v3 第 9 条）。
                    let numbers = (downloadedNumbers?() ?? []).sorted()
                    if let last = numbers.last, last > 0 {
                        var padded = Array(repeating: "", count: last)
                        for number in numbers where number <= last {
                            padded[number - 1] = "local://\(number)"
                        }
                        episodes = padded
                        isOfflineEpisodeList = true
                    }
                    playbackURL = local.absoluteString
                    phase = .ready
                    await loadDanmaku()
                    return
                }
                // 系统给的英文错误串（「The data couldn't be read…」之类）不往用户脸上贴：
                // 界面上说人话，原始原因写进运行日志。
                appendLog(String(localized: "解析剧集失败：\(String(describing: error.localizedDescription))"))
                failed(String(localized: "解析剧集失败，换条线路或换个源试试"))
                return
            }
        }

        guard episodes.indices.contains(currentEpisode - 1) else {
            phase = .failed(String(localized: "第 \(String(describing: currentEpisode)) 集不存在"))
            return
        }
        let target = episodes[currentEpisode - 1]
        guard !target.isEmpty else {
            failed(String(localized: "该集没有播放地址"))
            return
        }
        guard generation == startGeneration else { return }

        applyHeaders(plugin: plugin)
        // 本地已经下好了就用本地那份：不解析、不走网页，画质也稳定（Colo 5174）。
        if let local = localFile?(currentEpisode) {
            isEpisodeIncomplete = false
            playbackURL = local.absoluteString
            phase = .ready
            await loadDanmaku()
            return
        }
        phase = .parsingMedia
        startParseWatchdog()
        // 登录态交给解析页（LP 5450）：页面里那一步拿地址要登录，
        // 这个 WebView 原先是一次性会话，Cookie 到不了，就一直卡在解析。
        webView.configureSession(pluginName: plugin.name, url: target)
        let loadID = await webView.load(url: target, useLegacyParser: plugin.useLegacyParser)
        guard generation == startGeneration else { return }
        activeParseLoadID = loadID
    }

    /// 进播放页定「从第几集、第几条线路起」（对应 main `video_page._initOnlineMode`）。
    ///
    /// 续播（从详情页「开始观看」进来）：线路和集数都要在范围内才用——线路超出、
    /// 或者集数超过那条线路的长度，就整条记录作废，从第一集、第一条线路起。
    /// 不夹到最后一集：源常把一集切成几段，夹过去多半落在片尾（Ato 4843）。
    ///
    /// 用户点的那一集（历史页、切集）不算续播：这条源没那么多集时夹到最后一集，
    /// 免得一进来就「第 N 集不存在」。
    private func applyStartPoint(roads: [Road]) {
        let road = resumeRoad ?? 0
        if resumeFromHistory {
            if roads.indices.contains(road), currentEpisode >= 1,
               currentEpisode <= roads[road].data.count {
                selectedRoad = road
                episodes = roads[road].data
            } else {
                selectedRoad = 0
                episodes = roads.first?.data ?? []
                currentEpisode = 1
            }
        } else {
            selectedRoad = 0
            episodes = roads.first?.data ?? []
            currentEpisode = min(currentEpisode, max(1, episodes.count))
        }
    }

    /// 切线路后直接起播：原版只切列表、等用户再点集数，这里按本批要求自动接上。
    func selectRoad(_ index: Int) async {
        guard roads.indices.contains(index) else { return }
        selectedRoad = index
        episodes = roads[index].data
        currentEpisode = min(currentEpisode, max(1, episodes.count))
        phase = .idle
        playbackURL = nil
        resetDanmaku()
        resetSkipSegments()
        await start()
    }

    func selectEpisode(_ number: Int) async {
        currentEpisode = max(1, number)
        phase = .idle
        playbackURL = nil
        resetDanmaku()
        resetSkipSegments()
        await start()
    }

    func retry() async {
        parseWatchdog?.cancel()
        parseWatchdog = nil
        phase = .idle
        playbackURL = nil
        resetDanmaku()
        resetSkipSegments()
        await start()
    }

    /// AniSkip 片头片尾时间轴。
    ///
    /// 跟 main 的 `_maybeLoadSkipSegments` 同一套判据：只在设置开着、在线
    /// 播放、同一个地址只查一次、且播放器已经拿到片长（≥30 秒）时才查——
    /// AniSkip 按片长匹配，时长太短查出来的段对不上压制版本。
    func maybeLoadSkipSegments(duration: Double, enabled: Bool) {
        guard enabled, !isLocalPlayback else { return }
        guard let url = playbackURL, !url.isEmpty, skipSegmentsURL != url else { return }
        guard bangumiID > 0, currentEpisode > 0, duration >= 30 else { return }
        skipSegmentsURL = url
        let bangumiID = bangumiID
        let episode = currentEpisode
        Task { [weak self] in
            let segments = await AniSkipClient.lookup(
                bangumiID: bangumiID,
                episode: episode,
                duration: duration
            )
            guard self?.playbackURL == url else { return }
            self?.skipSegments = segments
            KazumiLogBuffer.player(
                segments.isEmpty
                    ? String(localized: "AniSkip: 这集没有片头片尾")
                    : String(localized: "AniSkip: 片头片尾已加载")
            )
        }
    }

    /// 本地文件（`file://`）不查 AniSkip：时间轴是按在线片源测的。
    private var isLocalPlayback: Bool {
        playbackURL?.hasPrefix("file://") ?? false
    }

    func stop() {
        startGeneration &+= 1
        activeParseLoadID = 0
        parseWatchdog?.cancel()
        parseWatchdog = nil
        cancelToken.cancel()
        webView.dispose()
    }

    /// 起播稳定后把嗅探用的 WebView 放掉（LP 4938 Step 2）。
    ///
    /// 地址已经解析到、mpv 已经在放，那个隐藏页面就没有存在的必要了：WKWebView 只要
    /// 还活着，WebContent 子进程就还在，它跟 mpv、画中画控制器同时向系统认领媒体路由。
    /// 拆掉不影响嗅探——下次要解析（换集 / 重试）时 `load()` 会自己重建一个。
    func releaseSourceWebView() {
        guard !didReleaseWebView else { return }
        didReleaseWebView = true
        KazumiLogBuffer.player("WebView 已释放（起播稳定后）")
        webView.releaseMedia()
    }

    // MARK: - 内部

    /// 从观看历史重建播放源。
    ///
    /// 历史里只存了规则名（`WatchRecord.sourceRuleName`），没有详情页地址，
    /// 因此先用规则搜一次番剧名，拿第一条（优先同名）结果的 `src` 当详情页。
    /// 失败就保持 `source` 为空，由 `start()` 报「没找到这部剧的播放源」。
    private func resolveSourceFromHistory() async {
        // 按卡片上那一条规则取（Fuck 4875）：同一部番在好几个源下各有一份记录，
        // 按番剧号取「最新那份」会拿错源——卡片写着 B 源，放出来是 A 源。
        guard let library else { return }
        let record = resumeRule.flatMap { library.record(for: bangumiID, pluginName: $0) }
            ?? library.record(for: bangumiID)
        guard let record else { return }
        let keyword = record.bangumiName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        // 记录的规则被删了就退回第一条已装规则，总比直接判死强。
        guard let plugin = plugins.plugin(named: record.sourceRuleName) ?? plugins.pluginList.first else {
            return
        }

        phase = .searchingSource
        appendLog(String(localized: "正在查找播放源：\(String(describing: plugin.name))"))
        do {
            let trace = try await engine.search(
                RuleExecutionConfig(plugin: plugin),
                keyword: keyword,
                cancelToken: cancelToken
            )
            let items = trace.response.data
            // 只认同名条目，且必须唯一：宁可播不了，也不能播错番。
            // 同名多条说明无法判定是哪一部，同样放弃。
            let matches = items.filter { $0.name == record.bangumiName }
            guard matches.count == 1, let item = matches.first else {
                appendLog(
                    matches.isEmpty
                        ? String(localized: "没有找到与「\(String(describing: keyword))」同名的条目")
                        : String(localized: "「\(String(describing: keyword))」有 \(String(describing: matches.count)) 个同名条目，无法确定播放哪一部")
                )
                return
            }
            source = PlaybackSource(
                pluginName: plugin.name,
                itemName: item.name,
                // 原样传 src，理由同选源面板：接口模式要的是 vod_id，不是网址。
                detailURL: item.src,
                directMediaURL: MediaUtility.isMediaURL(item.src) ? item.src : nil
            )
        } catch {
            appendLog(String(localized: "查找播放源失败：\(String(describing: error.localizedDescription))"))
        }
    }

    private func applyHeaders(plugin: Plugin) {
        // 登录过就用登录那页的 UA：站点常把登录 Cookie 绑 UA，
        // 播放和解析拿规则里另写的 UA 过去，Cookie 会被当成别人的（LP 5450）。
        let loginUA = PluginCookieStore.shared.userAgent(for: plugin.name)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let loginUA, !loginUA.isEmpty {
            userAgent = loginUA
        } else {
            userAgent = plugin.userAgent.isEmpty ? HTTPHeaders.randomUserAgent() : plugin.userAgent
        }
        let refererValue = plugin.referer.isEmpty ? plugin.baseUrl : plugin.referer
        referer = refererValue.isEmpty ? nil : refererValue
    }

    /// 失败提示统一走这里（LP 5465）：带登录 Cookie 的规则，Cookie 会过期，
    /// 出问题时把人往「网络 / 规则 / 登录」三处引，别只说「解析失败」。
    private func failed(_ reason: String) {
        var text = reason
        let hint = String(localized: "请检查网络、规则或 Cookie。")
        // 只说一遍：调用方自己带了这句就不再重复（LP 5476 看到两遍）。
        if let pluginName = source?.pluginName,
           PluginCookieStore.shared.hasCookies(pluginName: pluginName),
           !text.contains(hint) {
            text += "\n" + hint
        }
        phase = .failed(text)
    }

    /// 媒体地址要带的 Cookie 头：这条规则登录过才有，按媒体地址的域和路径筛。
    func playbackCookieHeader(for urlString: String) -> String? {
        guard let pluginName = source?.pluginName else { return nil }
        let header = PluginCookieStore.shared.cookieHeader(pluginName: pluginName, url: urlString)
        return header.isEmpty ? nil : header
    }

    /// 解析最多等 10 秒（LP 5473 先要 15 秒，LP 5479 再收到 10 秒）。地址一直不来，多半是站点那边没放行：网络、规则本身，
    /// 或者这条规则存的登录过期了——把三处都写进提示里，别让人对着转圈猜（LP 5465）。
    private func startParseWatchdog() {
        parseWatchdog?.cancel()
        parseWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            guard case .parsingMedia = self.phase else { return }
            self.failed(String(localized: "没解析到播放地址"))
        }
    }

    private func handleParsedMedia(_ event: VideoParserEvent) {
        guard !event.url.isEmpty else { return }
        // 换集 / 重试后旧页面迟到的回调：代号对不上，不能拿它去起播。
        guard event.loadID == activeParseLoadID else { return }
        guard case .parsingMedia = phase else { return }
        parseWatchdog?.cancel()
        parseWatchdog = nil
        isEpisodeIncomplete = false
        playbackURL = event.url
        phase = .ready
        KazumiLogBuffer.player("解析到媒体地址（\(event.format)）")
        Task { await loadDanmaku() }
    }

    // MARK: - 弹幕

    /// 对应 PlayerDanmakuController.fetchDanmaku：按 Bangumi id + 集数取弹幕。
    func loadDanmaku() async {
        guard danmakuStatus != .loading else { return }
        danmakuStatus = .loading
        danmakuMessage = nil

        let episode = currentEpisode
        let road = selectedRoad
        let result = await DanmakuAPI.fetch(bangumiID: bangumiID, episode: episode)
        guard currentEpisode == episode, selectedRoad == road else { return }
        switch result {
        case .success(let comments):
            danmakuComments = comments
            danmakuStatus = .ready
            KazumiLogBuffer.player("弹幕已加载：\(comments.count) 条")
        case .empty:
            danmakuComments = []
            danmakuStatus = .empty
            danmakuMessage = String(localized: "本集暂无弹幕；需要时可手动检索")
        case .unavailable(let message):
            danmakuComments = []
            danmakuStatus = .unavailable
            danmakuMessage = String(localized: "\(message)，已关闭弹幕；再次打开可手动检索")
        case .failed(let message):
            danmakuComments = []
            danmakuStatus = .failed
            danmakuMessage = String(localized: "弹幕加载失败：\(message)，已关闭弹幕；再次打开可手动检索")
        }
    }

    func loadDanmaku(episodeID: Int) async -> DanmakuManualResult {
        let episode = currentEpisode
        let road = selectedRoad
        danmakuStatus = .loading
        danmakuMessage = nil
        do {
            let comments = try await DanmakuAPI.comments(episodeID: String(episodeID))
            guard currentEpisode == episode, selectedRoad == road else {
                return .failed(String(localized: "播放集数已变化，请重试"))
            }
            guard !comments.isEmpty else {
                danmakuComments = []
                danmakuStatus = .empty
                danmakuMessage = String(localized: "该分集暂无弹幕")
                return .empty
            }
            danmakuComments = comments
            danmakuStatus = .ready
            danmakuMessage = String(localized: "已切换弹幕源")
            return .loaded(comments.count)
        } catch {
            guard currentEpisode == episode, selectedRoad == road else {
                return .failed(String(localized: "播放集数已变化，请重试"))
            }
            let message = error.localizedDescription
            danmakuComments = []
            danmakuStatus = .failed
            danmakuMessage = String(localized: "弹幕源切换失败：\(message)")
            return .failed(message)
        }
    }

    private func resetSkipSegments() {
        skipSegments = .empty
        skipSegmentsURL = nil
    }

    private func resetDanmaku() {
        danmakuComments = []
        danmakuStatus = .idle
        danmakuMessage = nil
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
    }
}
