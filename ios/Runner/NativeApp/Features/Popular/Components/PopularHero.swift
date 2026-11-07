//
//  PopularHero.swift
//  Kazumi
//
//  推荐页焦点区（Colo 竖版规格 v3，LP 2782 定的方向）。
//
//  封面通栏铺满上半屏：600 高、顶边钉在屏幕顶端（LP 2843 / Colo 2844；550 → 600 见 LP 2901 / Colo 2902）。
//  封面在滚动内容里（LP 2846）：上滑跟着内容一起滚走；下拉到顶时不拉伸、不放大、
//  不回弹——下拉出来的那段由外层往回补（Colo 2847），所以视觉上封面钉在屏幕顶端不动；
//  同时封面自己从中心往四周放大（LP 2869 / Colo 2870），看起来就是封面被拽大。
//
//  层级自下而上，越上面越先响应自己（Ato 2852 / Colo 2842）：
//  1. 封面图 ＋ 底边渐隐：点击只挂这一层，整块 600 都是命中区，点哪儿都进详情；
//  2. 顶上 100 高的渐变遮罩：压住封面图，让顶栏那颗大标题读得清；跟着封面一起滚走
//     （Colo 2856，封面一走它就走，不会在货架第一行上糊一条色带），不吃点击；
//  3. 圆点、名称、元信息：`allowsHitTesting(false)`，不吃点击；
//  4. 开始观看、收藏圆钮：各自先响应自己，点它们不进详情；
//  5. 顶栏：封面块最上面那一层 overlay（LP 2865 / Colo 2866）——跟着封面一起滚走，
//     上滑一起消失、滚回来再出现；自己不带底色，标题和两颗圆钮压在顶上那层遮罩上。
//
//  竖版封面塞进 550 高会上下裁掉一截，所以按偏上对齐裁，顶部保留 8%，别把人脸裁掉。
//

import SwiftUI
import UIKit

/// 第一行「热门番组」标题点开选的那排标签：与搜索页、constants.dart 的清单一致。
let heroTags: [String] = [
    "日常", "原创", "校园", "搞笑", "奇幻", "百合", "恋爱", "悬疑",
    "热血", "后宫", "机战", "轻改", "偶像", "治愈", "异世界",
]

struct PopularHero: View {
    let items: [PopularPoster]
    var zoomNamespace: Namespace.ID?
    /// 封面是不是还在屏幕上：滚过去了就停掉自动切换（Colo 3047），不在看不见的地方空转。
    var isOnScreen: Bool = true
    /// 下拉过界时封面的放大倍数（LP 2938 / Colo 2939 / LP 2944）：外层按位移算好传进来，上滑时是 1。
    /// 图从顶边放大，左右下三个方向一起长。
    var pullScale: CGFloat = 1
    /// 下拉位移（LP 2963）：名称、元信息、开始观看、收藏跟着手指往下走这么多，尺寸不变。
    var pullOffset: CGFloat = 0
    /// 渐隐的位移：文字块那截照手走，再补上「图放大后比文字块多长出来的那截」，
    /// 下沿才能一直贴着图的新底边。
    private var fadeOffset: CGFloat {
        // 渐隐下沿永远贴封面底边：封面放大后底边往下长多少，它就跟多少（LP 3152）。
        // 原来这里是 `pullOffset + 补出来的那截`，下拉得深一点时它会被推到底边下面，
        // 于是「满底色」那一点落到封面底边以下，底边那一截就透出封面、收成一条硬边。
        coverHeight * (effectiveScale - 1)
    }

    @Environment(AppRouter.self) private var router
    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var settings
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.colorScheme) private var colorScheme

    /// 封面块高度（LP 2843 / Colo 2844：400 → 480 → 500 → 550；LP 2901 / Colo 2902：550 → 600）。
    /// 加高是为了把封面底边推到「开始观看」和第一行货架中间，文字块本身不动（见 `textBottomInset`）。
    static let coverHeight: CGFloat = 600
    /// 宽屏两栏时按栏宽算出来的封面高度（Colo 6651：栏宽 ÷ 0.67）。
    /// 不传就是竖屏那档的 600，竖屏一个像素不动。
    var coverHeightOverride: CGFloat? = nil
    /// 封面实际宽度：取图档位按它算（Colo 6663），不再写死手机那档 402。
    var coverWidth: CGFloat = 402
    /// 文字块摆哪儿（Colo 6687 §3.2 / §4.2）：压在封面下沿（单栏、两栏），
    /// 还是摆在封面右边（英雄行：iPad 竖屏、iPhone 横屏）。
    var textPlacement: TextPlacement = .overlay
    /// 顶栏要横跨多宽（Colo 6687 §2.3.1）：两栏时封面只占左栏，但「推荐」贴屏左、
    /// 两颗圆钮贴屏右。不传就跟容器一样宽（单栏、英雄行本来就整屏）。
    /// 宽档版面把标题和两颗圆钮收进右栏白底上（Colo 6725），左栏一个字的没有，顶栏由外面画。
    var showsTopBar: Bool = true
    /// 宽档左栏：封面自己接下拉手势（Colo 6730 做法二 / 6736）。只有按在封面这块矩形里才放大，
    /// 按在信息块上、右栏货架上、两栏中间那条缝上都不动。
    var coverPullGesture: Bool = false
    /// 拖动量外提（Colo 7139 iPad 竖屏：右栏要跟封面 1:1 同偏移）：传了就用外面的状态，
    /// 手势直接写这个绑定——封面和右栏货架从同一个状态算偏移，同一个弹簧、零延迟。
    /// 不传维持内部状态，窄档一个字不动。
    var dragPullSource: Binding<CGFloat>? = nil
    /// iPad 竖屏两栏（Colo 7139）：整个英雄行块加同一个 translation offset，
    /// 信息块不再单独算曲线；窄档 false，信息块照旧单独让封面（Ato 6718）。
    var blockPullOffset: Bool = false

    /// C 档左栏（6888 规格）：iPhone 横屏那一栏只有 210 宽，文字块压封面下沿渐变。
    /// 栏窄，两处跟单栏那套不一样——块底只留 16（不是单栏那条 50），
    /// 按钮排也按栏宽排开：继续观看通栏、收藏贴右缘 16，两个框不许叠
    /// （LP 6901：原来「胶囊居中＋收藏浮右缘」在 210 宽里正好压在一起）。
    var compactColumn: Bool = false
    /// C 档封面向左铺进安全区的那一段（Ato 6936 / Colo 6940）：图从屏左缘起，信息块仍从内缩线起。
    var compactLeadingBleed: CGFloat = 0
    /// C 档块底留白：底安全区 + 16（Colo 6940：402 − 21 − 16 = 365）。
    var compactBottomInset: CGFloat = PopularHero.compactTextBottomInset

    /// 封面自己拖出来的位移（0…120），松手回弹到 0。
    @State private var dragPull: CGFloat = 0
    /// 这一下手指走过 8 点没有：走过是拖、没走过是点（Colo 6750 / 6763）。
    @State private var isCoverMoved = false

    /// 真正用的拖动量：外提了（iPad 竖屏两栏）用外面的，否则内部状态。
    private var dragPullValue: CGFloat { dragPullSource?.wrappedValue ?? dragPull }

    /// 真正用的放大倍数：外面传进来的（手机那条路）和封面自己拖出来的，取大的那个。
    private var effectiveScale: CGFloat {
        max(pullScale, 1 + min(dragPullValue, 120) / 550)
    }

    /// 信息块让开的距离：封面往下长多少就让多少。
    private var effectiveOffset: CGFloat {
        max(pullOffset, coverHeight * (effectiveScale - 1))
    }

    /// 封面这一档（iPad 横屏左栏）唯一的手势：拖动放大、松手回弹，没走过阈值就是点按、进详情。
    ///
    /// 点按和拖动必须由同一个识别器判（Colo 6730 做法二 / 6750 / 6763）。之前是封面套一个
    /// Button、外层再挂一个拖动手势，同一个抬手被两处各判一次，谁先谁后不保证——七次里会漏
    /// 一次点按、直接跳进详情（Ato 6765）。合成一处之后没有先后可言，给那颗旗子收尾的
    /// 0.15 秒计时器也一并删掉。
    /// 判据是位移不是时长（Colo 6750）：任一方向走过 8 点就算拖，快甩和慢拖一视同仁；
    /// 放大只看竖向，横向仍留给翻页。
    private var coverGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard coverPullGesture else { return }
                let moved = max(abs(value.translation.height), abs(value.translation.width)) > 8
                if moved != isCoverMoved { isCoverMoved = moved }
                setPull(moved ? min(120, max(0, value.translation.height * 0.55)) : 0)
            }
            .onEnded { _ in
                guard coverPullGesture else { return }
                let wasDrag = isCoverMoved
                isCoverMoved = false
                if wasDrag {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        setPull(0)
                    }
                } else {
                    setPull(0)
                    openDetail(currentID ?? items.first?.id)
                }
            }
    }

    /// 写拖动量：外提了写绑定（封面和右栏一起动），否则写内部状态。
    private func setPull(_ value: CGFloat) {
        if let source = dragPullSource {
            source.wrappedValue = value
        } else {
            dragPull = value
        }
    }
    /// `trailingFilled`：封面在左、整块信息（简介、标签都在）在右，跟封面顶对齐往下排，
    /// 把那一栏的高度填满（Ato 6720 第二条：iPad 竖屏右栏的信息量要跟横屏左栏一样）。
    enum TextPlacement { case overlay, trailing, trailingFilled, below }
    private var coverHeight: CGFloat { coverHeightOverride ?? Self.coverHeight }
    /// 文字块离块底的留白（LP 2901 / Colo 2902）：封面加高 50，文字块原地不动，
    /// 所以「开始观看」那排仍在原来的位置，封面底边落到它下面、货架上面。
    static let textBottomInset: CGFloat = 50
    /// C 档左栏那条块底留白（6888 规格：「底 16」）。单栏那条 50 是给 600 高封面留的，
    /// 210×315 的左栏装不下，文字块会被顶到封面中段（LP 6901 那版块底 265、规格 299）。
    static let compactTextBottomInset: CGFloat = 16
    /// 文字块（名称、元信息、按钮、滚动点，含块底那 50）的高度：标题行数一变它就变，
    /// 所以整块量出来（`textBlockHeight`）。1 行标题时是 164，块顶落在 436。
    static let textBlockDefaultHeight: CGFloat = 164
    /// 提前到离封面底边 40 就满页面底色：560 往下的 40 点一直是满底色（Colo 2922），
    /// 最后这一段已经是纯底色，封面底边那条线就露不出来。
    static let fadeFullInset: CGFloat = 40
    /// 下拉时块往下长的封顶位移：再往下拽块也不再变高（原先是放大封顶 1.22）。
    static let maxPullDistance: CGFloat = 120
    /// 下拉放大的封顶比例（Colo 2953）：550 点下拉到 1.22，再往下不再放大。
    static let maxPullScale: CGFloat = 1.22
    /// 还没取到当前条目时给转场源用的兜底 ID（命名空间里没有同 ID 的目标，系统按默认转场走）。
    static let posterSourceFallbackID: Int = -1
    /// 竖版封面偏上对齐时顶部保留的比例。
    static let topReserve: CGFloat = 0.08

    @State private var currentID: Int?
    @State private var isToggling = false
    /// 顶栏本体的实际高度：提示语要落在它下面。
    @State private var topBarHeight: CGFloat = 59
    @State private var toastMessage: String?
    /// 选源面板的载体：与番剧详情页同一套（LP 2903 / Colo 2907）。
    @State private var sourceController: InfoController?
    /// 刚才是从选源面板点进播放页的：返回时把面板放回来（Colo 3275）。
    @State private var returnToSourcesAfterPlayer = false
    @State private var depthBeforePlayer = 0
    /// 从空规则的空状态点「去规则仓库添加」：关面板、等关完再推页（LP 2026-10-28）。
    @State private var goToRuleShopAfterDismiss = false
    /// 刚从规则仓库回来：把面板重开一次，别再停在空状态（Colo 3974）。
    @State private var returnFromRuleShop = false
    @State private var depthBeforeRuleShop = 0
    @State private var sourceNavigationRevision: UInt = 0

    private var navigationDepth: Int {
        router.popularPath.count + router.timelinePath.count
            + router.collectPath.count + router.myPath.count
    }
    /// 第一次点「开始观看」要先把条目备齐（缓存优先，没有才请求），期间不再接第二次点。
    /// 顶栏本体的实际高度：提示语要落在它下面。
    /// 文字块整块的实际高度（含块底那 50 的留白），渐隐由它推出来。
    /// 用 `onGeometryChange` 量（`PreferenceKey` 那条路在这版没吃到值）。单行标题是 164。
    @State private var textBlockHeight: CGFloat = PopularHero.textBlockDefaultHeight
    /// 字号跟着封面宽长（Colo 6687 §3.2 / §2.3.4）：402 宽是 22，484 是 27，645 是 37。
    /// 底数走系统文字样式，最大字号下照样跟着放大；402 以下不缩，单栏档一个像素不动。
    @ScaledMetric(relativeTo: .title2) private var title2Base: CGFloat = 22
    @ScaledMetric(relativeTo: .footnote) private var footnoteBase: CGFloat = 13
    /// 英雄行里文字块占多宽：容器宽减封面宽再减两侧留白（Colo 6687 §3.2）。
    @Environment(\.popularHeroTextWidth) private var textWidth
    private var coverTextScale: CGFloat {
        max(1, 1 + (coverWidth - 402) * 0.0617 / 22)
    }
    /// 圆钮按下时弹一下：缩到 0.8 再回弹，120 毫秒（Colo 2803）。
    @State private var followScale: CGFloat = 1
    /// 轮播停在第几页（含两头的克隆页）。滚动位置绑它，绕回不往回翻（LP 3064）。
    @State private var pageIndex: Int?
    /// 这一页在不在前台（切走 tab 会走 onDisappear）：切走就停掉自动切换（Colo 3047）。
    @State private var isPageVisible = true
    /// 手指正按着／还在滑：这时候不切，松手后重新起算（Colo 3067）。
    @State private var isScrolling = false
    /// 应用在不在前台。不用 `scenePhase`：实测这页读到的一直是非 active（模拟器上 act=0），
    /// 自动翻页的前提永远不满足，封面就不会自己翻了（LP 6967）。直接读 UIApplication 的状态。
    @State private var isAppActive = UIApplication.shared.applicationState == .active
    /// 上一次换页的时刻。5 秒的倒计时从这里算起：原来是从「转场停稳」才开始数，
    /// 转场那 0.55 秒额外加了进去，实测成了 5.75–6 秒一次（LP 6967 后定 5 秒一次）。
    @State private var lastPageChangeAt = Date()

    /// 自动切换的三个前提：不止一张、这一页在前台、封面没被滚出屏幕。
    private var canAutoAdvance: Bool {
        items.count > 1 && isPageVisible && isOnScreen && !isScrolling && isAppActive
    }

    /// 封面的解码档位：和 `BangumiRemoteImage` 在封面这个尺寸上算出来的那一档一致，
    /// 不然预取的图和视图要的不是同一份，等于白取。
    private var coverPixelSize: Int {
        KazumiImageLoader.pixelSize(for: CGSize(width: coverWidth, height: coverHeight))
    }

    /// 自动翻页的下一张（可能落在尾部那页克隆上，画的是第一张）。
    private var nextPoster: PopularPoster? {
        let from = pageIndex ?? firstRealPage
        let next = from + 1
        guard pages.indices.contains(next) else { return nil }
        return pages[next].poster
    }

    /// 下一张的封面已经在内存里了才翻（Colo 3067）。
    private var isNextCoverReady: Bool {
        guard let next = nextPoster else { return false }
        return KazumiImageLoader.shared.cachedImage(for: next.imageURL, pixelSize: coverPixelSize) != nil
    }

    private func prefetchNextCover() {
        guard let next = nextPoster else { return }
        KazumiImageLoader.shared.prefetch([next.imageURL], pixelSize: coverPixelSize)
    }

    /// 从当前页往后取两张（到尾部就绕回开头），保证下一次自动翻页时图已经就绪。
    private func prefetchAhead() {
        guard items.count > 1 else { return }
        let from = pageIndex ?? firstRealPage
        var urls: [String] = []
        for step in 1...2 {
            let index = from + step
            guard pages.indices.contains(index) else { continue }
            urls.append(pages[index].poster.imageURL)
        }
        guard !urls.isEmpty else { return }
        KazumiImageLoader.shared.prefetch(urls, pixelSize: coverPixelSize)
    }

    /// 计时任务的身份：任何一个前提变了，或者换了一张，旧计时就作废重来。
    private var autoAdvanceKey: String {
        "\(pageIndex ?? -1)|\(isPageVisible)|\(isOnScreen)|\(isScrolling)|\(isAppActive)"
    }

    /// 换到下一张：永远往右翻一页。翻到最后一张时下一页就是尾部那页克隆，
    /// 画的是第一张；落定后再悄悄挪回第一张真页（LP 3064）。
    private func advanceCover() {
        guard items.count > 1 else { return }
        let from = pageIndex ?? firstRealPage
        // 还停在两头的克隆页上（快速连滑时常见）：先无声挪回对应的真页。
        // 克隆页画的本来就是同一张，挪这一下看不见。原来这里直接 return，
        // 于是停在克隆页之后再也翻不动，得往回滑一次才行（LP 3106）。
        if let real = realPageIndex(for: from) {
            withTransaction(silentScrollTransaction) { pageIndex = real }
            return
        }
        let next = from + 1
        guard pages.indices.contains(next) else { return }
        withAnimation(.easeInOut(duration: 0.55)) {
            pageIndex = next
        }
    }

    /// 无声挪页用的事务：关掉动画，并保住滚动速度（Colo 3114）——
    /// 不然挪回去之后系统会按旧的惯性再弹一下，等于白挪。
    private var silentScrollTransaction: Transaction {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        if #available(iOS 18.0, *) {
            transaction.scrollPositionUpdatePreservesVelocity = true
        }
        return transaction
    }

    /// 停在克隆页上就无声挪回真页；不然下一次翻页会因为没有下一页而卡住。
    private func settleIfOnClone() {
        guard let index = pageIndex, let real = realPageIndex(for: index) else { return }
        withTransaction(silentScrollTransaction) { pageIndex = real }
    }

    /// 克隆页下标 → 对应的真页下标；本来就是真页时返回 nil。
    private func realPageIndex(for index: Int) -> Int? {
        guard items.count > 1 else { return nil }
        if index == 0 { return items.count }
        if index == pages.count - 1 { return 1 }
        return nil
    }

    /// 落在两头的克隆页时，等翻页动画走完再无声无息地挪到对应的真页。
    private func recenterIfNeeded(landed: Int) {
        guard items.count > 1 else { return }
        let target: Int?
        if landed == 0 {
            target = items.count
        } else if landed == pages.count - 1 {
            target = 1
        } else {
            target = nil
        }
        guard let target else { return }
        Task {
            // 等这一页真的停稳再挪（LP 3075）：翻页动画还没走完就改滚动位置，
            // 系统会把这次改动丢掉，于是「绕回第一张后的第一次翻页」不动一下。
            // 手指还按着就一直等，别一看到在滑就放弃——快速连滑时那正是常态，
            // 放弃了就永远停在克隆页上（LP 3106）。
            for _ in 0..<40 {
                if pageIndex != landed { return }
                if !isScrolling { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard pageIndex == landed, !isScrolling else { return }
            try? await Task.sleep(for: .milliseconds(120))
            guard pageIndex == landed, !isScrolling else { return }
            withTransaction(silentScrollTransaction) { pageIndex = target }
        }
    }

    /// 轮播里的一页。两头各多一页克隆（最后一张、第一张各复制一份），
    /// 这样「最后一张 → 第一张」是继续往右翻过去，不是往回倒（LP 3064）。
    private struct CarouselPage: Identifiable {
        let index: Int
        let poster: PopularPoster
        var id: Int { index }
    }

    /// 只有一张时没有克隆页，也不用绕。
    private var pages: [CarouselPage] {
        guard items.count > 1 else {
            return items.enumerated().map { CarouselPage(index: $0.offset, poster: $0.element) }
        }
        var result: [CarouselPage] = [CarouselPage(index: 0, poster: items[items.count - 1])]
        for (offset, item) in items.enumerated() {
            result.append(CarouselPage(index: offset + 1, poster: item))
        }
        result.append(CarouselPage(index: items.count + 1, poster: items[0]))
        return result
    }

    /// 第一张真页的下标（有克隆页时是 1）。
    private var firstRealPage: Int { items.count > 1 ? 1 : 0 }

    private var current: PopularPoster? {
        items.first { $0.id == (currentID ?? items.first?.id) }
    }

    private var collectType: CollectType {
        guard let id = current?.id else { return .none }
        return library.entry(for: id)?.collectType ?? .none
    }

    /// 单栏、两栏左栏：文字块压在封面下沿（现在这套，一处不动）。
    private var overlayLayout: some View {
        // 压图结构（Ato 7186/7189）＋分开版条目排版（LP 7194/7200/7202：名称左对齐、
        // 通栏开始观看、简介在）：直接用 infoCard 压在封面下部，不用旧 textBlock 的居中排。
        // 块底留 textBottomInset，渐隐高度照旧量整块（含底部留白）盖下来。
        ZStack(alignment: .bottom) {
            coverLayer
            // 文字块不参与放大，只跟着手指往下移（LP 2963）。
            infoCard
                // 内缩跟上一版（below）同一条：左右 24（Colo 7214）。
                .padding(.horizontal, 24)
                // 块底留白：原 50 是平板两栏的节奏，单栏简介下空太多（LP 7222），
                // 收到 16 让整块下移、简介贴近封面底边。
                .padding(.bottom, 16)
                .offset(y: pullOffset)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { textBlockHeight = $0 }
        }
        .frame(height: coverHeight)
    }

    /// 英雄行（Colo 6687 §3.2 / §4.2）：封面在左、文字在右，文字垂直居中于封面那段高度。
    private var trailingLayout: some View {
        HStack(alignment: .center, spacing: 32) {
            coverLayer
                .frame(width: coverWidth, height: coverHeight)
            textBlock(alignedLeading: true)
                .frame(width: textWidth, alignment: .leading)
            Spacer(minLength: 0)
        }
        .frame(height: coverHeight)
    }

    /// 两栏左栏（Colo 6691）：封面在上、纯美术不放字，信息块在下面把剩下的高度填满。
    private var belowLayout: some View {
        VStack(spacing: 0) {
            coverLayer
                .frame(width: coverWidth, height: coverHeight)
                .contentShape(Rectangle())
                .simultaneousGesture(coverGesture)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(current?.displayName ?? "")
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("打开详情")
                .accessibilityAction { openDetail(currentID ?? items.first?.id) }
            infoCard
                .padding(.horizontal, 24)
                .padding(.top, 20)
                // 下拉过界封面往下长多少，信息块就跟着让多少，不许被封面盖住（Ato 6718）。
                // iPad 竖屏两栏走 blockPullOffset：整块跟移，信息块不再单独算曲线（Colo 7139）。
                .offset(y: blockPullOffset ? 0 : effectiveOffset)
            Spacer(minLength: 0)
        }
        .offset(y: blockPullOffset ? effectiveOffset : 0)
    }

    /// 封面在左、整块信息在右，垂直居中（Colo 6725）：右栏 963 高，六项排满 432，
    /// 居中后上留 265、下留 266，读起来是留白不是洞。标题压在封面右段 x=500、
    /// 两颗圆钮贴屏右缘（Colo 7244），不再收进右栏；整行（标题行+圆钮+信息块）
    /// 挂同一个跟移偏移（Ato 7241 / Colo 7236）。
    private var trailingFilledLayout: some View {
        HStack(alignment: .top, spacing: 32) {
            coverLayer
                .frame(width: coverWidth, height: coverHeight)
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                infoCard
                    .frame(width: textWidth, alignment: .leading)
                Spacer(minLength: 0)
            }
            .frame(width: textWidth)
            // 信息块和标题行同一个量：封面底边往下长多少就下移多少（Ato 7241 / Colo 7236）。
            .offset(y: fadeOffset)
            Spacer(minLength: 0)
        }
        .frame(height: coverHeight)
        .overlay(alignment: .topLeading) {
            // 标题贴屏最左，边距跟「我的」页系统大标题取齐 x=20（LP 7255 / Colo 7257 实机量得）；
            // 行顶 = tab 药丸实际底边 +8（Colo 7253）；量不到药丸时按 1032×1376 实测节奏回落
            // （tab 底 59.5、标题顶 67.5）。
            PopularWideTopBar(leadingPadding: 20)
                .padding(.top, (Self.tabBarBottomEdge() ?? Self.statusBarHeight + 26) + 8)
                // 标题行和圆钮跟信息块同一个量：封面底边往下长多少就下移多少，
                // 同一个状态（pullScale）、同一个弹簧（Ato 7241 / Colo 7236）。
                .offset(y: fadeOffset)
        }
    }

    /// 浮动 tab 条药丸底边（窗口 y）：iPad 竖屏全宽档的大标题要压在它下面一行
    /// （Colo 7253：标题行顶 = tab 条实际底边 +8）。找法同 PopularScreen.tabBarLeadingEdge；
    /// 系统改名找不到时返回 nil，调用处自己回落。
    static func tabBarBottomEdge() -> CGFloat? {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first?.keyWindow,
              let bar = findTabBar(in: window) else { return nil }
        var queue: [UIView] = bar.subviews
        while !queue.isEmpty {
            let v = queue.removeFirst()
            if String(describing: type(of: v)) == "_UITabBarItemPlatterView" {
                return v.convert(v.bounds, to: window).maxY.rounded()
            }
            queue.append(contentsOf: v.subviews)
        }
        return nil
    }

    private static func findTabBar(in view: UIView) -> UITabBar? {
        if let bar = view as? UITabBar { return bar }
        for sub in view.subviews { if let b = findTabBar(in: sub) { return b } }
        return nil
    }

    /// 左栏信息块：名称、元信息、开始观看、圆点、简介、标签行（Colo 6691）。
    /// 简介是异步来的，先占住位置再替换，免得数据一到整块往下推。
    private var infoCard: some View {
        // 手机竖屏（overlay 压图）居中（LP 7284 / Colo 7286）；below / trailingFilled 仍是左缘那套。
        let centered = textPlacement == .overlay
        return VStack(alignment: .leading, spacing: 0) {
            Text(current?.displayName ?? "")
                .font(.system(size: title2Base * coverTextScale, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)

            // 元信息回到带 • 的灰字（LP 7307，胶囊那几轮作废）；手机竖屏随整块居中。
            if let meta = current?.metaLine {
                Text(meta)
                    .font(.system(size: footnoteBase * coverTextScale))
                    .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                    .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
                    .padding(.top, 6)
            }

            // 单栏（overlay 压图）不走通栏（Colo 7220）：胶囊内容宽、自带水平内距 22、最小高 40，
            // 收藏留同一行右端；通栏只属于 below / iPad 横屏左栏（Ato 6936）。
            // 轮播页点在按钮行上面（LP 7231）：元信息底下，先点后按钮。
            dots
                .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
                .padding(.top, 12)

            // 手机竖屏：开始观看单独居中，收藏贴右缘（LP 7295，改掉 7286 的「整体居中」）；
            // 其余档照旧：below / trailingFilled 开始观看通栏，收藏同行右端。
            Group {
                if centered {
                    ZStack {
                        playButton(expanded: false)
                            .frame(maxWidth: .infinity)
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            followButton
                        }
                    }
                } else {
                    HStack(spacing: 12) {
                        playButton(expanded: textPlacement == .below || textPlacement == .trailingFilled)
                            .frame(maxWidth: (textPlacement == .below || textPlacement == .trailingFilled) ? .infinity : nil)
                        followButton
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 10)

            summarySlot
                .padding(.top, 16)
        }
        // 名称、简介跟着居中（multilineTextAlignment 沿环境往下传）。
        .multilineTextAlignment(centered ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }

    /// 简介位：有数据画三行，没有就先画三条骨架灰条占住同一块高度（Colo 6691 第二条）。
    private var summarySlot: some View {
        Group {
            if let summary = current?.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: footnoteBase * coverTextScale))
                    .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                    // 竖屏那栏给到六行（Colo 6725），横屏左栏还是三行。
                    .lineLimit(textPlacement == .trailingFilled ? 6 : 3)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule()
                            .fill(KazumiPalette.secondaryText(for: colorScheme).opacity(0.18))
                            .frame(height: 15)
                    }
                }
            }
        }
        // 三行的高度先占住，数据到了原地换内容，位置不动。
        .frame(maxWidth: .infinity, minHeight: 63, alignment: .topLeading)
    }

    /// 封面那一层：分页图 ＋ 底边渐隐。
    private var coverLayer: some View {
        ZStack(alignment: .bottom) {
            // 下拉时只有那张图从顶边放大（LP 2963 / Colo 2939）：横向钉死页宽，
            // 纵向往下长，多出来的露在下面。可视宽度不跟着放大，隔壁才不会挤进来（Colo 2959）。
            pager
                .scaleEffect(effectiveScale, anchor: .top)
                .mask(alignment: .top) {
                    Rectangle()
                        .frame(maxWidth: .infinity)
                        .frame(height: coverHeight * Self.maxPullScale)
                }

            // 底边渐隐挂在封面这一整个盒子上，不挂在图里（Colo 2922）：
            // 挂在图上时，它的下沿跟着图片自己的高度走，渐隐就提前 18 点结束，底边那条线就露出来了。
            fade
                .offset(y: fadeOffset)
        }
    }

    var body: some View {
        Group {
            if textPlacement == .trailing {
                trailingLayout
            } else if textPlacement == .trailingFilled {
                trailingFilledLayout
            } else if textPlacement == .below {
                belowLayout
            } else {
                overlayLayout
            }
        }
        .onPreferenceChange(TopBarHeightKey.self) { topBarHeight = $0 }
        // 封面块不做缩放转场，走默认的横向翻页（LP 2976）：缩放转场返回时只飞回一张快照，
        // 渐隐和按钮要等动画结束才出现，看着就是「图先落回、底下一闪」。
        // 不登记源视图，详情页那边会自动回落到系统默认转场。
        // 这里不裁：下拉过界时封面放大，底边要真的往下长出来（LP 2942）。
        // 平时图正好 600 高，没有东西溢出去。

        // 选源面板不再挂在这一页上（2026-10-28 计时：点下去到面板开始画 3.6 秒，
        // 全耗在「弹之前先把这一页重排一遍」）。现在交给根层去弹，
        // 这一页只负责交出控制器和两个回调。
        .onChange(of: router.externalNavigationRevision) { _, _ in
            returnToSourcesAfterPlayer = false
            returnFromRuleShop = false
            goToRuleShopAfterDismiss = false
            sourceController?.closeSourceSearch()
        }
        .onChange(of: SourceSheetCoordinator.shared.isPresented) { _, presented in
            guard sourceNavigationRevision == router.externalNavigationRevision,
                  !presented else { return }
            // 面板关完了：该进规则仓库就进（等关闭动画收完，两个动画不抢）。
            if goToRuleShopAfterDismiss {
                goToRuleShopAfterDismiss = false
                returnFromRuleShop = true
                depthBeforeRuleShop = navigationDepth
                router.push(.pluginShop)
            }
        }
        // 从播放页返回：把面板放回来。
        .onChange(of: navigationDepth) { _, newDepth in
            guard sourceNavigationRevision == router.externalNavigationRevision,
                  returnToSourcesAfterPlayer, newDepth <= depthBeforePlayer else { return }
            returnToSourcesAfterPlayer = false
            if let controller = sourceController { presentSources(controller) }
        }
        // 从规则仓库回来：规则装上了就把面板重开一次；还是空的就留在原地。
        .onChange(of: navigationDepth) { _, newDepth in
            guard sourceNavigationRevision == router.externalNavigationRevision,
                  returnFromRuleShop, newDepth <= depthBeforeRuleShop else { return }
            returnFromRuleShop = false
            guard !environment.plugins.pluginList.isEmpty else { return }
            guard let controller = sourceController else { return }
            presentSources(controller)
        }
        // 分页一变就更新「当前是哪部」，落到克隆页则等动画走完再悄悄挪回真页：
        // 两页画的是同一张图，挪过去看不出接缝。
        .onChange(of: isScrolling) { _, scrolling in
            // 兜底：手一松，只要还停在两头的克隆页上就挪回真页。
            // 自动切换那条路已经管了，这条管「滑到克隆页就停手」的情况（LP 3106）。
            guard !scrolling else { return }
            settleIfOnClone()
        }
        .onChange(of: pageIndex) { _, newValue in
            guard let newValue, pages.indices.contains(newValue) else { return }
            currentID = pages[newValue].poster.id
            lastPageChangeAt = Date()
            recenterIfNeeded(landed: newValue)
            // 每换一页就把后面两张补取进来（Colo 3076）：只在进页时取一次的话，
            // 隔一张就没图了。
            prefetchAhead()
        }
        // 大封面自己走：停 5 秒换下一张，到头绕回第一张（LP 3044 / 3064）。
        // 只在看得见、在前台时走（Colo 3047）：切走 tab、退后台、封面滚出屏幕都停。
        // 计时挂在 currentID 上：手指翻页也会重新起算，不会刚滑完就被换走。
        .task(id: autoAdvanceKey) {
            // 等 5 秒；到点了下一张封面还没解码好就先不翻——旧封面留在原地，
            // 再过 5 秒看一次（Colo 3067：宁可晚一点，也不许翻出一片白）。
            while canAutoAdvance, !Task.isCancelled {
                // 从上一次换页算起还差多少到 5 秒（至少留 0.3 秒，别空转）。
                let remaining = max(0.3, 5 - Date().timeIntervalSince(lastPageChangeAt))
                try? await Task.sleep(for: .seconds(remaining))
                if Task.isCancelled || !canAutoAdvance { return }
                if isNextCoverReady {
                    advanceCover()
                    return
                }
                // 下一张还没解码好：补取，再过一小会儿再看，宁可晚一点也不翻出一片白。
                prefetchNextCover()
            }
        }
        .onAppear { isPageVisible = true }
        .onDisappear { isPageVisible = false }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in isAppActive = true }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in isAppActive = false }
        // 条目换成 5 张以内时把圆点状态收敛回第一张。
        .onAppear {
            if currentID == nil { currentID = items.first?.id }
            if pageIndex == nil, !items.isEmpty { pageIndex = firstRealPage }
            // 只补取「当前往后两张」，不把五张全取进来（LP 3077 要省内存）：
            // 翻页前下一张一定已经就绪，再往后的一张有 5 秒慢慢来。
            prefetchAhead()
        }
        .onChange(of: items.first?.id) { _, _ in
            if let first = items.first?.id, !items.contains(where: { $0.id == currentID }) {
                currentID = first
                pageIndex = firstRealPage
            }
        }
        // 顶栏是封面块最上面那一层（LP 2865 / Colo 2866）：压在封面顶边，
        // 跟着封面、跟着内容一起滚。LP 3132 说了照旧滚动，只把固定那条模糊改成上滑才出现。
        .overlay(alignment: .top) {
            if showsTopBar {
                topBar
                    .padding(.top, Self.statusBarHeight)
            }
        }
        // 提示语摆在顶栏下沿再让 12，不然会压住状态栏的时钟和顶栏那三十四点的大标题。
        .overlay(alignment: .top) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.78)))
                    .padding(.top, toastOffset)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - 封面

    private var pager: some View {
        ScrollView(.horizontal) {
            // 这里用 HStack 而不是 LazyHStack（LP 3074）：只有 5 张加两页克隆，
            // 全部先摆好；懒加载会在自动翻页滚过去的半路上才建下一页，那一下就是白片。
            HStack(spacing: 0) {
                ForEach(pages) { page in
                    cover(page.poster)
                        .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $pageIndex)

        // 手指按住、还在滑都不切，松手（回到 idle）后计时重新起算（Colo 3067）。
        .onScrollPhaseChange { _, phase in
            isScrolling = phase != .idle
        }
        .scrollIndicators(.hidden)
        // 横向裁在翻页容器这一层：外面那层不能裁（下拉时封面要往下长出来），
        // 但隔壁那张页就在右边，不裁的话它会被一起画出来（LP 2958）。
        .clipped()
    }

    /// 封面图 ＋ 底边渐隐：点击只挂在这一层（Ato 2852），整块都是命中区。
    @ViewBuilder
    private func cover(_ poster: PopularPoster) -> some View {
        if coverPullGesture {
            // 这一档（iPad 横屏左栏）整块的点按/拖动交给外层同一个手势（见 `coverGesture`）：
            // 不再套 Button，否则一个抬手被两处各判一次，就会偶发跳详情（Ato 6765）。
            // 无障碍标签和激活动作挂在外层那一块上（见 `belowLayout`）。
            coverImage(poster)
        } else {
            // 其余各档照旧用 Button：换成点击手势之后，同层的拖动手势一次都收不到
            // （实测拖 200 点封面逐像素零差），放大直接死掉。
            Button {
                openDetail(poster.id)
            } label: {
                coverImage(poster)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(poster.displayName)
            .accessibilityHint("打开详情")
        }
    }

    /// 封面那一张图：竖图铺满整块，宽度钉在页宽上（`containerRelativeFrame`），高度超出 coverHeight 的裁掉。
    private func coverImage(_ poster: PopularPoster) -> some View {
        ZStack(alignment: .bottom) {
            // 宽度必须钉：横向 ScrollView 给内容的宽度提议是无穷大，光靠
            // `frame(maxWidth: .infinity)` 撑不开，图会按自己的比例算出一个比页宽更宽的
            // 尺寸（实测 440 对 402），左右各溢出 19 点——左右滑时隔壁那张就从这条缝里
            // 露出来（LP 2899 / Colo 2900）。
            BangumiRemoteImage(url: poster.imageURL)
                .containerRelativeFrame(.horizontal)
                // 高度必须钉死 600（Colo 3165）：不钉的话这一层的高度是按海报自己的
                // 比例算出来的（同一页宽 402，矮的 568、高的 611），底边就不在 600 上。
                // 渐隐的底边是按 600 算的，高海报的底边会落到渐隐下面，露出一条——
                // 换一张海报露的多少还不一样，这就是「一直漏」。
                .frame(height: coverHeight)
                // 放大由整块那层统一做（Colo 2953）：图自己再放一次会变成 1.22 的平方。
                // 这里只管裁：显示尺寸永远等于页宽 402、页高 600。
                .clipped()
        }
    }

    /// 进详情页：大封面点开走系统默认的横向翻页，不做缩放转场（LP 2976 / 2985）。
    private func openDetail(_ id: Int?) {
        guard let id else { return }
        router.push(.bangumiInfo(bangumiID: id, zoom: false))
    }

    /// 底边渐隐：从圆点那行底下开始往下，把封面渐成页面底色，满底色落在 560，
    /// 再往下 40 点一直是满底色（Colo 2922）。
    ///
    /// 第一档必须是 0（LP 2925 / 2926 / Colo 2930）：之前起手就给 20%，圆点那行以上是原图、
    /// 以下一层白纱，那条台阶看着就像在封面上贴了一张透明白图。
    private var fade: some View {
        // 下沿＝封面底边（放大后也跟着走），上沿压在文字块顶上。
        // 用块高而不是量绝对位置：下拉时文字块整体位移，绝对位置会带着位移走，块高不会。
        let coverBottom = coverHeight * effectiveScale
        // 英雄行的文字不在封面上，渐隐按默认文字块那一段的高度收（Colo 6687 §3）。
        let textTop = textPlacement == .trailing
            ? coverHeight - Self.textBlockDefaultHeight
            : coverHeight - textBlockHeight + pullOffset
        // C 档渐隐高 = 块高 + 16（Colo 6940）。
        let height = max(1, coverBottom - textTop + (compactColumn ? 16 : 0))
        // 满底色永远落在封面底边往上 40：这样底边那一截是纯底色，
        // 封面图的下边缘不会透出来成一条硬边（LP 3152）。
        let full = min(1, max(0.01, (height - Self.fadeFullInset) / height))
        // 七档等分在渐隐的顶…560 上（Colo 2930），第一档是 0——
        // 顶部那一档要是直接给 20%，圆点那行就会成一条台阶（LP 2925 / 2926）。
        // C 档名称压在海报上，名称要 ≥3:1、元信息 ≥4.5:1（Colo 6940），渐隐要在名称那一行就吃满。
        let steps: [CGFloat] = compactColumn
            ? [0, 0.85, 0.93, 0.96, 0.98, 0.99, 1]
            : [0, 0.20, 0.40, 0.60, 0.80, 0.90, 0.95]
        var stops = steps.enumerated().map { index, opacity in
            Gradient.Stop(
                color: pageBackground.opacity(opacity),
                location: full * CGFloat(index) / CGFloat(steps.count)
            )
        }
        // 满底色落在 560，600 往上这 40 点一直是满底色（Colo 2922）。
        stops.append(.init(color: pageBackground, location: full))
        stops.append(.init(color: pageBackground, location: 1))
        return LinearGradient(
            stops: stops,
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .allowsHitTesting(false)
    }

    /// 页面真正的底色：封面块下面那块没有自己刷底色，用的是系统背景
    /// （浅色纯白、深色纯黑）。渐隐收尾必须用它，用 `KazumiPalette.background`
    /// （浅色是 0.98）在 600 处会差 5 级，正好显出一条线。
    private var pageBackground: Color { Color(uiColor: .systemBackground) }

    // MARK: - 文字

    private func textBlock(alignedLeading: Bool) -> some View {
        VStack(spacing: 0) {
            // 名称、元信息不吃点击（Ato 2852）：点击只挂封面图那一层，
            // 文字压在上面也不会把按钮的点击吃掉。
            VStack(spacing: 0) {
                Text(current?.displayName ?? "")
                    // 字号跟着封面宽长（Colo 6687 §3.2）；402 宽不缩，还是 .title2 那一档。
                    .font(coverTextScale > 1
                          ? .system(size: title2Base * coverTextScale, weight: .bold)
                          : .title2.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(alignedLeading ? .leading : .center)
                    .padding(.horizontal, alignedLeading ? 0 : (compactColumn ? 16 : 24))

                if let meta = current?.metaLine {
                    Text(meta)
                        .font(coverTextScale > 1
                              ? .system(size: footnoteBase * coverTextScale)
                              : .footnote)
                        .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: alignedLeading ? .leading : .center)
            .allowsHitTesting(false)

            actions
                .padding(.top, 14)

            // 滚动点挪到「开始观看」下面（LP 3127）：上面那排（含右侧收藏）整体上移 28 让出位置，
            // 点落在原来那排占的地方。
            if compactColumn {
                ZStack {
                    dots
                    HStack {
                        Spacer()
                        followButton
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            } else {
                dots
                    .padding(.top, 12)
            }
        }
        // 文字块贴块底：开始观看那排压在块底上，名称落在块底往上 78（Colo 2853 / 2868）。
        // 1 行标题时正好是 78，2 行会更高——78 说的是单行那个位置。
        // 块底从 550 抬到 600 之后文字块跟着留出这 50，屏上位置一点不变（LP 2901 / Colo 2902）。
        .padding(.leading, compactColumn ? compactLeadingBleed : 0)
        .padding(.bottom, alignedLeading ? 0 : (compactColumn ? compactBottomInset : Self.textBottomInset))
        // 量整块（含块底那 50）：渐隐的高度直接用它，块里再多一行点也不会露出封面。
        // 之前这条量在了圆点那行上，量到的是圆点胶囊的 14，渐隐就只剩十几点、
        // 看着像整条没了（Colo 2922 那一版起就一直在犯）。
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { textBlockHeight = $0 }
    }

    private var actions: some View {
        Group {
            if compactColumn {
                // C 档左栏 210 宽（6888 规格）：继续观看通栏到内缩线，收藏贴右缘 16。
                // 单栏那套是「胶囊居中、收藏浮在右缘」，在 210 宽里两个框会叠在一起（LP 6901）。
                // Ato 6936：胶囊独占一行、整宽 178；收藏挪到圆点那一行右侧（见 textBlock）。
                playButton(expanded: true)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
            } else {
                ZStack {
                    playButton()

                    HStack {
                        Spacer()
                        followButton
                            .padding(.trailing, 16)
                    }
                }
            }
        }
        .frame(minHeight: 40)
    }

    /// 卡片版面里胶囊要通栏：384 = 436（24…460）减掉圆钮 40 和 12 点缝（Ato 6724）。
    /// 宽度必须撑在胶囊自己的底色里面——撑在外面时胶囊还是按字宽画、居中悬着（Fuck 6723 量到 126 宽）。
    private func playButton(expanded: Bool = false) -> some View {
        Button {
            guard let poster = current else { return }
            openSources(poster)
        } label: {
            Label(playTitle, systemImage: "play.fill")
                .font(.subheadline.weight(.semibold))
                // 跟详情页「开始观看」使用同一语义前景色，随深浅模式切换。
                .foregroundStyle(KazumiPalette.onAccent(for: colorScheme))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .frame(maxWidth: expanded ? .infinity : nil, minHeight: 40)
                .background(Capsule().fill(KazumiPalette.accent(for: colorScheme)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playTitle)
        .accessibilityHint("选择播放源")
    }

    /// 三个名字全 App 统一（Camo 2950）：没记录「开始观看」、看了一半「继续观看」、
    /// 看完了「重新观看」——最后一档原来也叫「开始观看」，跟历史页的「重新观看」撞了。
    private var playTitle: String {
        guard let id = current?.id, let record = library.record(for: id) else { return String(localized: "开始观看") }
        return record.isFinished ? String(localized: "重新观看") : String(localized: "继续观看")
    }

    /// 收藏圆钮：玻璃底 ＋ 一层轻投影（Colo 2864 / 2866），压在封面上也要托得出来。
    private var followButton: some View {
        Button {
            guard let poster = current else { return }
            bounceFollow()
            Task { await toggleFollow(poster) }
        } label: {
            Image(systemName: collectType == .none ? "plus" : collectType.statusSymbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                // 画 40（Ato 6756：24 + 384 + 12 + 40 = 460，胶囊右边才落在 408）。
                .frame(width: 40, height: 40)
                .kazumiGlassCapsule(interactive: true)
                .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
                // 热区 44（Colo 6757 / HIG），但布局仍按 40 排：
                // 正负各 2 点，点得到的地方大一圈，占的地方不变。
                .padding(2)
                .contentShape(Rectangle())
                .padding(-2)
        }
        .buttonStyle(.plain)
        .scaleEffect(followScale)
        .disabled(isToggling)
        .accessibilityLabel(collectType == .none ? "收藏" : "已\(collectType.title)")
        .accessibilityValue(collectType.title)
        .accessibilityHint("切换追番状态")
    }

    // MARK: - 圆点

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(items) { poster in
                let selected = poster.id == (currentID ?? items.first?.id)
                Capsule(style: .continuous)
                    // LP 3503／Colo 3505：未选中的点跟页面底色对着来——
                    // 浅色页面白底，用黑 50%；深色页面深灰，用白 50%。
                    // 原来写死黑 55%，深色下等于看不见。
                    .fill(selected ? KazumiPalette.accent(for: colorScheme)
                                   : (colorScheme == .dark ? Color.white.opacity(0.50)
                                                           : Color.black.opacity(0.50)))
                    .frame(width: selected ? 18 : 6, height: 6)
            }
        }
        // LP 3503：圆点底下那条胶囊底删掉，点直接压在封面上。
        .frame(height: 14)
        .animation(.easeOut(duration: 0.2), value: currentID)
    }

    // MARK: - 顶栏

    /// 顶栏：左边的大标题点开选标签（原版就是它），右边搜索和观看历史。
    /// 它是封面块最上面那一层 overlay，跟着封面一起滚（LP 2865 / Colo 2866）。
    @ViewBuilder
    private var topBar: some View {
        HStack(alignment: .center, spacing: 10) {
            // LP 3044：首页几页大标题都收成两个字，这页就是「推荐」。
            // 原来挂在标题上的「热门番组」标签菜单挪到了下面第一行货架（见 PopularScreen）。
            Text("推荐")
                .font(.largeTitle.weight(.semibold))
                // 34 半粗、字距 −0.4（Colo 3032）。
                .tracking(-0.4)
                // 压在封面上的字得有一层才读得清（Colo 2864）：就这一层，别更重。
                .shadow(color: .black.opacity(0.30), radius: 8, y: 1)
                // 恒定白（LP 7275 / Colo 7279）：不随系统深浅色变，不是语义色。
                .foregroundStyle(Color.white)
                .accessibilityAddTraits(.isHeader)

            Spacer()

            circleButton(symbol: "magnifyingglass", label: "搜索") {
                router.push(.search(keyword: ""))
            }
            circleButton(symbol: "clock", label: "观看历史") {
                router.push(.history)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: TopBarHeightKey.self, value: proxy.size.height)
            }
        )
    }

    /// 顶栏那两颗圆钮：36 玻璃正圆、命中区给到 44（Colo 2864 / 2866）。
    /// 玻璃就是全 App 那一套 `kazumiGlassCapsule`（iOS 26 上只有系统 `glassEffect`），
    /// 跟详情页返回 / 更多同一副面孔，不在这儿另立一份。
    ///
    /// 不压 tint、不加投影（LP 2897 / Colo 2898）：上一版为了让它透出封面压了一层
    /// 黑 tint，结果看着是两颗黑圆；发亮的根子在垫底那层材质上，已经在 `LiquidGlass`
    /// 里按系统版本分开了，这里不用再补任何颜色。
    private func circleButton(symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                // 跟时间表那颗统一到 40 正圆、图标 20（Colo 3061 的「统一 40」）。
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .kazumiGlassCapsule(interactive: true)
        }
        .buttonStyle(.plain)
        // 画 36，点按区域给到 44。
        .hitTarget44()
        .accessibilityLabel(label)
    }

    // MARK: - 动作

    /// 「开始观看」：与番剧详情页那颗按钮同一条路（LP 2903 / 2904 / Colo 2907）——
    /// 弹同一张「选择播放源」面板（`SourceSheet`），在那里选源、进去开播；
    /// 播哪一话、用哪条规则全由播放器自己按观看记录接上，与详情页一致。
    ///
    /// 面板要一个 `InfoController`，所以先把条目备齐：缓存优先（从列表/以前进过
    /// 详情页都有），没有才请求一次。同一部番点第二次直接用已经建好的那份。
    private func openSources(_ poster: PopularPoster) {
        if let controller = sourceController, controller.item.id == poster.id {
            presentSources(controller)
            return
        }
        // 点这颗钮不需要网络，也就不能等网络（LP 3665）：有缓存就用缓存，
        // 没有就先用列表里那份名称把面板打开。面板里的检索本来就要联网，
        // 没网时在那儿失败、在那儿提示，不挡面板弹出来。
        // 详情信息由面板自己按需补（`loadDetailIfNeeded`），补回来会换上。
        // 启动后第一次点这颗钮，白屏的账几乎全在「读盘」上：`item(for:)` 和
        // `applyCachedEpisodes()` 都会去 Application Support 里读文件，读的时候
        // 主线程停着，面板就一直是白的（LP 2026-10-28「第一次启动点推荐页的
        // 开始观看会白几秒」）。所以这一下只碰内存：有就用，没有就拿列表里那份
        // 名称先把面板弹出来，磁盘里的两份放到面板出来之后补（都是一样的字段，
        // 补回来面板自己会重画）。
        SheetTiming.tap = SheetTiming.now
        SheetTiming.bodyFirst = 0
        SheetTiming.listFirst = 0
        SheetTiming.appear = 0
        SheetTiming.ready = 0
        let item = BangumiSubjectCache.shared.memoryItem(for: poster.id)
            ?? BangumiItem(id: poster.id, name: poster.name, nameCn: poster.nameCn)
        let controller = InfoController(item: item, plugins: environment.plugins)
        if let cachedEpisodes = BangumiSubjectCache.shared.memoryEpisodes(for: poster.id),
           controller.episodes.isEmpty {
            controller.replaceEpisodes(cachedEpisodes)
        }
        sourceController = controller
        SheetTiming.ready = SheetTiming.now
        presentSources(controller)
        // 这里不能顺手读盘：`Task { @MainActor }` 会在这一拍结束时立刻跑，
        // 读的还是主线程、还是赶在面板上屏之前——量出来「点下去→面板开始画」
        // 就是这 4 秒（2026-10-28 计时：b4035ms）。剧集和条目由面板自己按需补
        // （`loadDetailIfNeeded` 和检索结果），这条路上一次磁盘读都不做。
    }

    /// 把面板交给根层去弹：这里只给控制器和两个回调，不动这一页的布局。
    private func presentSources(_ controller: InfoController) {
        guard router.pendingExternalLink == nil else { return }
        sourceNavigationRevision = router.externalNavigationRevision
        let revision = router.externalNavigationRevision
        SourceSheetCoordinator.shared.present(
            controller: controller,
            onPlay: { pluginName, result in
                guard revision == router.externalNavigationRevision,
                      router.pendingExternalLink == nil else { return }
                SourceSheetCoordinator.shared.dismiss()
                returnToSourcesAfterPlayer = true
                depthBeforePlayer = navigationDepth
                // 跟详情页「开始观看」一个口径：这部剧在这条规则上看到哪就从哪起。
                let point = library.resumePoint(for: controller.item.id, pluginName: pluginName)
                router.push(
                    .player(
                        bangumiID: controller.item.id,
                        episode: point?.episode ?? 1,
                        source: PlaybackSource(
                            pluginName: pluginName,
                            itemName: result.name,
                            // 原样传 src：接口模式要的是 vod_id，拼成网址就查不到剧集。
                            detailURL: result.src,
                            directMediaURL: MediaUtility.isMediaURL(result.src) ? result.src : nil
                        ),
                        resumeRoad: point?.road,
                        resumeFromHistory: true,
                        resumeRule: nil
                    )
                )
            },
            onOpenRuleShop: {
                guard revision == router.externalNavigationRevision,
                      router.pendingExternalLink == nil else { return }
                // 面板自己关，这里只记下来，等它关完再推页。
                goToRuleShopAfterDismiss = true
                SourceSheetCoordinator.shared.dismiss()
            }
        )
    }

    /// 收藏圆钮：轻点是「在看 ↔ 未收藏」两态切换。
    ///
    /// 口径与详情页那颗钮一致（`BangumiInfoScreen.collect`）：自动同步开着就推
    /// Bangumi，推不成功整次作废。其余状态（想看 / 搁置 / 看过 / 抛弃）在详情页的
    /// 状态菜单里选——这里只留一个「快速」入口，不铺一整排。
    private func toggleFollow(_ poster: PopularPoster) async {
        guard !isToggling else { return }
        isToggling = true
        defer { isToggling = false }

        let next: CollectType = collectType == .none ? .watching : .none
        let syncEnabled = settings.bangumiSyncEnable
        guard syncEnabled else {
            applyCollect(poster, next)
            withAnimation { toastMessage = toastText(for: next) }
            scheduleToastClear()
            return
        }
        let pushed = await environment.bangumiSync.pushCollectible(bangumiID: poster.id, type: next)
        guard pushed else {
            withAnimation { toastMessage = "同步到 Bangumi 失败，已取消本次状态修改" }
            scheduleToastClear()
            return
        }
        applyCollect(poster, next)
        withAnimation { toastMessage = toastText(for: next) }
        scheduleToastClear()
    }

    /// 按下去弹一下：缩到 0.8 再回弹，120 毫秒（Colo 2803）。
    private func bounceFollow() {
        withAnimation(.easeInOut(duration: 0.12)) { followScale = 0.8 }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.55).delay(0.12)) { followScale = 1 }
    }

    /// 报一句状态：加的那下说状态名（在看），取消的那下用菜单里那一项的字（Camo 2805）。
    private func toastText(for type: CollectType) -> String {
        type == .none ? "已取消追番" : "已标为\(type.title)"
    }

    private func applyCollect(_ poster: PopularPoster, _ type: CollectType) {
        if type == .none {
            library.remove(bangumiID: poster.id)
            BangumiTimelineStore.shared.dropIfNotWatching(poster.id, collectType: .none)
            return
        }
        library.upsert(
            LibraryEntry(
                id: poster.id,
                type: type.rawValue,
                name: poster.name,
                nameCn: poster.nameCn,
                summary: poster.summary,
                airDate: poster.airDate,
                imageURL: poster.imageURL,
                rating: poster.rating,
                rank: 0,
                tags: [],
                totalEpisodes: poster.totalEpisodes,
                currentEpisode: 0,
                addedAt: library.entry(for: poster.id)?.addedAt ?? Date(),
                updatedAt: Date()
            )
        )
        BangumiTimelineStore.shared.dropIfNotWatching(poster.id, collectType: type)
    }

    private func scheduleToastClear() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            withAnimation { toastMessage = nil }
        }
    }

    /// 提示语摆在顶栏下沿再让 12：顶栏自己跟着封面滚，所以它的高度得量出来。
    private var toastOffset: CGFloat {
        Self.statusBarHeight + topBarHeight + 12
    }

    /// 状态栏那一截的高度：顶栏要压在它下面。
    ///
    /// 这里不用 GeometryReader 读 `safeAreaInsets`：封面为了铺到屏幕顶，给滚动区加了
    /// `ignoresSafeArea(edges: .top)`，加完之后在里面读到的顶部内边距是 0。
    /// 直接问窗口的状态栏拿，与列表页读屏宽是同一套写法。
    private static var statusBarHeight: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.statusBarManager?.statusBarFrame.height ?? 44
    }

    private var background: Color {
        KazumiPalette.background(for: colorScheme)
    }
}

/// 顶栏本体的实际高度：提示语要落在它下面，所以量一下。
/// 宽档版面的顶栏：标题在左、两颗圆钮在右，压在白底上，深色字（Colo 6725）。
/// 不做背板——要在封面上压到 4.5:1 就得盖 70% 的黑，那是给封面加一条黑板。
struct PopularWideTopBar: View {
    /// 标题左边到栏左缘的距离：横屏那栏要 16（x=500），竖屏那栏是 0（x=677，跟信息块齐）。
    var leadingPadding: CGFloat = 16

    @Environment(AppRouter.self) private var router

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("推荐")
                .font(.largeTitle.weight(.semibold))
                .tracking(-0.4)
                // 恒定白（LP 7275 / Colo 7279）：与窄档标题同一套，不随系统深浅色变。
                .foregroundStyle(Color.white)
                // 白字得有一层才读得清（Colo 2864），两档同一层。
                .shadow(color: .black.opacity(0.30), radius: 8, y: 1)
                .accessibilityAddTraits(.isHeader)

            Spacer()

            PopularTopBarCircle(symbol: "magnifyingglass", label: "搜索") {
                router.push(.search(keyword: ""))
            }
            PopularTopBarCircle(symbol: "clock", label: "观看历史") {
                router.push(.history)
            }
        }
        .padding(.leading, leadingPadding)
        .padding(.trailing, 16)
    }
}

/// 顶栏那两颗圆钮：40 正圆、图标 20、命中区 44（Colo 3061）。
/// 手机压在封面上、iPad 压在右栏白底上，是同一副面孔。
struct PopularTopBarCircle: View {
    let symbol: String
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                // 图标恒白（LP 7275 / Colo 7279）。
                .foregroundStyle(Color.white)
                .frame(width: 40, height: 40)
                .kazumiGlassCapsule(interactive: true)
                // 玻璃固定取深色那一档（LP 7277 / Colo 7279）：让系统 glassEffect
                // 按深色档渲染，不用 tint 压黑（tint 只是色罩，出不来深玻璃）。
                .environment(\.colorScheme, .dark)
        }
        .buttonStyle(.plain)
        .hitTarget44()
        .accessibilityLabel(label)
    }
}

private struct TopBarHeightKey: PreferenceKey {
    // 必须是 `let`：`var` 在严格并发下是非隔离的全局可变状态，编译不过。
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}


/// 英雄行里文字块占的宽度，由推荐页按容器宽算好传进来（Colo 6687 §3.2 / §4.2）。
private struct PopularHeroTextWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 280
}

extension EnvironmentValues {
    var popularHeroTextWidth: CGFloat {
        get { self[PopularHeroTextWidthKey.self] }
        set { self[PopularHeroTextWidthKey.self] = newValue }
    }
}
