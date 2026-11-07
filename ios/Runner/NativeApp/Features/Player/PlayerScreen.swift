//
//  PlayerScreen.swift
//  Kazumi
//
//  对应 lib/pages/video/video_page.dart 的原生实现：
//  * 顶部 16:9 播放区（KSPlayer 基础画面 + 弹幕层），浮着返回与标题；
//  * 播放条：播放 / 暂停、进度、弹幕开关、超分辨率、倍速；
//  * 下方是线路与分集切换，解析中显示进度与解析日志，失败时给出原因与重试。
//

import AVFoundation
import AVKit
import MediaPlayer
import SwiftUI
import UIKit

/// 视频比例（对应原版 `lib/pages/player/controller/player_aspect_ratio.dart` 的四档）。
/// 与原版一样，播放器里的选择只在本次播放内生效，不写回设置。
enum PlayerAspectRatioMode: String, CaseIterable, Identifiable {
    case automatic
    case crop
    case stretch
    case ratio4x3

    var id: String { rawValue }

    /// 与原版 `PlayerAspectRatio.label` 逐字一致。
    var label: String {
        switch self {
        case .automatic: String(localized: "自动")
        case .crop: String(localized: "裁切填充")
        case .stretch: String(localized: "拉伸填充")
        case .ratio4x3: "4:3"
        }
    }

    /// 播放区本身的宽高比：只有 4:3 会换盒子，其余沿用 16:9。
    var frameAspectRatio: CGFloat {
        self == .ratio4x3 ? 4.0 / 3.0 : 16.0 / 9.0
    }

    /// 交给 mpv 渲染层的填充方式。
    var fillMode: MPVPlayerContainer.MPVFillMode {
        switch self {
        case .automatic, .ratio4x3: .fit
        case .crop: .crop
        case .stretch: .stretch
        }
    }

    var videoAspectOverride: String {
        self == .ratio4x3 ? "4:3" : "no"
    }

    /// 交给 AVPlayerLayer 的填充方式（原版 `BoxFit` 的等价物）。
    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .automatic: .resizeAspect
        case .crop: .resizeAspectFill
        case .stretch, .ratio4x3: .resize
        }
    }
}

/// 画面下面那一片的两个页：左边选集（线路 + 集数），右边这部番的吐槽。
enum PlayerDetailTab: String, CaseIterable, Identifiable {
    case episodes = "选集"
    case comments = "评论"

    var id: String { rawValue }
}

/// 「更多」面板里的三页：主列表和两个二级页（定时关闭 / 超分辨率 / 画面比例）。
/// 用 popover 自己翻页，不依赖 Menu 的嵌套菜单——那样菜单一开就没法挡自动隐藏。
/// 更多菜单里能打开的那几个页面，一次只有一张。
enum PlayerSheet: String, Identifiable {
    case danmakuSettings
    case danmakuSource
    case airPlay
    case externalPlay
    case syncPlay
    case videoInfo

    var id: String { rawValue }
}

/// 一次竖滑浮层要显示的内容：调的是亮度还是音量，现在到多少。
struct GestureHUDValue: Equatable {
    enum Kind { case brightness, volume }

    var kind: Kind
    var value: Double

    /// 横条左边那颗 15pt 图标，**跟着档位换**（LP 4876）：
    /// 音量 0 是静音，往上依次加一道声波；亮度低半颗小太阳、高半颗大太阳。
    var symbol: String {
        // 先夹到 0–1 再分档（Colo 4879）：拖到负数会落进最大那档。
        let level = max(0, min(1, value))
        switch kind {
        // 亮度两档，对半。
        case .brightness:
            return level <= 0.5 ? "sun.min.fill" : "sun.max.fill"
        // 音量四档，分界 1/3、2/3。
        case .volume:
            if level <= 0 { return "speaker.slash.fill" }
            if level <= 1.0 / 3.0 { return "speaker.wave.1.fill" }
            if level <= 2.0 / 3.0 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        }
    }

    /// 这颗符号自己的颜色（LP 4876 给的色）：音量 #00C0E8、亮度 #FFCC00，
    /// 轨道和数值仍是白的。
    var symbolColor: Color {
        switch kind {
        case .brightness: return Color(red: 1.0, green: 0.8, blue: 0.0)
        case .volume: return Color(red: 0.0, green: 0.7529, blue: 0.9098)
        }
    }
}

/// 画面这一次拖动调的是哪一路（起手时定死，中途不改）。
enum DragAxis {
    case seek
    case brightness
    case volume
    /// 贴着左边缘往右拖：这是侧滑返回，画面手势这一路什么都不做。
    case ignored
}

/// 系统音量：改音量时 iOS 自己会在屏幕边上弹那条音量浮条，所以这里只负责换算，
/// 不再画第二条（两条叠在一起是原版被吐槽的地方）。
@MainActor
final class PlayerVolumeControl {
    static let shared = PlayerVolumeControl()

    /// MPVolumeView 内部的音量滑杆；拿到之后系统音量就能直接写。
    weak var slider: UISlider?

    /// 刚由我们写下去的那一拍：这期间观察到的音量变化是回声，不是按了键。
    private(set) var isWriting = false

    var current: Double {
        if let slider = liveSlider() { return Double(slider.value) }
        return Double(AVAudioSession.sharedInstance().outputVolume)
    }

    func set(_ value: Double) {
        guard let slider = liveSlider() else { return }
        let clamped = Float(min(1, max(0, value)))
        slider.value = clamped
        isWriting = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            isWriting = false
        }
        // 两种事件都发：不同 iOS 版本认的不一样，只发一种常常写了不生效。
        slider.sendActions(for: .valueChanged)
        slider.sendActions(for: .touchUpInside)
    }

    /// **每次都现找一个活着的滑杆**（LP 2026-10-28 实机「调过一次之后上下都滑不动」）：
    /// MPVolumeView 内部的滑杆会随着系统音量浮层、视图重建被换掉，早先缓存的
    /// 那个 weak 引用一旦是旧对象，写进去既不改音量也不报错——表现就是第一下能调、
    /// 之后两个方向都没反应。这里只认「还挂在窗口上」的那一个。
    private func liveSlider() -> UISlider? {
        if let slider, slider.window != nil { return slider }
        slider = nil
        guard let found = Self.searchSlider() else { return nil }
        slider = found
        return found
    }

    /// 在窗口里找 MPVolumeView 的滑杆；一个都没有就自己挂一个再找。
    static func searchSlider() -> UISlider? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        for window in windows {
            if let view = findVolumeView(in: window), let slider = findSlider(in: view) {
                return slider
            }
        }
        // 视图树里没有：往 key window 上挂一个（1×1、几乎透明），下次就能找到。
        for window in windows where window.isKeyWindow {
            let view = MPVolumeView(frame: CGRect(x: -20, y: -20, width: 1, height: 1))
            view.showsRouteButton = false
            view.alpha = 0.01
            window.addSubview(view)
            return findSlider(in: view)
        }
        return nil
    }

    private static func findVolumeView(in view: UIView) -> MPVolumeView? {
        if let volume = view as? MPVolumeView { return volume }
        for child in view.subviews {
            if let found = findVolumeView(in: child) { return found }
        }
        return nil
    }

    private static func findSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        for child in view.subviews {
            if let found = findSlider(in: child) { return found }
        }
        return nil
    }
}

/// 把 MPVolumeView 塞进视图树（1×1、几乎全透明），只为拿到它的音量滑杆。
private struct SystemVolumeHost: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.showsRouteButton = false
        view.alpha = 0.01
        // 滑杆不一定直接是第一层子视图，交给统一的递归查找（可能晚一两拍才装上，重试几次）。
        for delay in [0, 0.15, 0.4, 0.9] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                _ = PlayerVolumeControl.searchSlider()
            }
        }
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

struct PlayerScreen: View {
    var bangumiID: Int
    var episode: Int
    var source: PlaybackSource?
    /// 续播信息（见 `AppRoute.player`）：上次那条线路，以及这次是不是「接着看」。
    var resumeRoad: Int?
    var resumeFromHistory: Bool = false
    /// 历史卡片带过来的规则名：重建播放源时按这一条取，别按番剧号取「最新那份」。
    var resumeRule: String?

    @State private var controller: PlayerController?
    /// Diagnostic identity only; it does not participate in navigation or playback.
    @State private var diagnosticPlayerID = String(UUID().uuidString.prefix(8)).lowercased()
    @State private var surface = PlayerSurfaceModel()
    /// 交给播放内核的代理（LP 5331：设置里手填的那个）。nil = 不走。
    /// 不现取：得在「开关或地址端口改了 / 回前台」时才重读一次。
    @State private var proxyURL: String?
    @State private var danmakuEnabled = true
    /// 横屏底栏那个发弹幕的输入框：草稿、焦点。
    /// 画面量出来的宽度：横屏两行底栏按它判断。
    @State private var surfaceWidth: CGFloat = 0
    /// 播放区所在容器的尺寸（全屏时要按它铺满，见 `boxAspectRatio`）。
    @State private var containerSize: CGSize = .zero
    /// 播放页四周的安全区内缩（全屏时画面要绕过刘海，按它算窗口尺寸）。
    @State private var containerInsets = EdgeInsets()
    /// 上一次转屏请求的结果，显示在「播放信息」里（Colo 2026-10-28）：
    /// 分得清是系统没给（被拒＋原因），还是我们没请求（一直「未请求」）。
    @State private var lastOrientationResult = String(localized: "未请求")
    @State private var danmakuDraft = ""
    @FocusState private var danmakuFieldFocused: Bool
    /// 这一次的暂停是「输入弹幕」引起的：收键盘后只恢复这一种（上游 2.4.0 #2708）。
    @State private var pausedForDanmakuInput = false
    @State private var playbackRate: Float = 1.0
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    /// 拖动时手指在进度条上的横坐标（点），目标时间跟它走。
    @State private var scrubFingerX: CGFloat = 0
    @State private var isEditingSkipSeconds = false
    @State private var skipSecondsInput = ""
    @State private var skipSecondsError: String?

    // 本批新增：画面比例、控制栏自动隐藏、锁定、长按临时倍速。
    @State private var aspectRatioMode: PlayerAspectRatioMode = .automatic
    @State private var controlsVisible = true
    /// 「正在播放」的节拍计数：250 毫秒一轮，凑到 8 轮（2 秒）同步一次。
    @State private var nowPlayingTick = 0
    /// 上一次看到的「别的 App 占着音频会话吗」。只在变了的时候写一行日志（LP 4976）。
    @State private var lastOtherAudioPlaying: Bool?
    /// 这一集是「因为切到后台才停下的」吗——只有这种暂停才在回前台时自动接上，
    /// 用户自己按的暂停不算（LP 2026-10-29「回到前台自动播放」）。
    @State private var pausedByBackground = false
    /// 后台自动画中画。设置关着时一直是 nil：不建图层、不建控制器、不碰软件渲染。
    @State private var pictureInPicture: PictureInPictureController?
    /// 投屏进行中：画中画与投屏互斥，这颗按钮置灰并给出读屏原因。
    @State private var isCasting = false
    /// 「更多」/ 倍速面板：自己握开关，好让控制层知道菜单还开着。
    ///
    /// 系统菜单不把开合告诉代码，所以另挂了一个 `SystemMenuProbe` 看它在不在，
    /// 下面的 `.task` 靠它把「菜单已经收了」这件事认出来。
    /// 每次交互 +1，body 上的 `.task(id:)` 据此取消上一轮自动隐藏并重新计时。
    @State private var hideGeneration = 0
    /// 「更多」菜单开着：开着的时候不自动收控制栏，否则菜单会变成一张点不动的死图。
    @State private var menuOpen = false
    @State private var menuOpenedAt = Date()
    @State private var probeSawMenu = false
    @State private var probeLastSeen = Date()
    /// 画面锁（LP 2026-10-28 第 4 条）：锁上手势全不响应，只留「点一下把
    /// 左边缘那颗锁定钮叫出来」。锁定钮在画面左边缘、截图钮在右边缘，
    /// 跟快退 / 快进那两颗同一行（竖向居中）。
    @State private var isSurfaceLocked = false
    /// 锁着时点一下只把解锁那一颗浮出来几秒——这是唯一的解锁入口。
    @State private var unlockAffordanceShown = false
    @State private var unlockAffordanceTask: Task<Void, Never>?
    /// 截图那一下的取景框动画进度（0 → 1 走一遍）。
    @State private var screenshotFlash: CGFloat = 0
    @State private var screenshotFlashTask: Task<Void, Never>?
    /// 收藏钮点下去的缩放（Colo 2026-10-28：0.15 秒的 spring 弹一下）。
    /// 切超分档位时在 1/4 那条线上提示一下（Colo 2026-10-28）。
    @State private var superResolutionHUD: String?
    @State private var superResolutionHUDTask: Task<Void, Never>?
    @State private var isTemporarySpeed = false
    @State private var rateBeforeTemporarySpeed: Float = 1.0
    /// 按住画面那一下的计时：手指一落下就开始数，到点就倍速。
    @State private var surfacePressTask: Task<Void, Never>?
    /// 转屏只留一条请求链：新请求先把旧的取消，旧的每一步先核对自己的代号
    /// 还是不是最新的（LP 2026-10-28「横屏切回竖屏后再也横不了」的正解）。
    @State private var orientationRequestTask: Task<Void, Never>?
    @State private var orientationGeneration = 0
    /// 系统拒绝转屏时的那句原话（回调在后台队列上到，见 `OrientationFailure`）。
    @State private var orientationFailure = OrientationFailure()
    /// 布局看到竖屏时先等它稳住再退全屏，别打断正在进行的转屏。
    @State private var landscapeExitTask: Task<Void, Never>?
    /// 本次按压是否已经进入长按状态（用来区分「松手时是短按还是长按结束」）。
    /// 全屏：画面占满窗口、横屏、隐藏状态栏，选集与线路区收起。
    /// 对应原版 `fillsWindow = fullscreen || (maxWidth > maxHeight)`。
    @State private var isFullscreen = false
    /// 这一轮全屏里是否真的横过屏；用来区分「刚进来还没转」和「用户转回去了」。
    @State private var sawLandscape = false
    /// 亮度 / 音量的横条浮层：左半边调亮度、右半边调音量，都自己画。
    @State private var gestureHUD: GestureHUDValue?
    /// 音量键的监听：它只当触发，画的是手势那条浮层（LP 2026-11-06）。
    @State private var volumeObserver: NSKeyValueObservation?
    /// 横滑调进度时中间那朵「+15s」。
    @State private var seekHUD: Int?
    /// 双击中间那朵播放 / 暂停符号。
    @State private var playPauseHUD: String?
    /// 这一串拖动在调什么：进度、亮度还是音量。起手时按方向定死，中途不再改。
    @State private var dragAxis: DragAxis?
    /// 起手那一刻的亮度或音量。
    @State private var dragValueStart: Double?
    /// 横滑起手时这一集的进度，以及滑到哪儿（松手才真 seek）。
    @State private var seekDragStart: Double?
    @State private var seekDragTarget: Double?
    /// 浮层淡出的定时器，下一次滑动会把它作废重排。
    @State private var hudHideTask: Task<Void, Never>?
    /// 最近一次长按触发的时间：长按松手后系统仍会补一次短按，用它挡掉。
    @State private var lastLongPressAt: Date?
    /// 画面下面那片选中的页。
    @State private var detailTab: PlayerDetailTab = .episodes
    /// 这部番的吐槽（按需加载，进页面不拉）。
    @State private var comments: [BangumiCommentItem] = []
    @State private var commentTotal = 0
    @State private var isLoadingComments = false
    @State private var commentRequestGeneration = 0
    @State private var commentLoadFailed = false
    /// 评论：最新优先还是最早优先；切换时只在本地重排，不再请求。
    @State private var isCommentsAscending = false
    /// 当前看的是哪一集的评论（nil 就是整部番），切集时用。
    @State private var commentEpisode: Int?
    /// 100 集以上时，快速跳到某一块（每 100 集一块）。
    @State private var episodeGridPage = 0
    /// 下载选择态（LP 5084 / Colo 5090）：true 时面板顶行换成 取消 / 全选 / 下载 N 集，
    /// 格子点一下是勾选而不是切集。不弹窗，面板原地变。
    @State private var isChoosingDownloads = false
    /// 选择态里勾中的集数。
    @State private var downloadSelection: Set<Int> = []
    /// 更多菜单里几个「开个页面」的入口。收到一个枚举里，
    /// 一次只可能有一张：几个布尔各自为真时后弹的那张会被系统吞掉。
    @State private var activeSheet: PlayerSheet?
    /// 「播放信息」里点了媒体地址后的「已复制」提示，1.2 秒后自动收回。
    @State private var mediaURLCopied = false
    @State private var mediaURLCopiedTask: Task<Void, Never>?
    /// 横屏选集：从右侧滑进来的玻璃窗口（LP 3637 要的，不再是铺满整屏的面板）。
    @State private var showsEpisodesPanel = false
    /// 定时关闭：还剩多少秒，nil 就是没定。
    @State private var sleepTimerRemaining: Int?
    @State private var sleepTimerChosenMinutes: Int?
    @State private var sleepTimerTask: Task<Void, Never>?
    /// 片头片尾弹窗：AniSkip 的时间轴 + 倒数 / 撤销 / 切集三态。
    @State private var skipPill = SkipSegmentPillModel()

    @Environment(AppEnvironment.self) private var environment
    @Environment(SettingsStore.self) private var settings
    /// 主题色分深浅两档，菜单跟着走（Colo 3344）。
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    /// 由现有 UIScene 通知维护的播放策略标志；诊断另外读取实际 activationState。
    @State private var sceneIsActive = true

    /// 画面那一半（body 的前半截）。
    ///
    /// 从 body 里拆出来的：整条修饰符链太长，编译器的类型检查会超时
    /// （`unable to type-check this expression in reasonable time`）。
    /// 拆成两段后各段单独求解，逻辑一行没改。
    private var playbackScaffold: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Group {
                if let controller {
                // 全屏与竖屏用同一棵树，只把下面那块收起来：
                // 分成两支的话，切全屏时 SwiftUI 会把播放器整个拆掉重建，
                // 画面从 0 重新起播（LP 3624「切全屏进度归零」）。
                // 铺满还是 16:9 由画面自己的 PlayerBoxModifier 决定。
                VStack(spacing: 0) {
                    playerArea(controller)
                    if !isFullscreen {
                        episodeArea(controller)
                    }
                }
            } else {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // 横屏选集：右侧滑进来的玻璃窗口（LP 3637）。
            // 左边压暗一层，点它就收；不铺满整屏，画面还看得见。
            if showsEpisodesPanel, let controller {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { closeEpisodesPanel() }

                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    episodesPanel(controller)
                }
                // 贴死右边缘，别被右侧安全区内缩出一截黑
                // （LP 2026-10-27，Colo §14.5）。
                .ignoresSafeArea(.container, edges: .trailing)
                .transition(.move(edge: .trailing))
            }
        }
        }
        .animation(.easeOut(duration: 0.12), value: showsEpisodesPanel)
        .background(Color.black.ignoresSafeArea())
        // 竖屏全屏不做：先真的横过屏，之后用户又转回竖屏，才退出全屏。
        // 只看「现在是不是竖的」会误判——刚点全屏、屏幕还没来得及转的那一帧
        // 本来就是竖的，那样一进就被自己的判据弹出来（LP 2026-10-25 现场）。
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        logLifecycleSnapshot("onAppear")
                        containerSize = proxy.size
                        containerInsets = proxy.safeAreaInsets
                    }
                    .onChange(of: proxy.size) { _, size in
                        containerSize = size
                        containerInsets = proxy.safeAreaInsets
                        if size.width > size.height {
                            sawLandscape = true
                            landscapeExitTask?.cancel()
                            landscapeExitTask = nil
                        } else if isFullscreen, sawLandscape {
                            sawLandscape = false
                            // 等竖屏稳住再退：转屏途中会报几帧中间尺寸，见一帧竖的
                            // 就退全屏会把正在进行的转屏打断（@developer3 4308 的第四条）。
                            landscapeExitTask?.cancel()
                            landscapeExitTask = Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(400))
                                guard !Task.isCancelled, isFullscreen, sawLandscape == false,
                                      containerSize.width <= containerSize.height
                                else { return }
                                exitFullscreen()
                            }
                        }
                    }
            }
        }
        .statusBarHidden(isFullscreen)
        // 全屏连 home 指示条一起藏：LP 2026-10-29 定这里保持原样（不动这一行）。
        // 「上滑退 app 要两下」改在手势那侧：画面最底下那条起手让给系统。
        .persistentSystemOverlays(isFullscreen ? .hidden : .automatic)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        // 播放器页面范围内把 tint 压回系统黑白：AppRoot 那句全局 .tint(accentColor)
        // 会顺着 tint 环境传到菜单行上，菜单的符号就变主题色
        // （LP 2026-10-28；Colo 4282 / @developer3）。选集、评论那几颗菜单
        // 在行上显式写了自己那份主题色，不受这句影响。
        .tint(.primary)
        .overlay(alignment: .top) { toastView }
        .overlay { skipSecondsDialog }
        .sheet(item: $activeSheet) { sheet in
            sheetContent(sheet)
        }
    }

    var body: some View {
        screenLifecycleObservers
    }

    /// 第一段修饰符：提示气泡、全屏、播放状态、进度条。
    ///
    /// 这一串拆成几段，是因为整条链放在一个表达式里，编译器的类型检查会超时
    /// （「unable to type-check this expression in reasonable time」）。
    private var contentObservers: some View {
        playbackScaffold
        // 竖屏侧滑返回：导航栏藏了之后系统的手势会失效，这里把它接回来（全屏时不认）。

        .animation(.easeOut(duration: 0.2), value: surface.toastMessage)
        .animation(.easeOut(duration: 0.2), value: surface.hudToastMessage)
        // 弹幕拉不到的时候说一句原因（Ato：对不上号 / 接口失败要说，
        // 「这集本来就没弹幕」是正常情况，安静地不显示）。
        // 「看到 90% 自动标为看过」成了也说一句，跟倍速/收藏同一处（1/4 那条线）。
        .onChange(of: environment.bangumiProgress.markedNotice) { _, message in
            if let message, !message.isEmpty {
                surface.hudToastMessage = message
            }
        }
        // 下载失败说一句带原因的（LP 5115）：格子上不再挂红点，改成弹一下。
        .onChange(of: environment.downloads.failureNotice) { _, message in
            guard let message, !message.isEmpty else { return }
            surface.hudToastMessage = message
            environment.downloads.failureNotice = nil
        }
        // 进页面 / 切线路把剧集列表重新拉一遍时，上一轮的失败痕迹一并清掉，
        // 格子回到「没下过」（LP 5115）。
        .onChange(of: controller?.currentEpisode) { _, _ in
            playPauseHUD = nil
            if let controller {
                environment.downloads.clearFailures(recordKey: downloadRecordKey(controller))
            }
        }
        .onChange(of: controller?.danmakuMessage) { _, message in
            if let message, !message.isEmpty {
                // 放画面 1/4 那条线上（LP 4773），跟倍速/收藏/定时关闭同一个位置。
                surface.hudToastMessage = message
            }
        }
        .onChange(of: controller?.danmakuStatus) { _, status in
            switch status {
            case .unavailable, .failed:
                danmakuEnabled = false
            case .idle, .loading, .ready, .empty, nil:
                break
            }
        }
        // 退出全屏时把选集窗口收掉：它只属于横屏，留着会压在竖屏的选集区上。
        .onChange(of: isFullscreen) { _, fullscreen in
            if !fullscreen, showsEpisodesPanel {
                closeEpisodesPanel()
            }
        }
        .onChange(of: surface.isPlaying) { _, playing in
            // 暂停时不允许隐藏（简报要求）；重新起播后重新计时。
            updateIdleTimer()
            if playing {
                scheduleControlsHide()
            } else {
                showControls()
            }
            pictureInPicture?.setPlaying(playing)
            // 用户亲手按的暂停不归「回前台自动播放」管。
            if playing {
                // 切后台那一拍我们刚 pause()，内核还会有一两个快照报「还在走」，
                // 那不是用户的意思：只有在前台真的播起来，才算「用户亲手按的暂停」
                // 作废。不然这一拍会把 pausedByBackground 洗掉，回前台就不续播了。
                if surface.engine?.playerScene?.activationState == .foregroundActive { pausedByBackground = false }
                // 起播那一刻立即写一次：不然要等到下一个 2 秒节拍，
                // 万一这期间出事，控制中心一次都没写出去过。
                syncNowPlaying()
            }
        }
        .onChange(of: isScrubbing) { _, scrubbing in
            if scrubbing {
                showControls()
            } else {
                scheduleControlsHide()
            }
        }
    }

    /// 第二段修饰符：250ms 节拍、切前后台、画中画设置、快进秒数输入。
    private var playbackObservers: some View {
        contentObservers
        // 片头片尾弹窗：跟播放内核同一个 250ms 节拍（快照泵就是这条节拍），
        // 位置 / 时长喂进去、seek 和切集请求接出来。时间轴只查一次，
        // 用户把 AniSkip 关了就把手上这份清掉。
        .task {
            // 控制中心那几颗键只接一次：接在画面上，它们才真能暂停、切集、拖进度。
            configureNowPlayingCommands()
            // 一进页面就把代理读一次：开关本来就开着的那次播放不靠别的时机。
            refreshProxy()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                if let controller {
                    controller.maybeLoadSkipSegments(
                        duration: surface.duration,
                        enabled: settings.aniSkipLookup
                    )
                    skipPill.segments = settings.aniSkipLookup ? controller.skipSegments : .empty
                    skipPill.hasNextEpisode = controller.currentEpisode < controller.episodes.count
                }
                skipPill.position = surface.currentTime
                skipPill.duration = surface.duration
                skipPill.isScrubbing = isScrubbing
                skipPill.update()
                // 「正在播放」每 2 秒同步一次进度：只在状态变化时写的话，
                // 拖动进度、跨集以后控制中心那条进度会停在旧位置。
                nowPlayingTick += 1
                if nowPlayingTick % 8 == 0 {
                    syncNowPlaying()
                }
                if let target = skipPill.consumeSeekTarget() {
                    surface.seek(to: target)
                }
                if skipPill.consumeNextEpisodeRequest() {
                    nextEpisode()
                }
            }
        }
        // 后台播放关着就退到后台即暂停；开着则让音频会话保持可播，
        // 熄屏 / 切出去继续出声（LP 清单「后台播放」，默认关）。
        // 具体做什么拆到下面两个方法里：这个闭包自己已经很长，再往里塞
        // 编译器的类型检查会超时（「unable to type-check in reasonable time」）。
        // 保留现有 UIScene 通知订阅和处理顺序。
        // 回调标记仅表示收到通知，不表明其触发来源。
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didEnterBackgroundNotification)) { notification in
            guard let scene = notification.object as? UIScene,
                  let playerScene = surface.engine?.playerScene,
                  scene === playerScene else { return }
            sceneIsActive = false
            logLifecycleSnapshot("UIScene.didEnterBackgroundNotification.received", scene: notification.object as? UIScene)
            // 进后台 / 锁屏一律放弃常亮；回前台且还在播再重新判断。
            updateIdleTimer()
            // 记录通知回调时的音频会话和卡片字段，不据此推断卡片点击结果。
            PlayerAudioSession.shared.logSnapshot(String(localized: "切到后台"))
            handleBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { notification in
            guard let scene = notification.object as? UIScene,
                  let playerScene = surface.engine?.playerScene,
                  scene === playerScene else { return }
            sceneIsActive = true
            logLifecycleSnapshot("UIScene.didActivateNotification.received", scene: notification.object as? UIScene)
            updateIdleTimer()
            handleForeground()
            // 回前台重新读一次代理：用户可能刚把代理工具打开/关掉。
            refreshProxy()
        }
        // 手填的代理改了也要重读：开关或地址任何一个变了都算。
        .onChange(of: settings.proxyEnabled) { _, _ in
            refreshProxy()
        }
        .onChange(of: settings.proxyUrl) { _, _ in
            refreshProxy()
        }
        .onChange(of: settings.backgroundAutoPiP) { _, enabled in
            if enabled {
                makePictureInPictureController(settingsStore: settings)
            } else {
                pictureInPicture?.setAutomaticStartAllowed(false)
            }
        }
        .onChange(of: isEditingSkipSeconds) { _, editing in
            if editing {
                showControls()
            } else {
                scheduleControlsHide()
            }
        }
    }

    /// 第三段修饰符：控制栏自动隐藏、启动、定期落进度、离开页面。
    private var screenLifecycleObservers: some View {
        playbackObservers
        // 自动隐藏：用 `.task(id:)` 而不是自建 Task，离开页面时系统会自己取消。
        .task {
            // 看菜单还在不在：在就不收控制栏，收了就恢复自动隐藏。
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                if menuOpen {
                    if SystemMenuProbe.isPresented {
                        probeSawMenu = true
                        probeLastSeen = Date()
                    } else if probeSawMenu, Date().timeIntervalSince(probeLastSeen) > 1.2 {
                        // 菜单已经收了：控制栏恢复自动隐藏。
                        menuOpen = false
                        probeSawMenu = false
                        scheduleControlsHide()
                    } else if !probeSawMenu, Date().timeIntervalSince(menuOpenedAt) > 45 {
                        // 探测器没认出来（换过实现就不一定认得出），留个上限，别把控制栏钉死。
                        menuOpen = false
                        scheduleControlsHide()
                    }
                }
            }
        }
        .task(id: hideGeneration) {
            guard canHideControls else { return }
            let seconds = Double(settings.playerControllerLayerDisappearTime) / 1000
            var remaining = seconds
            var sawMenu = false
            while true {
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled, canHideControls else { return }
                // 系统菜单（`Menu`）开着就停在原地：它不报开合，只能看它在不在。
                if SystemMenuProbe.isPresented {
                    sawMenu = true
                    remaining = 0.4
                    continue
                }
                if sawMenu {
                    // 菜单刚关掉：重新按设置全额起算，不是接着漏下的时间收。
                    sawMenu = false
                    remaining = seconds
                    continue
                }
                withAnimation(.easeOut(duration: 0.2)) {
                    controlsVisible = false
                }
                return
            }
        }
        .task {
            await bootstrapPlaybackIfNeeded()
        }
        .task {
            // 播放期间定期落一次进度；退出与播完时还会各写一次。
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled else { return }
                guard let controller else { continue }
                persistProgress(controller)
            }
        }
        .onDisappear {
            // A view lifecycle callback is not evidence of a deliberate return action.
            logLifecycleSnapshot("onDisappear.beforeCardClear")
            // 保留现有清理顺序。
            NowPlayingCenter.shared.clear()
            restoreAudioSessionAfterPlayer()
            volumeObserver?.invalidate()
            volumeObserver = nil
            // 离开播放器：屏幕常亮无论如何都要还回去，不能带出这个页面。
            UIApplication.shared.isIdleTimerDisabled = false
            // 先摘掉结束回调，避免关闭播放器时的 finish 又被当成「播完」触发连播。
            surface.onFinish = nil
            surface.onPlaybackStarted = nil
            // 长按手势若被系统取消，松手回调不会来，退出时兜一次恢复。
            endTemporarySpeed()
            // 横屏直接离开时先明确请求竖屏；只放开方向集合不会触发旋转，
            // 开着系统竖屏锁时其它页面会继续停在横屏。
            isFullscreen = false
            sawLandscape = false
            if isWindowLandscape {
                requestOrientation(.portrait, releaseAfterSuccess: true)
            } else {
                releaseOrientation()
            }
            if let controller { persistProgress(controller) }
            // 画中画先拆：它的取帧任务绑定当前 mpv 引擎，
            // 必须赶在 `surface.stop()` 之前取消。
            pictureInPicture?.teardown()
            pictureInPicture = nil
            surface.stop()
            controller?.stop()
        }
    }

    /// Read-only view state plus actual scene activation states, separate from sceneIsActive.
    private func logLifecycleSnapshot(_ event: String, scene: UIScene? = nil, details: String = "") {
        let state = "player=\(diagnosticPlayerID) controllerPresent=\(controller != nil)"
            + " sceneIsActive=\(sceneIsActive) isPlaying=\(surface.isPlaying)"
            + " corePaused=\(surface.corePaused) coreIdle=\(surface.coreIdle)"
            + " isReady=\(surface.isReady) position=\(surface.currentTime) duration=\(surface.duration)"
            + " pausedByBackground=\(pausedByBackground) fullscreen=\(isFullscreen)"
        PlaybackLifecycleDiagnostics.log("PlayerScreen.\(event)", scene: scene,
                                         details: details.isEmpty ? state : "\(state) \(details)")
    }

    /// 各种半屏页面的内容。抽成方法是因为原来这段 switch 直接写在 `.sheet` 里，
    /// 修饰符链一长，编译器的类型检查就超时了。
    @ViewBuilder
    private func sheetContent(_ sheet: PlayerSheet) -> some View {
        switch sheet {
        case .danmakuSettings:
            NavigationStack {
                DanmakuSettingsScreen()
                    .navigationTitle("弹幕设置")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        // 右上角关闭：跟下滑关闭是同一个动作。标题居中，
                        // 左边不放东西，也不再加「取消」（Colo 2026-10-27）。
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                dismissKeyboard()
                                activeSheet = nil
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 17, weight: .regular))
                                    // 弹窗是浅底，跟系统走；白色只属于播放器的控制层
                                    // （LP 2026-10-28「关闭怎么变白色了」/ Colo 同条）。
                                    .foregroundStyle(.primary)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("关闭")
                        }
                    }
            }
            .environment(settings)
            .environment(environment.router)
        case .danmakuSource:
            NavigationStack {
                DanmakuSourceSheet(
                    initialKeyword: danmakuInitialKeyword,
                    onSelectEpisode: applyManualDanmaku
                )
            }
            .presentationDetents([.medium, .large])
        case .airPlay:
            airPlaySheet
        case .externalPlay:
            externalPlaySheet
        case .syncPlay:
            SyncPlaySheet(
                settings: settings,
                showingSyncPlay: Binding(
                    get: { activeSheet == .syncPlay },
                    set: { if !$0 { activeSheet = nil } }
                ),
                surface: surface
            )
        case .videoInfo:
            videoInfoSheet
        }
    }

    /// 进页面时把播放器建起来（原来直接写在 `.task` 闭包里）。
    ///
    /// 搬出来是因为那个闭包太大了：编译器的类型检查在那里超时（413 行）。
    /// 逻辑一行没改。
    private func bootstrapPlaybackIfNeeded() async {
        guard controller == nil else { return }
        // 先把两个 store 取成局部常量：闭包会长期挂在 surface 上，
        // 这样试不会把整个 View（含 @Environment 包装器）一起捕获。
        let settingsStore = settings
        let library = environment.library
        danmakuEnabled = settingsStore.danmakuEnabled
        applyAudioSessionPolicy()
        observeSystemVolume()
        playbackRate = Float(settingsStore.playSpeed)
        // 默认视频比例：设置页选的那一档作为这次播放的起点，
        // 播放器里再改只影响这一次（与原版一样不写回设置）。
        aspectRatioMode = settingsStore.defaultAspectRatio
        let created = PlayerController(
            bangumiID: bangumiID,
            episode: episode,
            source: source,
            plugins: environment.plugins,
            library: library,
            resumeRoad: resumeRoad,
            resumeFromHistory: resumeFromHistory,
            resumeRule: resumeRule,
            // 离线播放（Colo 5174）：这集在本地有文件就直接放它。
            // 按番剧 + 规则名查，不管线路：下的时候是哪条线路、现在进的是哪条，
            // 对用户来说都是「这集我下过」。
            localFile: { number in
                return environment.downloads.localURL(
                    bangumiID: bangumiID,
                    pluginName: source?.pluginName ?? resumeRule ?? "",
                    number: number
                )
            },
            // 在线列表抓不到时退回这份下载记录：只列已下载的集。
            downloadedNumbers: {
                environment.downloads.downloadedNumbers(
                    bangumiID: bangumiID,
                    pluginName: source?.pluginName ?? resumeRule ?? ""
                )
            },
            // 本集加进了下载但还没下完：走在线解析时画面要说一句（Camo 5208）。
            episodeIncomplete: { number in
                environment.downloads.isEpisodeIncomplete(
                    bangumiID: bangumiID,
                    pluginName: source?.pluginName ?? resumeRule ?? "",
                    number: number
                )
            }
        )
        controller = created
        // 上一集 / 下一集必须在拿到 controller **之后**接：早接一步抓到的是 nil（LP 5042）。
        bindEpisodeRemoteCommands(created)
        // 默认倍速：就绪 / 重新起播时由画面模型再补一次（AVPlayer 会回到 1.0）。
        let startSpeed = Float(settingsStore.playSpeed)
        surface.setPlaybackRate(startSpeed)
        // 自动连播：正常播完后根据设置决定是否切到下一集。
        // 起播稳定后把嗅探用的 WebView 放掉（LP 4938 Step 2）：媒体地址已经解析到、
        // mpv 已经在放，那个隐藏页面就没有存在的必要了。WKWebView 只要还活着，它的
        // WebContent 子进程就还在，跟 mpv、画中画控制器一起向系统认领媒体路由——
        // 切后台那一秒三方抢路由，灵动岛 / 锁屏点击就失效。
        // 回调由 `PlayerSurfaceModel` 在「首帧之后又过了 0.15 秒」那一刻发一次
        // （见 `onPlaybackStarted`）；不写在 SwiftUI 的 `.onChange` 里，那串 modifier
        // 已经长到编译器的类型检查会超时。
        //
        // 必须挂在这里、不能挂在上面 `applyAudioSessionPolicy()` 里：那一步跑在
        // `controller = created` **之前**，闭包弱引用抓到的是当时还是 nil 的那个值，
        // 回调等于永远是空的（2026-10-30 模拟器上就是这么一次都没释放）。
        surface.onPlaybackStarted = { [weak created] in
            created?.releaseSourceWebView()
            // mpv 的 `ao_audiounit` 在音频流初始化那一刻会把会话重设一遍
            // （真机日志里 `模式=AVAudioSessionModeMoviePlayback` 就是它盖的，LP 4993）。
            // 所以起播一稳定就立刻掰回 `.default`，不等 2 秒那一次轮询。
            PlayerAudioSession.shared.reapplyIfNeeded()
            if settingsStore.backgroundAutoPiP,
               pictureInPicture?.hasOngoingPictureInPicture != true,
               surface.engine?.playerScene?.activationState == .foregroundActive {
                makePictureInPictureController(settingsStore: settingsStore)
            }
        }
        surface.onFinish = { [weak created] surface in
            guard let created else { return }
            // 播完先落一次进度：结尾 5 秒内会归零，当作「已看完」的边界。
            persistWatchProgress(
                library: library,
                privateMode: settingsStore.privateMode,
                controller: created,
                position: surface.currentTime,
                duration: surface.duration
            )
            guard settingsStore.autoPlayNext else { return }
            guard created.currentEpisode < created.episodes.count else {
                // 已是末集：停下来并给一句提示，不静默什么都不做。
                surface.toastMessage = String(localized: "已经是最新一集")
                return
            }
            let next = created.currentEpisode + 1
            surface.prepareForNewEpisode()
            Task { await created.selectEpisode(next) }
        }
        resumeIfNeeded(library: library, controller: created)
        // 后台自动画中画：设置开着才把控制器建出来，并提前把图层挂进窗口。
        // 系统的「自动画中画」要求内联图层在切后台**之前**就存在；等退后台
        // 那一刻再建，`isPictureInPicturePossible` 往往一直是 false。
        if settingsStore.backgroundAutoPiP {
            makePictureInPictureController(settingsStore: settingsStore)
        }
        await created.start()
    }

    /// 建（或复用）画中画控制器。
    private func makePictureInPictureController(settingsStore: SettingsStore) {
        if let pictureInPicture {
            pictureInPicture.setAutomaticStartAllowed(settingsStore.backgroundAutoPiP)
            pictureInPicture.setPlaying(surface.isPlaying)
            pictureInPicture.prepare(engine: surface.engine, surface: surface)
            return
        }
        let pip = PictureInPictureController()
        let backgroundPaused = $pausedByBackground
        let playerSceneActive = $sceneIsActive
        pip.onSettlement = { [weak surface] settlement in
            guard let surface else { return }
            switch settlement {
            case .active:
                // PiP feed reads decoded frames directly; stop only the inline
                // gpu-next/CAMetalLayer output while the system window is active.
                surface.setRenderingLocked(true)
                if backgroundPaused.wrappedValue {
                    backgroundPaused.wrappedValue = false
                    if !surface.isPlaying { surface.play() }
                }
            case .backgroundFallback(let reason):
                KazumiLogBuffer.player("画中画: 后台策略收口（\(reason)）")
                applyBackgroundPlaybackPolicy(
                    surface: surface,
                    settingsStore: settingsStore,
                    backgroundPaused: backgroundPaused
                )
            case .stoppedInBackground:
                KazumiLogBuffer.player("画中画: 后台关闭小窗，按后台播放设置收口")
                applyBackgroundPlaybackPolicy(
                    surface: surface,
                    settingsStore: settingsStore,
                    backgroundPaused: backgroundPaused
                )
            case .foreground:
                surface.setRenderingLocked(false)
                let shouldResume = settingsStore.resumeOnForeground && backgroundPaused.wrappedValue
                if shouldResume {
                    backgroundPaused.wrappedValue = false
                    if !surface.isPlaying { surface.play() }
                }
                let active = surface.engine?.playerScene?.activationState == .foregroundActive
                playerSceneActive.wrappedValue = active
                let keepAwake = surface.isPlaying && active
                if UIApplication.shared.isIdleTimerDisabled != keepAwake {
                    UIApplication.shared.isIdleTimerDisabled = keepAwake
                }
            }
        }
        pip.onActiveChanged = { [weak surface] active in
            surface?.setRenderingLocked(active)
        }
        pictureInPicture = pip
        pip.setAutomaticStartAllowed(settingsStore.backgroundAutoPiP)
        pip.setPlaying(surface.isPlaying)
        pip.prepare(engine: surface.engine, surface: surface)
    }

    private func applyBackgroundPlaybackPolicy(
        surface: PlayerSurfaceModel,
        settingsStore: SettingsStore,
        backgroundPaused: Binding<Bool>
    ) {
        // No decoder switch: the fallback only locks the window renderer and,
        // when background audio is disabled, pauses with the existing resume marker.
        surface.setRenderingLocked(true)
        if !settingsStore.backgroundPlayback, surface.isPlaying {
            backgroundPaused.wrappedValue = true
            KazumiLogBuffer.player("画中画: 静默暂停来源：后台兜底")
            surface.pause()
        }
    }

    /// 切到后台只转发 transition；PiP 有资格启动时绝不在这里同步锁渲染或暂停。
    /// 控制器会在 bounded start window 最终失败、且仍在后台时发唯一政策事件。
    private func handleBackground() {
        if pictureInPicture?.hasOngoingPictureInPicture == true {
            KazumiLogBuffer.player("画中画: 后台沿用当前小窗周期，不重新准备")
            pictureInPicture?.handleBackground(engine: surface.engine, surface: surface)
        } else if settings.backgroundAutoPiP {
            makePictureInPictureController(settingsStore: settings)
            pictureInPicture?.handleBackground(engine: surface.engine, surface: surface)
        } else if let pictureInPicture {
            pictureInPicture.handleBackground(engine: surface.engine, surface: surface)
        } else {
            // PiP 设置关闭，本来就没有启动窗口；直接沿用后台播放策略。
            applyBackgroundPlaybackPolicy(
                surface: surface,
                settingsStore: settings,
                backgroundPaused: $pausedByBackground
            )
        }
        if let controller { persistProgress(controller) }
    }

    /// 读一次代理交给播放内核（LP 5331）。
    ///
    /// libmpv 不认 iOS 的系统代理，所以只能由我们交给它。iOS 上 App 拿不到
    /// 代理软件（Surge 之类）在 HTTP 模式下监听的那个端口，所以这里只认
    /// 用户在设置里手填的地址和端口。
    private func refreshProxy() {
        let next = settings.playerProxyURL
        guard next != proxyURL else { return }
        proxyURL = next
        KazumiLogBuffer.player(MPVDiagnostics.sanitize(
            next == nil ? String(localized: "代理：不走代理，直连") : String(localized: "代理：走 \(String(describing: next!))")
        ))
    }

    /// 回前台只转发一次；后续 didStop 在控制器里走同一收口且不再回调。
    private func handleForeground() {
        if let pictureInPicture {
            pictureInPicture.handleForeground()
        } else {
            // 设置关闭时没有 PiP owner，保留原有回前台策略。
            surface.setRenderingLocked(false)
            let shouldResume = settings.resumeOnForeground && pausedByBackground
            if shouldResume {
                pausedByBackground = false
                if !surface.isPlaying { surface.play() }
            }
            logLifecycleSnapshot("handleForeground.completed")
        }
    }

    // MARK: - 播放区

    /// 全屏时把「画面比例」换成**容器比例**：`.aspectRatio(_, contentMode: .fit)`
    /// 传 nil 会退回内容的固有比例（mpv 视图是方的，上一版就成了 382×382）。
    /// 换成容器自己的比例后 fit 的结果正好等于容器，全屏铺满——只改一个参数、
    /// 不改视图类型；改类型会把 mpv 拆掉重建、进度归零（3678）。
    private var boxAspectRatio: CGFloat {
        if isFullscreen, containerSize.width > 0, containerSize.height > 0 {
            return containerSize.width / containerSize.height
        }
        return aspectRatioMode.frameAspectRatio
    }

    /// 画面：16:9（或 4:3）画面本身，控制层压在它上面。
    /// 竖屏里这条就是页面最上面那一块；横屏全屏时铺满。
    @ViewBuilder
    private func playerArea(_ controller: PlayerController) -> some View {
        // 在这里读一次：视频尺寸变化要让整个播放区重算（控制层矩形也跟着变）。
        let videoSize = surface.videoSize
        ZStack {
            // 上下两条压暗：压在**画面之上、控制层之下**（LP 2026-10-28 第 3 条）。
            // 挂成画面的 overlay 而不是 ZStack 里的一层：overlay 不参与布局，
            // 遮罩里那条 maxHeight: .infinity + ignoresSafeArea 会把整块播放区
            // 撑高，竖屏就变成「上下多出一条黑边、比画面本身高」
            // （LP 2026-10-28 第 4 条）。层级不变：画面 → 遮罩 → 控制层。
            interactiveSurface(controller)

            // 截图那一下的取景框（Colo 3667 的规格）：压在画面上、控制层之下。
            if screenshotFlash > 0 {
                ScreenshotFlashView(progress: screenshotFlash)
            }

            // 加载符号：一颗系统圈 + 下面一行网速（LP 4810）。
            //
            // 什么时候收：引擎推到「在播」这个相位（第一帧画过、或者时间轴已经走起来），
            // 不是「第一帧画上屏」那一刻——后者之后还有一小段等音画对齐的黑屏，
            // 圈先收了人就在那儿干等，就是「不转圈了还要等一会才能看」。
            // 判据不看一次性回调（Ato 4867），理由见 `MPVPlayerContainer.isLoadingFirstFrame`。
            // 中途卡住（网卡缓冲）、拖完进度在 seek，都走同一颗（LP 4810 第三句）。
            if showsLoadingHUD,
               surface.errorMessage == nil,
               controller.playbackURL != nil {
                loadingAtCenterLine {
                    PlayerLoadingHUD(bytesPerSecond: surface.downloadSpeed)
                }
                .transition(.opacity)
            }

            if let error = surface.errorMessage {
                errorOverlay(error, controller: controller)
            }

            // 控制层只铺在画面矩形里：横屏两侧的黑边留空，顶栏 / 进度条 /
            // 两侧 15 秒钮都跟画面左右边缘对齐（DEFECT 4）。
            // 视频尺寸还没拿到时 videoRect 回落到整块画面，不会先缩一下再跳。
            GeometryReader { proxy in
                let videoRect = aspectRatioMode.fillMode.videoRect(
                    in: CGRect(origin: .zero, size: proxy.size),
                    videoSize: videoSize
                )
                // 两条压暗的长度按画面高算（Colo 2026-10-28 4295 的公式）。
                let maskFades = Self.maskFadeLengths(
                    videoHeight: proxy.size.height,
                    isFullscreen: isFullscreen
                )
                // 控制层只有安全区那么大（横屏 750×382，窗口 874×402）：纵向靠
                // 过冲吃掉了，横向得自己铺到窗口宽，不然左右两条窄边没压到
                // （LP 2026-10-28「上下都到顶了，但是左右两侧没有」）。
                let maskWidth: CGFloat? = isFullscreen
                    ? fullscreenVideoSize.width + Self.maskTopOvershoot * 2
                    : nil
                // 控制层铺满整块播放区，不再框进 videoRect：横屏全屏时这块就是
                // 874x402 的窗口，顶栏底栏进度条才贴得到窗口边（Colo 2026-10-27，
                // LP「横屏播放器一圈都不沾边」）。竖屏内联时播放区本身就是那块
                // 16:9 画面，所以一条规则两边都对。videoRect 只留给弹幕层。
                controlLayer(controller, width: proxy.size.width)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    // 两条压暗挂在**控制层**身上：它跟画面同尺寸同位置，而且
                    // 按钮本来就压在画面上（控制层在上），所以挂这里一定看得见、
                    // 也一定从这块几何的上/下沿起画（@developer3 2026-10-28）。
                    // 顶条只往上多画 `maskTopOvershoot`：画在屏幕外，专门吃
                    // 「跟窗口顶差几个点」那种缝（LP 2026-10-28 反复报的）。
                    .background(alignment: .top) {
                        topMask(fadeHeight: maskFades.top)
                            .frame(width: maskWidth)
                            .offset(y: -Self.maskTopOvershoot)
                            .opacity(controlsShown ? 1 : 0)
                            .animation(.easeOut(duration: 0.2), value: controlsVisible)
                    }
                    .background(alignment: .bottom) {
                        bottomMask(fadeHeight: maskFades.bottom)
                            .frame(width: maskWidth)
                            .opacity(controlsShown ? 1 : 0)
                            .animation(.easeOut(duration: 0.2), value: controlsVisible)
                    }
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            // 这一层几何本身要铺到窗口边：控制层（和它的遮罩）原来排在安全区里，
            // 遮罩就从安全区下沿起画、离窗口顶差那一点（LP 2026-10-28 反复报的）。
            // 顶栏自己有 padding(.top, containerInsets.top)，按钮不会顶到刘海下面。
            .ignoresSafeArea(.container, edges: isFullscreen ? [.top, .bottom] : [])

            // HUD 一律放在画面从上往下 1/4 处、水平居中（LP 2026-10-28 第 11 条 / Colo）：
            // 亮度 / 音量横条、横滑的秒数、长按倍速的胶囊、双击的播放 / 暂停都在这一条线上。
            // 按播放器可视高度算，不按窗口高。
            if let gestureHUD {
                hudAtQuarter { gestureOverlay(gestureHUD) }
            } else if let seekHUD {
                hudAtQuarter { seekOverlay(seekHUD, target: seekDragTarget) }
            }
            if let superResolutionHUD {
                hudAtQuarter {
                    Text(superResolutionHUD)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .playerGlass(in: Capsule(style: .continuous))
                        .shadow(color: .black.opacity(0.28), radius: 8, y: 2)
                }
                .transition(.opacity)
            }
            // 双击的播放 / 暂停也摆在这一条线上（LP 4687），小符号 + 文字，跟动作结果同一款气泡。
            if let playPauseHUD, gestureHUD == nil, seekHUD == nil {
                hudAtQuarter { playPauseBubble(playPauseHUD) }
                    .transition(.opacity)
            }

            // 片头片尾弹窗：横屏固定位置（跟控制栏显隐无关），竖屏贴控制栏上沿。
            // 状态机自己跑，这里只负责把它摆到画面右下角。
            if skipPill.isVisible {
                SkipSegmentPillView(model: skipPill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, skipPillTrailingInset)
                    .padding(.bottom, skipPillBottomInset)
            }

            // 长按加速的倍速值：跟其它 HUD 同一条线（1/4 处），松手就消失。
            if isTemporarySpeed {
                hudAtQuarter { temporarySpeedCapsule }
                    .transition(.opacity)
            }
            // 动作结果那句（倍速 / 收藏 / 定时关闭，LP 4668）也摆在这一条线上，
            // 跟长按倍速胶囊同一个高度；顶部那条留给说明性的话。
            if let message = surface.hudToastMessage {
                hudAtQuarter {
                    toastBubble(message)
                        .task(id: message) { await hideToast(message, slot: .hud) }
                }
                .transition(.opacity)
            }
        }
        // 画面、控制栏、HUD 这一层强制深色（LP 2026-11-06）：玻璃按深色渲染，
        // 不跟系统浅色走。竖屏的选集 / 评论面板不在这棵树里，保持原样。
        .environment(\.colorScheme, .dark)
        .modifier(PlayerBoxModifier(fillsWindow: isFullscreen,
                                    aspectRatio: boxAspectRatio))
        // 横屏画面铺满整个窗口（874×402）：上下安全区都忽略掉。
        // 底部那 21 的 home 区不忽略画面就矮一截、底下露一条黑缝（LP 2026-10-27）；
        // 顶部不忽略，顶部遮罩就从安全区下沿起画、离窗口顶差一点（LP 2026-10-28）。
        // 控制层自己另外忽略底边，留在安全区里排，不受这里影响。
        .ignoresSafeArea(.container, edges: isFullscreen ? [.top, .bottom] : [])
        .background(Color.black)
        // MPVolumeView 得在视图树里，才拿得到它内部的音量滑杆。
        .background(
            SystemVolumeHost()
                .frame(width: 1, height: 1)
                .opacity(0.01)
        )
        // 控制层要知道画面有多宽：横屏才排两行底栏（宽 ≥ 600）。
        // 用 onGeometryChange 量，不套 GeometryReader —— 那玩意会把可用空间全吃掉，
        // 画面就不再是 16:9（LP 3623「竖屏播放器窗口变太大」就是这么来的）。
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            surfaceWidth = width
        }
    }

    /// 画面 + 手势（只挂在画面上，下面的选集与评论不接）：
    /// 单击显隐控制层，双击播放暂停，长按临时倍速，左右两侧竖滑分别调亮度与音量。
    /// 全屏时画面要铺满**整个窗口**（874×402），不是安全区里的 750×382——
    /// 左右那 62 的刘海区画面也要占住（Colo 2026-10-27 定的 (b)）。
    /// 控制层仍然按安全区的 750 排，所以 15 秒两颗落在 750 的 1/4 与 3/4。
    private var fullscreenVideoSize: CGSize {
        guard isFullscreen else { return .zero }
        return CGSize(
            width: containerSize.width + containerInsets.leading + containerInsets.trailing,
            height: containerSize.height + containerInsets.top + containerInsets.bottom
        )
    }

    private func interactiveSurface(_ controller: PlayerController) -> some View {
        GeometryReader { proxy in
            // 全屏用窗口尺寸，竖屏用播放区自己的尺寸（两者在竖屏下相同）。
            let surfaceSize = isFullscreen ? fullscreenVideoSize : proxy.size
            // 全屏时画面（874×402）比播放区（750×382）大，而 GeometryReader 的内容
            // 默认贴**左上角**——不居中就会整体偏右 62（LP 2026-10-27「视频偏右」）。
            // 外面再套一层居中的 frame，竖屏下两者同尺寸、没有影响。
            Group {
            // 没有画面（解析中、加载失败）时一个面手势都不挂：父层的手势会抢走
            // 失败页上「重试」「返回选源」的点击，连点都落不下去（LP 2026-10-25）。
            if controller.playbackURL == nil {
                videoSurface(controller)
                    .frame(width: surfaceSize.width, height: surfaceSize.height)
            } else {
                videoSurface(controller)
                    .frame(width: surfaceSize.width, height: surfaceSize.height)
                    .contentShape(Rectangle())
                    .gesture(
                        ExclusiveGesture(SpatialTapGesture(count: 2), SpatialTapGesture(count: 1))
                            .onEnded { value in
                                switch value {
                                case .first(let tap):
                                    handleSurfaceDoubleTap(at: tap.location.x, width: surfaceSize.width)
                                case .second:
                                    handleSurfaceTap()
                                }
                            }
                    )
                    // 滑动手势关了就不收竖向拖拽（LP 清单「滑动手势」，默认开）。
                    .simultaneousGesture(
                        surfaceDragGesture(width: surfaceSize.width, height: surfaceSize.height),
                        including: settings.brightnessVolumeGesture && !isSurfaceLocked ? .all : .none
                    )
                    // 长按倍速：**按住的那段就是倍速**（LP 2026-10-28 第 10 条 / Colo）。
                    // 不再靠系统的长按回调——它要等按满 0.5 秒才通知，手指一动还会取消，
                    // 表现出来就像「松手之后才倍速」。改成自己数：手指落下就起计时，
                    // 0.4 秒到点还在按就倍速，松手那一拍立刻还原。
                    .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 24) {
                        lastLongPressAt = Date()
                    } onPressingChanged: { pressing in
                        surfacePressTask?.cancel()
                        surfacePressTask = nil
                        // 锁着时长按也不倍速（LP 2026-10-28 第 4 条）。
                        if pressing, !isSurfaceLocked {
                            surfacePressTask = Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(400))
                                guard !Task.isCancelled else { return }
                                lastLongPressAt = Date()
                                beginTemporarySpeed()
                            }
                        } else {
                            endTemporarySpeed()
                        }
                    }
            }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
        }
    }

    /// 画面拖动，一次只走一路：
    /// * 横着拖是调进度，换算照 main（`180000 / width` 毫秒每点，整块画面宽 ≈ 180 秒），
    ///   比拖进度条细得多，中途只显示「+15s」，松手才真跳到那儿；
    /// * 竖着拖左半边调亮度、右半边调音量，同样自己画横条，不弹系统那条。
    ///
    /// 起手有三道门（LP 2026-10-29 4790 那份参考实现）：
    /// 1. **上下安全区屏蔽**：起手点落在窗口最上 / 最下 40 点里就不认——那是控制中心
    ///    和 home 指示条的地盘，抢过来就变成「拉亮度和划控制中心一起发生」；
    /// 2. **方向锁定死区**：`minimumDistance` 就是那 10 点，跨过去才决定这一路是调进度
    ///    还是调亮度/音量，定下来就不再改（`dragAxis` 只在 nil 时赋值）；
    /// 3. 左半屏亮度、右半屏音量。
    ///
    /// 坐标用 `.global`（窗口坐标）而不是画面局部坐标：安全区是按**屏幕**算的，
    /// 竖屏内联时画面只有 226 点高、上下都离屏幕边很远，拿局部坐标量安全区没意义。
    private func surfaceDragGesture(width: CGFloat, height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: Self.directionLockThreshold, coordinateSpace: .global)
            .onChanged { value in
                let window = UIScreen.main.bounds
                // 按住倍速已经起来了：这一路拖动什么都不做——不调进度、不碰亮度音量，
                // 倍速继续到松手（LP 2026-10-29「按住倍速时不应该还能触发音量亮度
                // 进度调节等手势」）。所以这里不能走下面那段「拖出容差就结束倍速」。
                if isTemporarySpeed {
                    dragAxis = .ignored
                    return
                }
                if dragAxis == nil {
                    // 安全区这道门先过：上下 40 点里起手，这一路什么都不做。
                    guard value.startLocation.y > Self.gestureEdgeGuard,
                          value.startLocation.y < window.height - Self.gestureEdgeGuard else {
                        dragAxis = .ignored
                        return
                    }
                    if abs(value.translation.width) > abs(value.translation.height) {
                        // 贴左边缘往右起手是返回，交给外层的侧滑手势，不调进度。
                        if value.startLocation.x < 28, value.translation.width > 0 {
                            dragAxis = .ignored
                            return
                        }
                        dragAxis = .seek
                        seekDragStart = surface.currentTime
                        seekDragTarget = surface.currentTime
                    } else if isFullscreen, value.startLocation.y > window.height - Self.bottomSystemStrip {
                        // 竖向从最底下那条起手：那是 home 指示条的地盘，让给系统退 app，
                        // 不在这里再调一次亮度/音量（LP 2026-10-29「上滑控制音量和退出 app 同步执行」）。
                        // 只限竖向：横向拖进度不碰系统手势，照旧可用。
                        // 横屏全屏时这块一直铺到窗口底沿（那层 ignoresSafeArea 是 10-27 要的）。
                        dragAxis = .ignored
                        return
                    } else if value.startLocation.x < window.width / 2 {
                        dragAxis = .brightness
                        dragValueStart = Double(UIScreen.main.brightness)
                    } else {
                        dragAxis = .volume
                        dragValueStart = PlayerVolumeControl.shared.current
                    }
                }
                // 手指已经在拖了：按住的倍速计时作废，拖动不该被当成「长按倍速」
                // （LP 2026-10-28「上下滑动手势不要触发长按倍速」；
                //  @developer3 定位：长按那套是自己数的 400 毫秒计时，压根不看手指
                //  有没有动，而竖向拖动是 simultaneousGesture，不会取消长按的 pressing）。
                if dragAxis != nil, dragAxis != .ignored {
                    surfacePressTask?.cancel()
                    surfacePressTask = nil
                    // 倍速已经起来了、手指又拖出长按自己的容差（24pt，跟 longPress 的
                    // maximumDistance 一致）：这一次是拖动，不是按住。
                    if abs(value.translation.height) > 24 || abs(value.translation.width) > 24 {
                        endTemporarySpeed()
                    }
                }
                switch dragAxis {
                case .seek:
                    guard let start = seekDragStart else { return }
                    let seconds = Double(value.translation.width) / Double(max(1, width)) * 180
                    let limit = max(0, surface.duration - 0.5)
                    let target = min(max(0, start + seconds), limit)
                    seekDragTarget = target
                    seekHUD = Int((target - start).rounded())
                case .brightness, .volume:
                    guard let start = dragValueStart else { return }
                    // 倍率照 main（player_item.dart 1214 / 1233）：亮度 level = 高度×2
                    // （滑两屏到底），音量 level = 高度×0.03 而 main 的音量是 0–100，
                    // 折成 0–1 就是三屏到底。原来两样都写死 220pt，比原版快十倍，
                    // 手指一抖就拉到底（LP 2026-10-29「降低音量亮度手势调节的倍率」）。
                    // 分母用**窗口**高度（main 的 MediaQuery.sizeOf(context).height），
                    // 不是画面那块的高度：竖屏内联时画面只有 226 点高，拿它算会比原版灵敏三倍。
                    let windowHeight = Double(max(1, window.height))
                    let level = dragAxis == .brightness ? windowHeight * 2 : windowHeight * 3
                    let delta = Double(-value.translation.height) / level
                    let target = min(1, max(0, start + delta))
                    if dragAxis == .brightness {
                        UIScreen.main.brightness = CGFloat(target)
                        gestureHUD = GestureHUDValue(kind: .brightness, value: target)
                    } else {
                        PlayerVolumeControl.shared.set(target)
                        showVolumeHUD(target)
                    }
                case .ignored, .none:
                    break
                }
            }
            .onEnded { _ in
                let wasSeeking = dragAxis == .seek
                if wasSeeking, let target = seekDragTarget {
                    surface.seek(to: target)
                }
                dragAxis = nil
                dragValueStart = nil
                seekDragStart = nil
                seekDragTarget = nil
                // 秒数胶囊停 1.2 秒；亮度 / 音量还是 0.6 秒。
                scheduleHUDHide(after: wasSeeking ? 1.2 : 0.6)
            }
    }

    private var controllerPhase: PlayerController.Phase {
        controller?.phase ?? .idle
    }

    /// 控制层是不是该露面。
    ///
    /// 暂停、播放失败：控制层和左上返回一直在，这时候用户最可能想退出去（Colo 3307）。
    /// 加载中按正常状态处理，跟正在播放一样随控制条自动隐藏、点一下唤回来。
    private var controlsShown: Bool {
        // 锁着时控制层一律不露面：暂停也不再钉住（LP 2026-10-28 第 4 条）。
        guard !isSurfaceLocked else { return false }
        return controlsVisible || pinsControls
    }

    private var pinsControls: Bool {
        if case .failed = controllerPhase { return true }
        return controllerPhase == .ready && !surface.isPlaying
    }

    /// 控制层：顶一行、底一行，都浮在画面上；几秒不碰淡出，点一下回来。
    /// 隐藏只降透明度、不动布局，画面不会跳。
    private func controlLayer(_ controller: PlayerController, width: CGFloat) -> some View {
        ZStack {
            // 锁着时整条控制层都不画：那一档只剩解锁那一颗（见下）。
            if !isSurfaceLocked {
                VStack(spacing: 0) {
                    topBar(controller)
                    Spacer(minLength: 0)
                    transportBar(controller, width: width)
                }
                // 命中只给控制栏本身：收起时它不该挡着「点画面把控制层叫回来」。
                .allowsHitTesting(controlsShown)
            }

            // 画面左右两侧的快退 / 快进：秒数取设置里「快进快退时长」（doubleTapSkipTime，默认 15）。
            // 双击两侧的快进已经删掉（LP 3593），快进快退只从这两颗走。
            if controlsShown {
                // 最边缘那两颗（LP 2026-10-28 第 4 条）：锁定在左、截图在右，
                // 距边 16、40×40 热区。画面两侧的快退 / 快进两颗已删（LP 2026-11-06），
                // 改由双击左 30 / 右 30 承担。
                lockButton
                    .padding(.leading, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .transition(.opacity)
                screenshotButton
                    .padding(.trailing, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .transition(.opacity)
            }

            if !controlsShown {
                // 控制层收起时，整块画面都是「把控制层叫回来」的命中区；
                // 锁着的时候这一下只唤出解锁钮，不显示控制层（LP 2026-10-28 第 4 条）。
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isSurfaceLocked { showUnlockAffordance() } else { showControls() }
                    }
            }

            // 锁住时只剩这一颗：点一下浮出来，几秒没人碰就收回去。
            //
            // 必须排在上面那块满屏命中区**之后**。锁着时 `controlsShown` 恒为 false，
            // 那块 `Color.clear` 一直都在；放在它前面就会被它整个盖住，
            // 于是「锁上以后再点就是解不开」——点多少下都只走「唤出解锁钮」。
            if isSurfaceLocked, unlockAffordanceShown {
                lockButton
                    .padding(.leading, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .transition(.opacity)
            }

        }
        .opacity(controlsShown || (isSurfaceLocked && unlockAffordanceShown) ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: controlsVisible)
        // 全屏时底栏离**窗口**下沿 12，不是离 home 那条安全区 12
        // （横屏底部还有 21 的内缩，不忽略的话底栏会悬在半空，LP 2026-10-27）。
        .ignoresSafeArea(.container, edges: isFullscreen ? .bottom : [])
    }


    /// 顶条只往上多画这么多点：画在屏幕外，专门吃「跟窗口顶之间那几个点」的缝。
    private static let maskTopOvershoot: CGFloat = 16

    /// 屏幕最底下留给系统手势的那一条（home 指示条）。竖向拖动的起手落在这条里就不接，
    /// 交给系统去退 app。横屏时底部安全区是 21，再加两点余量。
    private static let bottomSystemStrip: CGFloat = 24

    /// 竖向拖动起手的安全区：窗口最上 / 最下这么宽的一段不认，免得跟控制中心、
    /// home 指示条抢（LP 2026-10-29 4790 的参考实现里是 40 点）。
    private static let gestureEdgeGuard: CGFloat = 40

    /// 方向锁定的死区：手指先走这么多点，才决定这一路是调进度还是调亮度/音量。
    private static let directionLockThreshold: CGFloat = 10

    /// 两条压暗的长度（Colo 2026-10-28 4295）：顶 min(96, 画面高×0.25)、
    /// 底 min(200, 画面高×0.45)，再夹一句——顶栏＋顶渐隐＋底渐隐＋底栏 ≤ 画面高，
    /// 超了就等比缩。中间一定要留出一段全透明的画面：竖屏那组写死的数
    /// （64＋160＝224）比画面本身（215）还高，两条就这么糊满了（@developer3 量到的）。
    private static func maskFadeLengths(
        videoHeight: CGFloat,
        isFullscreen: Bool
    ) -> (top: CGFloat, bottom: CGFloat) {
        guard videoHeight > 0 else { return (0, 0) }
        // 栏高按代码里的实际值（@developer3 2026-10-28 4300）：顶栏 56（44 的钮
        // ＋12）；底栏横屏约 115（时间行＋进度条＋48 的钮行＋12），竖屏 64（52＋12）。
        let topBar: CGFloat = 56
        let bottomBar: CGFloat = isFullscreen ? 115 : 64
        var top = min(96, videoHeight * 0.25)
        var bottom = min(200, videoHeight * 0.45)
        let available = videoHeight - topBar - bottomBar
        if available > 0, top + bottom > available {
            let scale = available / (top + bottom)
            top *= scale
            bottom *= scale
        }
        return (top, bottom)
    }

    /// 顶部压暗：最黑那一档贴在这块几何的顶边（横屏就是窗口顶），往下渐隐到全透明。
    /// 顶栏自己那条底不加：0.8 起头已经压得住栏里的字（@developer3 2026-10-28 4297）；
    /// 真要改成 y=0 就透明，才需要给顶栏补一条底（Colo 4295）。
    private func topMask(fadeHeight: CGFloat) -> some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.8), location: 0),
                .init(color: .black.opacity(0.4), location: 0.5),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: fadeHeight)
        .allowsHitTesting(false)
    }

    /// 底部压暗：最黑那一档压在底边（底栏本来就有底），往上渐隐到全透明。
    private func bottomMask(fadeHeight: CGFloat) -> some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.4), location: 0.5),
                .init(color: .black.opacity(0.8), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: fadeHeight)
        .allowsHitTesting(false)
    }

    /// 左边缘那颗：锁画面（LP 2026-10-28 第 4 条）。
    /// 规格跟其余 HUD 按钮一样：40×40 热区、18pt Medium 白色符号，收起时一起隐。
    private var lockButton: some View {
        PlayerIconButton {
            toggleSurfaceLock()
        } content: {
            Image(systemName: isSurfaceLocked ? "lock" : "lock.open")
                .playerIcon()
                .foregroundStyle(.white)
        }
        .accessibilityLabel(isSurfaceLocked ? "解锁画面" : "锁定画面")
        .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
    }

    /// 右边缘那颗：抓当前这一帧存进相册（LP 2026-10-28 第 4 条）。
    /// 抓的是 mpv 自己出的那一帧，超分滤镜在，弹幕和控件不在（Colo 3667）。
    private var screenshotButton: some View {
        PlayerIconButton {
            takeScreenshot()
        } content: {
            Image(systemName: "camera")
                .playerIcon()
                .foregroundStyle(.white)
        }
        .accessibilityLabel("截图")
        .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
    }

    /// 锁上 / 解开。锁上顺手把控制层收掉：那一档屏幕上不该再有任何可点的东西。
    private func toggleSurfaceLock() {
        if isSurfaceLocked {
            isSurfaceLocked = false
            unlockAffordanceTask?.cancel()
            unlockAffordanceTask = nil
            unlockAffordanceShown = false
            // 解开就露一下控制层，让人看清刚才锁的是哪里。
            showControlsBriefly()
        } else {
            isSurfaceLocked = true
            unlockAffordanceTask?.cancel()
            unlockAffordanceTask = nil
            unlockAffordanceShown = false
            hideGeneration &+= 1
            withAnimation(.easeOut(duration: 0.2)) { controlsVisible = false }
        }
    }

    /// 锁着时点一下：只把解锁那一颗浮出来，3 秒后自己收回。
    private func showUnlockAffordance() {
        if unlockAffordanceShown { return }
        withAnimation(.easeOut(duration: 0.2)) { unlockAffordanceShown = true }
        unlockAffordanceTask?.cancel()
        unlockAffordanceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { unlockAffordanceShown = false }
        }
    }

    /// 截图：抓帧 → 存相册 → 闪一下取景框，存好/没存好都要说一句（LP 4709）。
    ///
    /// 抓帧走 mpv 的 `screenshot-to-file`（原始分辨率、不含字幕和 OSD，LP 4695），
    /// 出的是临时文件；这里再把文件交给相册那条路，存完删掉。
    ///
    /// 取景框**按下去就播**，不等抓帧：mpv 要回最近的关键帧重新解码，网络流上
    /// 这一下是秒级的（回执到了才算成），不先给个反应的话，从按下到有结果之间
    /// 屏幕几十秒没动静，就是 LP 说的「没任何提示」。失败了照样出错误提示。
    private func takeScreenshot() {
        noteInteraction()
        showControlsBriefly()
        flashScreenshot()
        environment.router.externalNavigationDeferralCount += 1
        Task { @MainActor in
            defer { environment.router.externalNavigationDeferralCount -= 1 }
            let captured = await surface.captureFrame()
            guard let url = captured.url else {
                // 抓帧自己会给一句能直接给用户看的话（哪种方式、多少毫秒、什么尺寸），
                // 拿不到就拿它当 toast，别再只说「没抓到画面」。
                surface.toastMessage = captured.note.isEmpty ? "截图失败：没抓到画面" : captured.note
                return
            }
            let failure = await PlayerScreenshot.save(pngAt: url)
            // 临时文件不再需要；存成功也是它自己那份了。
            try? FileManager.default.removeItem(at: url)
            if let failure {
                surface.toastMessage = failure
            } else {
                // 存成功也要说话（LP 4709）：取景框闪一下只是快门，没人知道到底存没存进去。
                // 跟倍速/收藏/定时关闭同一条线（LP 4668）——这是动作结果，不是说明。
                surface.hudToastMessage = String(localized: "已保存到相册")
            }
        }
    }

    /// 取景框从外往里收、同时淡入淡出，0 → 1 走 0.55 秒（Colo 3667 的数）。
    private func flashScreenshot() {
        screenshotFlashTask?.cancel()
        withAnimation(.linear(duration: 0.55)) { screenshotFlash = 1 }
        screenshotFlashTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled else { return }
            screenshotFlash = 0
        }
    }

    /// 两侧跳转钮：快进 / 快退那颗符号，数字由**系统符号自带**（LP 2026-10-28）。
    ///
    /// 秒数在系统有对应符号的那几档（10/15/30/45/60/75/90，`goforward.15` 这种）时
    /// 直接用自带数字的符号——设置里那几档就是按这个圈的，所以正常路径永远走这条。
    /// 只有秒数落在档位外（老数据、别的入口）才回退成「箭头＋自己叠的数字」，
    /// 免得画出一个没数字的空箭头。
    private func skipButton(seconds: Int, isForward: Bool) -> some View {
        PlayerIconButton {
            ZStack {
                Image(systemName: Self.skipSymbolName(seconds: seconds, isForward: isForward))
                    .playerIcon(optical: .detailed)
                    .foregroundStyle(.white)
                // 系统符号自带数字时不再叠一层，叠上去会重影。
                if !SettingsStore.skipSecondTiers.contains(seconds) {
                    Text("\(seconds)")
                        // 10 号（LP 2026-10-28：先「快进快退和跳过 80 的数字都小一号」→ 11，
                        // 再「跳过时长 80 的数字再小一号」→ 10）。符号仍是 18pt 基准；
                        // 叠数字这条只有 80 这种不在档位里的秒数才走得到，快进快退那两颗
                        // 用的是系统自带数字的符号，不受这里影响。
                        .font(.system(size: 10, weight: .regular).monospacedDigit())
                        .foregroundStyle(.white)
                        // 数字压在符号正中偏下（LP 2026-10-28 第 8 条，两次各 0.5，累计 1.0）：
                        // 符号那圈弧下半截更宽，正中对齐看着偏上。只动数字，符号不动。
                        .offset(y: 1.0)
                }
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
    }

    /// 快进 / 快退那颗符号的名字：系统有自带数字的那几档就用带数字的
    /// （`goforward.15`），否则用空箭头、数字自己叠。
    private static func skipSymbolName(seconds: Int, isForward: Bool) -> String {
        let base = isForward ? "goforward" : "gobackward"
        let tiers = SettingsStore.skipSecondTiers
        // 只有 10…90 那几档系统才有 `goforward.10` 这样的符号。
        if tiers.contains(seconds), seconds >= 10, seconds <= 90 {
            return "\(base).\(seconds)"
        }
        return base
    }

    /// 画面按压：短按切控制栏 / 播放暂停，长按临时倍速（对应原版
    /// `player_item.dart` 的 onLongPressStart / onLongPressEnd）。
    ///
    /// 用 `onLongPressGesture` 的 pressing 回调而不是两个手势叠加：
    /// 同一次按压只会走一条分支，长按松手不会再触发一次短按。
    /// 全屏开关：进横屏 + 隐藏状态栏；退出回竖屏（原版 `DisplayModeService` 也是
    /// 退出时显式回 portraitUp，而不是「系统默认」）。
    ///
    /// 方向请求走 `requestGeometryUpdate`，只影响本次会话，不改 Info.plist 里
    /// 声明的支持方向（竖屏/横屏本来都支持）。
    /// 全屏只有一种：横屏铺满（LP 2026-10-25，不做竖屏全屏）。
    /// 所以进入时先要横屏，退出时回竖屏；转回竖屏的那一下由布局兜底退出全屏，
    /// 免得留下一个「竖着也算全屏」的状态。
    private func toggleFullscreen() {
        if isFullscreen {
            exitFullscreen()
        } else {
            isFullscreen = true
            enterLandscape()
        }
        showControls()
        noteInteraction()
    }

    /// 要横屏，并且**确认它真的转过去了**。
    ///
    /// 以前是「请求一次，睡 0.8 秒，还没横就退全屏」。第二次进全屏时系统那边
    /// 刚被上一轮锁回竖屏，转场本来就慢一点，0.8 秒常常不够——于是请求发出去了、
    /// 界面也进了全屏，却在转场半路被自己退回来，看起来就是「切回竖屏后再也切不了全屏」
    /// （LP 2026-10-28 第 2 条）。
    /// 现在改成：发请求，然后每 100 毫秒看一眼，最多等 3 秒；中途还没转就再请求一次
    /// （有些机型第二次请求才认）；3 秒还没转，才算系统真的拒绝，退回竖屏。
    private func enterLandscape() {
        // 只发一次请求，重试和收尾都在 requestOrientation 那一条链里
        // （原来这里自己又数 30 次、第 10 次再发一遍，是最早那批并发来源之一）。
        requestOrientation(.landscapeRight)
    }

    /// 窗口现在是不是横的：直接问 UIKit，不依赖 SwiftUI 的尺寸回调有没有送到。
    private var isWindowLandscape: Bool {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let scene else { return false }
        return scene.interfaceOrientation.isLandscape
    }

    private func exitFullscreen() {
        guard isFullscreen else { return }
        isFullscreen = false
        sawLandscape = false
        requestOrientation(.portrait)
        showControls()
    }

    /// 离开播放页时恢复 App 默认方向，让其它页面继续支持横屏浏览。
    private func releaseOrientation() {
        orientationRequestTask?.cancel()
        orientationGeneration += 1
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        OrientationLock.release(scene: scene)
        if let scene { notifyOrientationChange(in: scene) }
    }

    private func requestOrientation(
        _ mask: UIInterfaceOrientationMask,
        releaseAfterSuccess: Bool = false
    ) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }
        // 让 `supportedInterfaceOrientations` 跟着变，否则请求会被忽略。
        OrientationLock.mask = mask
        notifyOrientationChange(in: scene)
        // **整条转屏只留一条链**：新请求先把旧链取消，旧链里的每一步都先核对自己的
        // 代号还是不是最新的。以前是「requestOrientation 内部发两次 + 半秒兜底再发一次
        // + enterLandscape 自己数着再发一次 + 布局看到竖屏又退全屏发一次」，
        // 四条一起转、互相打断，表现出来就是「横屏切回竖屏后再也横不了」
        // （LP 2026-10-28；@developer3 4308 定位到的并发来源）。
        orientationRequestTask?.cancel()
        orientationGeneration += 1
        let generation = orientationGeneration
        let wantsLandscape = !mask.intersection(.landscape).isEmpty
        orientationRequestTask = Task { @MainActor in
            for attempt in 0..<12 {          // 12 × 250ms = 3 秒
                await Task.yield()
                guard !Task.isCancelled, generation == orientationGeneration else { return }
                // 只在最初和大约 1 秒时各发一次：每 250 毫秒都重发会让转场发抖
                // （@developer3 4320）。其余时间只轮询系统转没转过去。
                if attempt == 0 || attempt == 4 {
                    notifyOrientationChange(in: scene)
                    // 系统的原话要落到「播放信息」里，不然只有「等满 3 秒」这一句
                    // （Colo 2026-10-28 §14.10 第 5 条 / @developer3 4311）。
                    // 这个回调**必须**是 nonisolated：UIKit 在自己的队列上调它，
                    // 闭包只要继承主线程隔离，一进去就撞断言闪退（LP 4753）。
                    let failure = orientationFailure
                    scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { @Sendable error in
                        let message = String(localized: "系统拒绝：\(String(describing: error.localizedDescription))")
                        failure.record(generation: generation, message: message)
                    }
                }
                // 回调什么时候到不由我们定，每轮都取一次；取到就记进「播放信息」。
                if let failure = orientationFailure.take(generation: generation) {
                    lastOrientationResult = failure
                }
                // 已经到了就收工，别再多发。
                if scene.interfaceOrientation.isLandscape == wantsLandscape {
                    if attempt > 0 {
                    }
                    lastOrientationResult = String(localized: "已转过去")
                    if releaseAfterSuccess {
                        OrientationLock.release(scene: scene)
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled, generation == orientationGeneration else { return }
            // 等满了才算系统真的不给转：这时候把界面退回竖屏内联，
            // 别留着「界面按全屏排、窗口还是竖的」这种两边不一致的状态
            // （Colo 2026-10-28 §14.10 / @developer3 4311 第三条）。
            // 退的是**界面状态**；用户再点全屏会重新发一条请求、重设方向锁，
            // 所以不会像以前那样「退过一次就再也转不动」。
            if !lastOrientationResult.hasPrefix(String(localized: "系统拒绝")) {
                lastOrientationResult = String(localized: "请求了但系统没转（等满 3 秒）")
            }
            if isFullscreen {
                isFullscreen = false
                sawLandscape = false
            }
            OrientationLock.mask = OrientationLock.appDefault
        }
    }

    /// 把场景里每个窗口的整条控制器链都标记为需要重算支持方向。
    private func notifyOrientationChange(in scene: UIWindowScene) {
        for window in scene.windows {
            Self.markOrientationDirty(window.rootViewController)
        }
    }

    private static func markOrientationDirty(_ controller: UIViewController?) {
        guard let controller else { return }
        controller.setNeedsUpdateOfSupportedInterfaceOrientations()
        for child in controller.children {
            markOrientationDirty(child)
        }
        markOrientationDirty(controller.presentedViewController)
    }

    /// 双击：左 30% 快退、中 40% 播放 / 暂停、右 30% 快进（LP 2026-11-06 改回分区；
    /// 秒数走设置里「快进快退时长」）。即时反馈复用 1/4 线上那条浮层，不另画。
    private func handleSurfaceDoubleTap(at x: CGFloat, width: CGFloat) {
        // 锁着时双击也不生效：这把锁就是防误触的（LP 2026-10-28 第 4 条）。
        guard !isSurfaceLocked else { return }
        let seconds = settings.doubleTapSkipTime
        let ratio = width > 0 ? x / width : 0.5
        if ratio < 0.3 {
            surface.seek(to: max(0, surface.currentTime - Double(seconds)))
            flashSeekHUD(-seconds)
        } else if ratio > 0.7 {
            surface.skipForward(seconds: Double(seconds))
            flashSeekHUD(seconds)
        } else {
            surface.togglePlay()
            flashPlayPauseHUD()
        }
        showControlsBriefly()
    }

    /// 控制层浮出来 1.2 秒再淡出；暂停状态保持显示，方便接着操作。
    private func showControlsBriefly() {
        showControls()
        // 先作废按设置计时的那一条，免得两套计时同时跑。
        hideGeneration &+= 1
        let generation = hideGeneration
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, surface.isPlaying else { return }
            guard generation == hideGeneration, canHideControls else { return }
            withAnimation(.easeOut(duration: 0.2)) { controlsVisible = false }
        }
    }

    /// 点画面只切控制层显示（原版：短按显隐，不暂停）；播放/暂停在播放键上。
    private func handleSurfaceTap() {
        // 锁着时点画面只唤出解锁那颗：不显控制层、不切换播放（LP 2026-10-28 第 4 条）。
        if isSurfaceLocked {
            showUnlockAffordance()
            return
        }
        // 长按刚松手时系统会补一次短按，挡掉，别把控制层又切一遍。
        if let longPressAt = lastLongPressAt, Date().timeIntervalSince(longPressAt) < 0.4 {
            lastLongPressAt = nil
            return
        }
        // 弹幕输入框还开着时，点空白先收键盘，不动控制栏（Colo 2026-10-27）。
        if danmakuFieldFocused {
            danmakuFieldFocused = false
            return
        }
        if controlsVisible {
            withAnimation(.easeOut(duration: 0.2)) {
                controlsVisible = false
            }
        } else {
            showControls()
        }
    }

    /// 长按临时加速：原版按住期间用 `defaultShortcutForwardPlaySpeed`（默认 2.0），
    /// 松手恢复按下前的速度，不写回设置。
    /// 切超分档位：只改本次应用会话（着色器由容器按新路径重新挂上，当场生效），
    /// 再在 1/4 那条线上提示一句「超分辨率 · 质量」（Colo 2026-10-28）。
    private func applySuperResolution(_ mode: SuperResolutionMode) {
        settings.playbackSuperResolutionMode = mode
        noteInteraction()
        let text = mode == .off ? String(localized: "超分辨率 · 关闭") : String(localized: "超分辨率 · \(String(describing: mode.title))")
        withAnimation(.easeOut(duration: 0.15)) { superResolutionHUD = text }
        superResolutionHUDTask?.cancel()
        superResolutionHUDTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { superResolutionHUD = nil }
        }
    }

    private func beginTemporarySpeed() {
        // 已经在临时倍速里就什么都不做：起点只记一次，
        // 重复调用会把 2x 记成起点，松手就回不到原来的速度。
        guard !isTemporarySpeed else { return }
        isTemporarySpeed = true
        rateBeforeTemporarySpeed = playbackRate
        PlayerHaptics.bump()
        surface.setPlaybackRate(Float(settings.longPressSpeed))
    }

    private func endTemporarySpeed() {
        guard isTemporarySpeed else { return }
        isTemporarySpeed = false
        surface.setPlaybackRate(rateBeforeTemporarySpeed)
    }

    // MARK: - 控制栏自动隐藏

    private var canHideControls: Bool {
        controlsVisible && surface.isPlaying && !isScrubbing && !isEditingSkipSeconds
            && activeSheet == nil && !menuOpen
    }

    /// 从菜单里开页面：菜单自己还要收一下，同一拍里改 presentation 会被吞掉，
    /// 所以等一拍再开（「更多里的选项点了没反应」里的一半）。
    /// 收起键盘：弹幕设置里有输入框，右上角那颗关闭要先把键盘收掉再关弹窗，
    /// 不然键盘会留在屏上下次进来还弹着（Colo 2026-10-27）。
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func openSheet(_ sheet: PlayerSheet) {
        showControls()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            activeSheet = sheet
        }
    }

    /// 音频会话：播放器一打开就是 .playback。
    ///
    /// 系统只把「播放类别」的 app 当成正在播放的播放器；不是这个类别，
    /// 控制中心、锁屏、灵动岛都不会有那张卡片（LP 4491 就是这里）。
    /// 静音键管的是铃声和提示音，不该管视频音量——Apple Music 也一样。
    /// 「切后台继续出声」是另一件事，由 scenePhase 那边决定要不要暂停。
    /// 来电中断和拔耳机也挂在同一处，见 `PlayerAudioSession`。
    private func applyAudioSessionPolicy() {
        PlayerAudioSession.shared.surface = surface
        PlayerAudioSession.shared.activate()
    }

    /// 离开播放器：退回默认类别，别让整个 App 一直占着播放位。
    private func restoreAudioSessionAfterPlayer() {
        PlayerAudioSession.shared.surface = nil
        PlayerAudioSession.shared.restore()
    }

    /// 屏幕常亮：只在「真的在播」且 App 在前台时开；暂停、缓冲、播完、退后台、离开播放器全部恢复默认，
    /// 免得暂停一晚上屏幕还亮着。锁手势不影响——那时内核照样在播，就照样常亮。
    private func updateIdleTimer() {
        let active = surface.engine?.playerScene?.activationState == .foregroundActive
        let keepAwake = surface.isPlaying && active
        if UIApplication.shared.isIdleTimerDisabled != keepAwake {
            UIApplication.shared.isIdleTimerDisabled = keepAwake
        }
    }

    /// 按「控制栏消失时间」设置重新计时；不能隐藏时 `.task(id:)` 会直接返回。
    private func scheduleControlsHide() {
        hideGeneration &+= 1
    }

    private func showControls() {
        if !controlsVisible {
            withAnimation(.easeOut(duration: 0.2)) {
                controlsVisible = true
            }
        }
        scheduleControlsHide()
    }

    /// 任何一次控件交互都算「有操作」，重新计时。
    private func noteInteraction() {
        showControls()
    }

    /// 弹幕观感打包：设置页那几项 + 播放器自己的弹幕开关与当前倍速。
    /// 改成结构体是因为弹幕层要的项越来越多，一项一个参数会把调用点撑散。
    private var danmakuStyle: DanmakuOverlayView.Style {
        var style = DanmakuOverlayView.Style()
        style.enabled = danmakuEnabled
        style.opacity = settings.danmakuOpacity
        style.fontSize = settings.danmakuFontSize
        style.area = settings.danmakuArea
        style.duration = settings.danmakuDuration
        style.lineHeight = settings.danmakuLineHeight
        style.followSpeed = settings.danmakuFollowSpeed
        style.showTop = settings.danmakuTop
        style.showBottom = settings.danmakuBottom
        style.showScroll = settings.danmakuScroll
        style.massive = settings.danmakuMassive
        style.deduplication = settings.danmakuDeduplication
        style.showBiliBili = settings.danmakuBiliBiliSource
        style.showGamer = settings.danmakuGamerSource
        style.showDanDan = settings.danmakuDanDanSource
        style.border = settings.danmakuBorder
        style.borderSize = settings.danmakuBorderSize
        style.useColor = settings.danmakuColor
        style.fontWeight = settings.danmakuFontWeight
        return style
    }

    /// 黑底 + 视频画面（或解析中的状态）。拆出来是为了只在画面上挂手势，
    /// 不把顶栏按钮与错误遮罩的点击也当成「点画面暂停」。
    @ViewBuilder
    private func videoSurface(_ controller: PlayerController) -> some View {
        ZStack {
            Color.black

            if let text = controller.playbackURL, let url = URL(string: text) {
                MPVPlayerContainer(
                    url: url,
                    referer: controller.referer,
                    userAgent: controller.userAgent,
                    cookie: controller.playbackCookieHeader(for: text),
                    proxyURL: proxyURL,
                    shaderPaths: settings.playbackSuperResolutionMode.shaderPaths,
                    fillMode: aspectRatioMode.fillMode,
                    videoAspectOverride: aspectRatioMode.videoAspectOverride,
                    danmaku: controller.danmakuComments,
                    danmakuStyle: danmakuStyle,
                    danmakuPlaybackRate: isTemporarySpeed ? settings.longPressSpeed : Double(playbackRate),
                    // 横屏让开顶栏；竖屏顶栏压在画面上，保持原样。
                    danmakuTopInset: isFullscreen ? 44 : 0,
                    lowMemoryMode: settings.lowMemoryMode,
                    hardwareDecodeEnabled: settings.hardwareDecodeEnabled,
                    hardwareDecodeMode: settings.hardwareDecodeMode,
                    surface: surface
                )
            } else {
                statusOverlay(controller)
            }
        }
    }

    private func topBar(_ controller: PlayerController) -> some View {
        HStack(spacing: 6) {
            PlayerIconButton {
                logLifecycleSnapshot("returnButton.tapped")
                dismiss()
            } content: {
                Image(systemName: "chevron.left")
                    .playerIcon()
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("返回")

            if isFullscreen {
                let meta = nowPlayingMeta(controller)
                let episodeNumber = max(1, controller.currentEpisode)
                Text("\(meta.title) · \(String(format: "%02d", episodeNumber))")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 竖屏顶栏不放标题（标题在画面下面那块），留一个可压缩 Spacer
            // 把右边那组推到屏幕右缘；横屏由标题自己占满中间。
            if !isFullscreen {
                Spacer(minLength: 0)
            }

            // 横屏底栏已经有弹幕开关，顶栏这颗藏起来，不然两个开关
            // （LP 2026-10-27）。竖屏没有底栏开关，照旧留着。
            if !isFullscreen {
                danmakuButton
            }
            // 右边这一组整体锁死宽度：这几颗都是 UIKit 菜单按钮，
            // HStack 一有富余空间被压，就会把其中一颗压成 0 宽——表现出来是
            // 「收藏按钮没了」（LP 2026-10-28；跟 Colo 3300 记的那次同一个毛病）。
            HStack(spacing: 6) {
                pipEnterButton
                // 跳过那颗在收藏左边（LP 2026-10-28 第 6 条）。
                skipForwardButton
                collectButton
                // 定时关闭横竖屏都放顶栏，实时倒数直接挂在这颗上。
                sleepTimerButton
                moreMenu
            }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .onAppear { isCasting = Self.hasExternalVideoRoute }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            isCasting = Self.hasExternalVideoRoute
        }
    }

    private static var hasExternalVideoRoute: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            $0.portType == .airPlay || $0.portType == .HDMI
        }
    }

    /// 顶栏手动画中画：单符号 pip.enter，只有可用／不可用两态。
    /// 用户手势直接走控制器的单次启动，不经过自动那条 possible 门控。
    @ViewBuilder
    private var pipEnterButton: some View {
        if AVPictureInPictureController.isPictureInPictureSupported() {
            let button = PlayerIconButton {
                if pictureInPicture == nil {
                    makePictureInPictureController(settingsStore: settings)
                }
                pictureInPicture?.startFromUserTap(engine: surface.engine, surface: surface)
            } content: {
                Image(systemName: "pip.enter")
                    .playerIcon()
                    .foregroundStyle(.white)
            }
            .opacity(isCasting ? 0.4 : 1)
            .disabled(isCasting)
            .accessibilityLabel(String(localized: "开启画中画"))
            if isCasting {
                button.accessibilityHint(String(localized: "投屏时不能用"))
            } else {
                button
            }
        }
    }

    /// 横屏底栏的视频比例：点开直接选，当前项系统打勾。
    private var aspectRatioButton: some View {
        PlayerIconButton {
            SystemMenuButton(
                selection: .init(options: PlayerAspectRatioMode.allCases.map { mode in
                    .init(title: mode.label, isSelected: aspectRatioMode == mode) {
                        aspectRatioMode = mode
                    }
                }),
                title: nil,
                symbol: "aspectratio",
                accessibilityLabel: String(localized: "视频比例"),
                tint: .white,
                symbolOptical: .standard,
                onOpen: { pinControlsWhileMenuOpen() }
            )
        }
    }

    /// 顶栏的定时关闭（横竖屏都在这一组里）。
    ///
    /// 计时仍按原来的方式放在菜单里：选中的那一档标题实时显示 mm:ss。
    /// 定时关闭现在是顶层菜单，不再藏在「更多」的子菜单里，所以每秒更新
    /// 不会再把用户刚展开的子菜单收掉。
    /// 没定时是空心月亮，倒数一开始换实心并按光学补偿缩一档。
    private var sleepTimerButton: some View {
        let isRunning = sleepTimerRemaining != nil
        return PlayerIconButton {
            SystemMenuButton(
                selection: .init(options: [SystemMenuButton.Selection.Option(
                    title: String(localized: "不开启"),
                    isSelected: sleepTimerMinutes == nil
                ) {
                    cancelSleepTimer()
                }] + [15, 30, 60, 90].map { minutes in
                    SystemMenuButton.Selection.Option(
                        title: sleepTimerItemTitle(minutes),
                        isSelected: sleepTimerMinutes == minutes
                    ) {
                        startSleepTimer(minutes: minutes)
                    }
                }),
                title: nil,
                symbol: isRunning ? "moon.zzz.fill" : "moon.zzz",
                accessibilityLabel: String(localized: "定时关闭"),
                tint: .white,
                symbolOptical: isRunning ? .solid : .standard,
                onOpen: { pinControlsWhileMenuOpen() }
            )
        }
    }

    /// 收藏钮（LP 2026-10-28「顶栏收藏按钮改加号，收藏了才是实心」／Colo 3926、3929）：
    /// 未收藏是 `plus`、收藏了是实心 `heart.fill`，一律白色 18pt Medium——播放器里不用主题色，
    /// 靠实心与否区分，不靠颜色。
    ///
    /// 点一下只弹菜单，不改状态、不震动：五项状态和「取消追番」都在里面。
    /// 菜单交给 UIKit 持有，避免播放中 SwiftUI 刷新后菜单变成点不动的旧副本。
    private var collectButton: some View {
        PlayerIconButton {
            SystemMenuButton(
                items: collectMenuItems,
                title: nil,
                symbol: collectSymbolName,
                accessibilityLabel: "追番状态",
                tint: .white,
                symbolOptical: collectSymbolOptical,
                onOpen: { pinControlsWhileMenuOpen() }
            )
        }
    }

    private var collectMenuItems: [SystemMenuButton.Item] {
        var items = CollectType.enabledCases.map { type in
            SystemMenuButton.Item(
                title: type.buttonTitle,
                symbol: type.statusSymbol,
                isChecked: currentCollectType == type
            ) {
                applyCollectType(type)
            }
        }
        if currentCollectType != .none {
            items.append(
                SystemMenuButton.Item(
                    title: String(localized: "取消追番"),
                    symbol: "trash",
                    isDestructive: true
                ) {
                    applyCollectType(.none)
                }
            )
        }
        return items
    }

    /// 顶栏那颗的符号＝当前状态（Colo 3984）。
    private var collectSymbolName: String {
        switch currentCollectType {
        case .none: "plus"
        case .watching: "heart.fill"
        case .wish: "star.fill"
        case .onHold: "hourglass"
        case .watched: "checkmark"
        case .dropped: "heart.slash.fill"
        }
    }

    /// 实心状态符号视觉偏大，按光学补偿缩一档。
    private var collectSymbolOptical: PlayerIconOptical {
        switch currentCollectType {
        case .watching, .wish, .dropped: .solid
        default: .standard
        }
    }

    /// 这部番现在的收藏状态（收藏库里没有就是未收藏）。
    private var currentCollectType: CollectType {
        CollectType(rawValue: environment.library.entry(for: bangumiID)?.type ?? 0) ?? .none
    }

    /// 改收藏状态：先写回 Bangumi，成功了才动本地收藏库；
    /// 没登录时写不进去，就在画面上说一句，不假装改过。
    private func applyCollectType(_ type: CollectType) {
        guard type != currentCollectType else { return }
        noteInteraction()
        // 口径照 collect_controller.dart 的 _syncBangumiCollectIfEnabled：
        // 只有「自动同步追番」开着才推给 Bangumi；没开就是纯本地改动。
        // 推失败时这次修改整体作废 —— 本地显示「已看过」而 Bangumi 上还是「在看」，
        // 比没改更让人糊涂（原版同样是回滚 + 一句失败提示）。
        let syncEnabled = settings.bangumiSyncEnable
        let showToast = settings.bangumiImmediateSyncToastEnable
        Task {
            if syncEnabled {
                if showToast { surface.toastMessage = String(localized: "正在同步到 Bangumi...") }
                let pushed = await environment.bangumiSync.pushCollectible(
                    bangumiID: bangumiID,
                    type: type
                )
                guard pushed else {
                    surface.toastMessage = "同步到 Bangumi 失败，已取消本次状态修改"
                    return
                }
            }
            if var entry = environment.library.entry(for: bangumiID) {
                entry.type = type.rawValue
                entry.updatedAt = Date()
                environment.library.upsert(entry)
            } else if type == .none {
                // 本来就没收藏，取消追番就什么也不用改。
            } else if await addToLibrary(type) {
                // 收藏库里没有这部番：从播放器加进去（见 addToLibrary）。
            } else {
                // 拿不到番剧信息就不假装加过（跟同步失败同一条口径）。
                surface.toastMessage = String(localized: "拿不到番剧信息，没能加入收藏")
                return
            }
            if type == .none {
                BangumiTimelineStore.shared.dropIfNotWatching(bangumiID, collectType: .none)
            }
            if syncEnabled, showToast {
                surface.toastMessage = "已同步到 Bangumi"
            }
            // 收藏状态那句只走 HUD 那条线（LP 4668）；顶部那条只留给同步进度 / 结果。
            // 两处都写就会弹两次（LP 4742）。
            surface.hudToastMessage = type == .none ? String(localized: "已取消追番") : String(localized: "已标为\(String(describing: type.title))")
        }
    }

    /// 收藏库里还没有这部番时，从播放器把它加进去。
    ///
    /// 播放器手上只有番剧 ID（名字、封面都在来源那边），所以缺的字段向 Bangumi 取一次，
    /// 字段跟详情页 `applyCollect(_:_:)` 建条目那一套完全一致——两处加的必须是同一种条目。
    private func addToLibrary(_ type: CollectType) async -> Bool {
        guard let item = await BangumiAPI.info(id: bangumiID) else { return false }
        environment.library.upsert(
            LibraryEntry(
                id: item.id,
                type: type.rawValue,
                name: item.name,
                nameCn: item.nameCn,
                summary: item.summary,
                airDate: item.airDate,
                imageURL: item.largeImage,
                rating: item.ratingScore,
                rank: item.rank,
                tags: item.tags.map(\.name),
                totalEpisodes: controller?.episodes.count ?? 0,
                currentEpisode: controller?.currentEpisode ?? 0,
                addedAt: Date(),
                updatedAt: Date()
            )
        )
        BangumiTimelineStore.shared.dropIfNotWatching(bangumiID, collectType: type)
        return true
    }

    /// 用户选的那一档（选中的勾看它，不跟着倒数变）。
    private var sleepTimerMinutes: Int? {
        sleepTimerChosenMinutes
    }

    /// 档位保持固定；正在倒数的那一项标题实时显示 mm:ss（原来菜单里的计时）。
    private func sleepTimerItemTitle(_ minutes: Int) -> String {
        if sleepTimerChosenMinutes == minutes,
           let remaining = sleepTimerRemaining {
            return String(format: "%02d:%02d", remaining / 60, remaining % 60)
        }
        return String(localized: "\(String(describing: minutes)) 分钟")
    }

    /// 到点暂停。定时器是一次性的 Task，改定或取消都要把上一个收掉。
    private func startSleepTimer(minutes: Int) {
        noteInteraction()
        sleepTimerTask?.cancel()
        sleepTimerRemaining = minutes * 60
        sleepTimerChosenMinutes = minutes
        let target = minutes * 60
        sleepTimerTask = Task { @MainActor in
            var left = target
            while left > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                left -= 1
                sleepTimerRemaining = left
            }
            sleepTimerRemaining = nil
            sleepTimerChosenMinutes = nil
            surface.pause()
            // 定时关闭那句跟倍速、收藏同一条线（LP 4668）。
            surface.hudToastMessage = String(localized: "定时关闭：已暂停")
            showControls()
        }
        surface.hudToastMessage = String(localized: "定时关闭：\(String(describing: minutes)) 分钟后暂停")
    }

    private func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerRemaining = nil
        sleepTimerChosenMinutes = nil
    }

    /// 远程投屏：AirPlay / DLNA 二选一，版面见 `CastSheet`（design-cast.md）。
    private var airPlaySheet: some View {
        CastSheet(
            mediaURL: controllerURLString,
            onPlay: { surface.play() },
            onPause: { surface.pause() },
            onSeek: { surface.seek(to: $0) },
            position: surface.currentTime,
            duration: surface.duration
        )
    }

    /// 外部播放：把这一集的地址交给系统分享面板，装了 VLC、Infuse 这类播放器就能在那里打开。
    @ViewBuilder
    private var externalPlaySheet: some View {
        if let urlString = controllerURLString, let url = URL(string: urlString) {
            ShareSheet(items: [url])
                .presentationDetents([.medium, .large])
        } else {
            ContentUnavailableView("还没有解析出地址", systemImage: "play.slash")
                .presentationDetents([.height(200)])
        }
    }

    /// 播放信息：这一集文件的实际编码规格 + 媒体地址，只读。
    /// 值从 mpv 现读，拿不到的项写「—」；深浅色跟着主题走。
    private var videoInfoSheet: some View {
        let info = surface.playbackInfo()
        let mediaURL = controllerURLString
        let rows: [(title: String, value: String)] = [
            (String(localized: "视频编码"), info?.videoCodec ?? "—"),
            (String(localized: "分辨率"), info?.resolution ?? "—"),
            (String(localized: "帧率"), info?.frameRate ?? "—"),
            (String(localized: "码率"), info?.videoBitrate ?? "—"),
            (String(localized: "音频编码"), info?.audioCodec ?? "—"),
            (String(localized: "声道"), info?.audioChannels ?? "—"),
            (String(localized: "采样率"), info?.sampleRate ?? "—"),
            (String(localized: "容器"), info?.container ?? "—"),
            (String(localized: "方向"), orientationSummary),
            // 超分到底有没有喂进 mpv：这里显示真正找到的着色器文件数
            // （Colo 2026-10-28：是 0 就是没挂上，是 6 但画面没变才是着色器本身的问题）。
            ("超分辨率", String(localized: "\(String(describing: settings.playbackSuperResolutionMode.title)) · \(String(describing: surface.appliedShaderCount())) 颗着色器（已挂）")),
        ]
        return NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows.indices, id: \.self) { index in
                        if index > 0 {
                            Divider()
                                .padding(.leading, 16)
                        }
                        infoRow(rows[index])
                    }
                    Divider()
                        .padding(.leading, 16)
                    mediaURLRow(mediaURL)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
            .background(KazumiPalette.groupedBackground(for: colorScheme).ignoresSafeArea())
            .navigationTitle("播放信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        activeSheet = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(Color.primary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("关闭")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onDisappear {
            // 关掉时把「已复制」与定时器收干净，下次打开不带着上一次的状态。
            mediaURLCopiedTask?.cancel()
            mediaURLCopied = false
        }
        .presentationDetents([.medium, .large])
    }

    /// 「方向」那一行的值：支持哪些、现在是哪个、上次请求什么结果。
    /// 横屏切不回横屏时，一眼就能分出是系统没给还是我们没请求（Colo 2026-10-28）。
    private var orientationSummary: String {
        let supported = OrientationLock.mask
        var names: [String] = []
        if supported.contains(.portrait) { names.append(String(localized: "竖")) }
        if supported.contains(.landscapeLeft) { names.append(String(localized: "横左")) }
        if supported.contains(.landscapeRight) { names.append(String(localized: "横右")) }
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let current: String
        switch scene?.interfaceOrientation {
        case .landscapeLeft: current = "横左"
        case .landscapeRight: current = "横右"
        case .portrait, .portraitUpsideDown: current = "竖"
        default: current = "—"
        }
        let nameList = names.joined(separator: "+")
        return String(localized: "支持 \(nameList) · 当前 \(current) · \(lastOrientationResult)")
    }

    /// 播放信息里的一条：左标题、右值。
    private func infoRow(_ row: (title: String, value: String)) -> some View {
        HStack(spacing: 16) {
            Text(row.title)
                .font(.footnote)
                .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
            Spacer(minLength: 12)
            Text(row.value)
                .font(.system(size: 15).monospacedDigit())
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }

    /// 媒体地址：点一下复制完整地址；复制后右侧闪一下「已复制」并震一下。
    /// 屏上只显示一行、中间截断，长地址不会把排版撑破。
    private func mediaURLRow(_ urlString: String?) -> some View {
        Button {
            guard let urlString else { return }
            UIPasteboard.general.string = urlString
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            mediaURLCopied = true
            mediaURLCopiedTask?.cancel()
            mediaURLCopiedTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1200))
                guard !Task.isCancelled else { return }
                mediaURLCopied = false
            }
        } label: {
            HStack(spacing: 16) {
                Text("媒体地址")
                    .font(.footnote)
                    .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                Spacer(minLength: 12)
                Text(mediaURLCopied ? "已复制" : (urlString ?? "—"))
                    .font(.system(size: 15).monospacedDigit())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(
                        mediaURLCopied
                            ? KazumiPalette.accent(for: colorScheme)
                            : Color.primary
                    )
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(urlString == nil)
        .accessibilityLabel("媒体地址")
        .accessibilityValue(mediaURLCopied ? "已复制" : (urlString ?? String(localized: "不可用")))
        .accessibilityHint("点按复制完整地址")
    }

    /// 片头片尾弹窗的右边距：横屏离窗口右缘 90，竖屏 20（跟 main 一致）。
    /// 横屏要比竖屏再靠右 50：右边距是「离右缘多远」，所以是**减小**——
    /// 之前写成 90→140 反而把胶囊往左推了 50，LP 2026-10-28「横屏的还没有右移」。
    private var skipPillTrailingInset: CGFloat { isFullscreen ? 40 : 20 }

    /// 片头片尾弹窗的底边距：横屏固定（不随控制栏显隐），竖屏跟着控制栏走。
    private var skipPillBottomInset: CGFloat {
        // 竖屏不再跟着控制栏躲（LP 2026-10-28「不用避让控制栏」）：位置钉死。
        // 原来是 `containerInsets.bottom + (controlsVisible ? 48 : 28)`，跟着控制栏
        // 显隐在两个位置之间跳；现在固定在「显示」那条线再往下 30（48 - 30 = 18）。
        // 之前写成 +58 反而往上抬了 10，所以 LP 看着「一点没变」。
        isFullscreen
            ? containerInsets.bottom + 63
            : containerInsets.bottom + 18
    }

    /// 当前这一集的媒体地址（解析出来才有）。
    private var controllerURLString: String? {
        guard let text = controller?.playbackURL, !text.isEmpty else { return nil }
        return text
    }

    /// 弹幕开关：关是 `text.bubble`，开是 `text.bubble.fill`；横竖屏都用统一的
    /// 40×40 热区、18pt Medium，实心态按光学补偿缩一档。
    private var danmakuButton: some View {
        PlayerIconButton {
            noteInteraction()
            handleDanmakuButton()
        } content: {
            Image(systemName: danmakuEnabled ? "text.bubble.fill" : "text.bubble")
                .playerIcon(optical: danmakuEnabled ? .solid : .standard)
                .foregroundStyle(.white)
        }
        .accessibilityLabel(danmakuEnabled ? "关闭弹幕" : "打开弹幕")
    }

    private func handleDanmakuButton() {
        if danmakuEnabled {
            danmakuEnabled = false
            return
        }
        if controller?.danmakuStatus == .loading {
            surface.hudToastMessage = String(localized: "弹幕正在加载")
            return
        }
        if let comments = controller?.danmakuComments, !comments.isEmpty {
            danmakuEnabled = true
            return
        }
        openSheet(.danmakuSource)
    }

    private var danmakuInitialKeyword: String {
        let library = environment.library
        if let entry = library.entry(for: bangumiID), !entry.displayName.isEmpty {
            return entry.displayName
        }
        if let record = library.record(for: bangumiID), !record.bangumiName.isEmpty {
            return record.bangumiName
        }
        return source?.itemName ?? ""
    }

    private func applyManualDanmaku(_ episode: DanmakuEpisode) async -> String? {
        guard let controller else {
            return String(localized: "播放器已关闭")
        }
        switch await controller.loadDanmaku(episodeID: episode.episodeID) {
        case .loaded:
            danmakuEnabled = true
            return nil
        case .empty:
            return nil
        case .failed(let message):
            danmakuEnabled = false
            return message
        }
    }

    /// 弹幕设置的图标：20×18 画布里两条横线，右下角压一颗 8pt 齿轮。
    /// 按钮用 SwiftUI 叠，系统菜单里用这张 UIImage——两边同一套尺寸。
    /// 渲好的图按深浅色各存一张：颜色跟着当前外观定，切外观不会用错那张。
    private nonisolated(unsafe) static var cachedDanmakuSettingsIcons: [String: UIImage] = [:]

    private var danmakuSettingsIcon: UIImage {
        // 菜单里那条要的是 UIImage，就把同一个 View 渲成图（Colo 2026-10-28）：
        // 一处写、两处引用，横屏底栏和「更多 → 弹幕设置」不会再走样。
        let key = colorScheme == .dark ? "dark" : "light"
        if let cached = Self.cachedDanmakuSettingsIcons[key] { return cached }
        let rendered = Self.renderDanmakuSettingsIcon(scheme: colorScheme)
        Self.cachedDanmakuSettingsIcons[key] = rendered
        return rendered
    }

    private static func renderDanmakuSettingsIcon(scheme: ColorScheme) -> UIImage {
        // 菜单里那颗跟播放器里是同一个 View；渲成模板图后由系统统一 tint。
        // 颜色只影响渲染时的 alpha 形状，最终显示颜色跟旁边 SF Symbols 一致。
        let dark = scheme == .dark
        let renderer = ImageRenderer(
            content: DanmakuSettingsGlyph(color: dark ? .white : .black)
                .environment(\.colorScheme, scheme)
        )
        renderer.scale = 3
        // 菜单里的图标必须走模板色，跟同一菜单里的 SF Symbols 用同一份 tint；
        // 否则渲染图自带黑白，浅色/深色下都会比旁边的符号偏一档。
        return (renderer.uiImage ?? UIImage()).withRenderingMode(.alwaysTemplate)
    }

    /// 弹幕设置：跟横屏开关同一套两条横线符号，右下角多一颗小齿轮——
    /// 两个符号占一个符号位，命中仍是 40×40（LP 2026-10-27）。
    private func danmakuSettingsButton() -> some View {
        PlayerIconButton {
            openSheet(.danmakuSettings)
        } content: {
            // 跟「更多 → 弹幕设置」那条用同一张图：一份实现画出来，两边不可能再走样
            // （LP 2026-10-28「横屏和竖屏更多菜单的要一起改，不要只改一个」）。
            DanmakuSettingsGlyph(color: .white)
        }
        .accessibilityLabel("弹幕设置")
    }

    /// 「更多」：只剩点一下就有反应、没有二级的项。
    ///
    /// 用系统 `Menu`：玻璃、行高、宽度、箭头全由系统画——LP 要的就是原来那颗
    /// 系统菜单的观感，自绘只能做到八分像。带二级的那三项（超分辨率、画面比例、
    /// 睡眠定时）拿出去，收在「播放选项」里（Colo / Ato 2026-10-25）。
    ///
    /// 菜单不把开合告诉代码，控制层的自动隐藏靠 `SystemMenuProbe` 看菜单在不在，
    /// 在就不收层。
    /// 「更多」：点一下弹系统菜单。
    /// UIKit 自己持有菜单和动作；播放状态刷新不会把屏幕上的菜单换成无主副本。
    private var moreMenu: some View {
        PlayerIconButton {
            SystemMenuButton(
                items: moreMenuItems,
                title: nil,
                symbol: "ellipsis",
                accessibilityLabel: "更多选项",
                tint: .white,
                symbolOptical: .detailed,
                onOpen: { pinControlsWhileMenuOpen() }
            )
        }
    }

    private var moreMenuItems: [SystemMenuButton.Item] {
        // 弹幕设置：横屏底栏有直接入口，这里那条就删掉（同一件事不留两个门）；
        // 竖屏没底栏，入口留在这儿，图标跟横屏那颗同一套（Colo 2026-10-27）。
        var items: [SystemMenuButton.Item] = []
        if !isFullscreen {
            items.append(
                SystemMenuButton.Item(
                    title: "弹幕设置",
                    symbol: "captions.bubble",
                    symbolImage: danmakuSettingsIcon
                ) {
                    closeMenu()
                    openSheet(.danmakuSettings)
                }
            )
        }
        // 竖屏没有底栏，倍速和超分辨率都只剩菜单这一个入口（LP 2026-10-28）。
        if !isFullscreen {
            items.append(
                SystemMenuButton.Item(
                    title: "超分辨率",
                    symbol: "wand.and.stars",
                    subtitle: settings.playbackSuperResolutionMode.title,
                    selection: .init(options: SuperResolutionMode.allCases.map { mode in
                        .init(
                            title: mode.title,
                            isSelected: settings.playbackSuperResolutionMode == mode
                        ) {
                            applySuperResolution(mode)
                        }
                    })
                ) {}
            )
            items.append(
                SystemMenuButton.Item(
                    title: "倍速",
                    symbol: "speedometer",
                    subtitle: speedText(Double(playbackRate)),
                    selection: .init(options: PlaybackSpeed.all.map { rate in
                        .init(
                            title: speedText(rate),
                            isSelected: abs(playbackRate - Float(rate)) < 0.01
                        ) {
                            applySpeed(Float(rate))
                            noteInteraction()
                        }
                    })
                ) {}
            )
        }
        // 横屏底栏已经有视频比例；远程投屏不再占顶栏，统一收进「更多」。
        let displayMenuItems: [SystemMenuButton.Item] = isFullscreen ? [
            SystemMenuButton.Item(title: "远程投屏", symbol: "airplayvideo") {
                closeMenu()
                openSheet(.airPlay)
            },
        ] : [
            SystemMenuButton.Item(title: "远程投屏", symbol: "airplayvideo") {
                closeMenu()
                openSheet(.airPlay)
            },
            SystemMenuButton.Item(
                title: "视频比例",
                symbol: "aspectratio",
                subtitle: aspectRatioMode.label,
                selection: .init(options: PlayerAspectRatioMode.allCases.map { mode in
                    .init(title: mode.label, isSelected: aspectRatioMode == mode) {
                        aspectRatioMode = mode
                    }
                })
            ) {}
        ]
        return items + [
            SystemMenuButton.Item(title: "播放信息", symbol: "info.circle") {
                closeMenu()
                openSheet(.videoInfo)
            },
        ] + displayMenuItems + [
            SystemMenuButton.Item(title: String(localized: "外部播放"), symbol: "arrow.up.forward.app") {
                closeMenu()
                openSheet(.externalPlay)
            },
            SystemMenuButton.Item(title: "一起看", symbol: "person.2.wave.2") {
                closeMenu()
                openSheet(.syncPlay)
            },
            // 定时关闭已经统一放顶栏，「更多」里不再重复一份。
        ]
    }

    /// 「更多 → 追番状态」的子菜单：五项状态 + 取消追番，勾在现在这一项上。
    /// 菜单弹出来了：控制栏先别收。
    ///
    /// 系统菜单是挂在弹出它的那颗按钮上的。控制栏一收，按钮就被关掉点击，
    /// 菜单还留在屏幕上但点谁都没主（LP 2026-10-25「能打开还是无法点击」）。
    private func pinControlsWhileMenuOpen() {
        showControls()
        menuOpen = true
        probeSawMenu = false
        menuOpenedAt = Date()
        probeLastSeen = Date()
        // 已经排上的收层计时作废，等菜单关了重新起算。
        hideGeneration &+= 1
    }

    /// 菜单里点了一项：菜单这就收了，控制栏可以照常计时。
    private func closeMenu() {
        menuOpen = false
        probeSawMenu = false
    }

    /// 顶部快进按钮：单击快进，长按修改秒数（对应原版 player_item_panel 的快进按钮）。
    private var skipForwardButton: some View {
        // 数字放进符号里、不带单位（LP 2026-10-28 第 9 条）：跟两侧那两颗
        // 快进快退同一个画法，一眼就知道是多少秒，也不用再写「秒」字。
        skipButton(seconds: settings.buttonSkipTime, isForward: true)
            // 单击与长按必须互斥：两个手势各挂一次时，长按松手会再触发
            // 一次单击，用户点开「跳过秒数」的同时画面已经快进了。
            .gesture(
                LongPressGesture(minimumDuration: 0.5)
                    .onEnded { _ in presentSkipSecondsDialog() }
                    .exclusively(
                        before: TapGesture().onEnded {
                            surface.skipForward(seconds: Double(settings.buttonSkipTime))
                        }
                    )
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("快进")
            .accessibilityHint(String(localized: "快进\(String(describing: settings.buttonSkipTime))秒，长按修改时间"))
            .accessibilityAddTraits(.isButton)
    }

    private func errorOverlay(_ message: String, controller: PlayerController) -> some View {
        // 错误要整块居中（LP 5485：符号、文字、按钮原来都偏上）：
        // 1/4 那条线是给转圈的加载提示留的，出错时用它会显得没居中。
        ZStack {
            Color.black.opacity(0.55)
            errorContent(message, controller: controller)
                .padding(.horizontal, 24)
        }
        .allowsHitTesting(true)
    }

    private func errorContent(_ message: String, controller: PlayerController) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("重新加载") {
                surface.errorMessage = nil
                Task { await controller.retry() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func statusOverlay(_ controller: PlayerController) -> some View {
        // 圈跟加载信息、集数一起从正中那条线往下排（LP 4913）。
        loadingAtCenterLine {
        VStack(spacing: 10) {
            switch controller.phase {
            case .idle, .searchingSource, .resolvingChapters, .parsingMedia:
                // 解析阶段还没有 mpv，拿不到网速，所以只转圈（`bytesPerSecond` 默认 0）。
                PlayerLoadingHUD(info: phaseTitle(controller.phase), reservesSpeedLine: false)
                // 切集时先亮一下目标集数，代替原版的「正在加载${集标题}」
                // （原生这边只有 URL，没有集标题）。
                if showsEpisodeLoadingLine(controller.phase) {
                    Text(String(localized: "正在加载第 \(String(describing: controller.currentEpisode)) 集"))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                // Camo 5208：本集还没下完、这轮要走在线解析，说一句。
                // 位置跟上面那行同处；起播成功或失败（phase 变化）就收。
                if controller.isEpisodeIncomplete {
                    Text("本集下载未完成，正在尝试在线播放")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
                // 原来这儿挂着内核日志的最后一行。LP 4810：屏蔽掉，
                // 画面上只留圈（+ 网速），日志照旧进 KazumiLogBuffer 给排查用。
            case .failed:
                // 失败提示不压在画面正中间：挪到下面「选集」那一块里
                // （平时列剧集的位置），跟页面一起推进来（LP 3286 / Colo 3287）。
                EmptyView()
            case .ready:
                EmptyView()
            }
        }
        }
    }

    private func phaseTitle(_ phase: PlayerController.Phase) -> String {
        switch phase {
        case .idle: String(localized: "准备中…")
        case .searchingSource: String(localized: "正在查找播放源…")
        case .resolvingChapters: String(localized: "正在加载剧集列表…")
        case .parsingMedia: String(localized: "正在解析播放地址…")
        case .ready: ""
        case .failed: ""
        }
    }

    /// 「正在加载第 N 话」只在真正要播某一集时出现；查找播放源阶段还没定集数。
    private func showsEpisodeLoadingLine(_ phase: PlayerController.Phase) -> Bool {
        switch phase {
        case .idle, .resolvingChapters, .parsingMedia: true
        case .searchingSource, .ready, .failed: false
        }
    }

    /// 查找播放源阶段顶行已经是「正在查找播放源…」，不再叠一行同义的日志。
    private func showsLogLine(_ phase: PlayerController.Phase) -> Bool {
        phase != .searchingSource
    }

    // MARK: - 播放条

    /// 播放条：一条，压在画面底部。播放键、进度、时间、倍速、全屏。
    /// 倍速从「更多」里提上来——它是这一轮要的常动作，且 3× 以前根本选不到。
    /// 底栏。竖屏单行（播放/暂停｜进度条｜当前 / 总长｜全屏）；
    /// 横屏两行（Colo 3613，照 main 非 compact）：时间在上、进度条一行，按钮一行。
    private func transportBar(_ controller: PlayerController, width: CGFloat) -> some View {
        Group {
            // 全屏就是横屏（竖屏那颗全屏键是唯一入口），直接看它，
            // 不等量出来的宽度——初值 0 会先画一帧单行再跳成两行（Colo 3627）。
            if isFullscreen || width >= 600 {
                landscapeTransport(controller)
            } else {
                portraitTransport
            }
        }
    }

    private var portraitTransport: some View {
        HStack(spacing: 8) {
            playPauseButton
            scrubber
            timeLabel
            fullscreenButton
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(height: 52)
    }

    /// 横屏：时间文字在进度条上方（左 10、下 10），进度条左右各 10，
    /// 再下面一行按钮（左右各 10）。按钮行按 Colo 3613 的精简版：手机横屏放不下十颗。
    private func landscapeTransport(_ controller: PlayerController) -> some View {
        VStack(spacing: 0) {
            timeLabel
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 16)
                .padding(.bottom, 8)

            scrubber
                .padding(.horizontal, 16)

            HStack(spacing: 8) {
                playPauseButton
                nextEpisodeButton(controller)
                danmakuButton
                // 横屏两棵弹幕键并排：开关 + 设置（LP 2026-10-27）。
                danmakuSettingsButton()
                danmakuField
                    .frame(maxWidth: .infinity)
                superResolutionButton
                speedButton
                aspectRatioButton
                episodesButton
                fullscreenButton
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
        }
        .padding(.bottom, 12)
    }

    /// `当前 / 总长`，12 号白色、等宽数字，长短不变不跳（竖屏在进度条右边）。
    private var timeLabel: some View {
        Text("\(timeText(isScrubbing ? scrubValue : surface.currentTime)) / \(timeText(surface.duration))")
            .font(.system(size: 12, weight: .regular).monospacedDigit())
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
    }

    private var playPauseButton: some View {
        PlayerIconButton {
            surface.togglePlay()
            // 跟双击中间那一朵共用同一个指示器（LP 4689）：两种按法都出同一句话、
            // 同一个位置，不分开各画一套。
            flashPlayPauseHUD()
            noteInteraction()
        } content: {
            Image(systemName: surface.isPlaying ? "pause.fill" : "play.fill")
                .playerIcon(optical: .solid)
                .foregroundStyle(.white)
        }
        .accessibilityLabel(surface.isPlaying ? "暂停" : "播放")
    }

    private var fullscreenButton: some View {
        PlayerIconButton {
            toggleFullscreen()
        } content: {
            // 符号跟着当前状态走：进全屏是放大，退出是全屏箭头收回。
            Image(systemName: isFullscreen
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right")
                .playerIcon(optical: .detailed)
                .foregroundStyle(.white)
        }
        .accessibilityLabel(isFullscreen ? "退出全屏" : "全屏")
    }

    /// 下一集：没有下一集时灰掉。
    private func nextEpisodeButton(_ controller: PlayerController) -> some View {
        let hasNext = controller.currentEpisode < controller.episodes.count
        return PlayerIconButton {
            guard hasNext else { return }
            noteInteraction()
            Task { await controller.selectEpisode(controller.currentEpisode + 1) }
        } content: {
            Image(systemName: "forward.end.fill")
                .playerIcon(optical: .solid)
                .foregroundStyle(.white.opacity(hasNext ? 1 : 0.35))
        }
        .disabled(!hasNext)
        .accessibilityLabel("下一集")
    }

    /// 横屏那颗超分辨率：点开就是模式列表，当前项系统打勾（Colo 2026-10-28）。
    private var superResolutionButton: some View {
        PlayerIconButton {
            SystemMenuButton(
                selection: .init(options: SuperResolutionMode.allCases.map { mode in
                    .init(title: mode.title, isSelected: settings.playbackSuperResolutionMode == mode) {
                        applySuperResolution(mode)
                    }
                }),
                title: nil,
                symbol: "wand.and.stars",
                accessibilityLabel: String(localized: "超分辨率 \(String(describing: settings.playbackSuperResolutionMode.title))"),
                symbolOptical: .detailed,
                onOpen: { pinControlsWhileMenuOpen() }
            )
        }
    }

    /// 横屏那颗倍速：底栏只放符号，当前值点开菜单看（Colo 2026-10-28）。
    private var speedButton: some View {
        PlayerIconButton {
            SystemMenuButton(
                selection: .init(options: PlaybackSpeed.all.map { rate in
                    .init(
                        title: speedText(rate),
                        isSelected: abs(playbackRate - Float(rate)) < 0.01
                    ) {
                        applySpeed(Float(rate))
                        noteInteraction()
                    }
                }),
                title: nil,
                symbol: "speedometer",
                accessibilityLabel: String(localized: "倍速 \(String(describing: speedText(Double(playbackRate))))"),
                symbolOptical: .standard,
                onOpen: { pinControlsWhileMenuOpen() }
            )
        }
    }

    private var episodesButton: some View {
        PlayerIconButton {
            // 再点一次收起（Colo §7）。
            if showsEpisodesPanel {
                closeEpisodesPanel()
            } else {
                openEpisodesPanel()
            }
        } content: {
            Image(systemName: "list.bullet")
                .playerIcon()
                .foregroundStyle(.white)
        }
        .accessibilityLabel("选集")
    }

    /// 横屏选集：从右侧滑进来的玻璃窗口（LP 3637）。
    /// 复用竖屏那块 `episodesPane`，所以 100 集以上的分块跳转、线路菜单、
    /// 加载失败态都是同一套；打开时把在播那集滚到中间（LP 3640）。
    private func episodesPanel(_ controller: PlayerController) -> some View {
        // 宽度照 Colo §7：可用宽的九成封顶，常态取三分之一，手机横屏 844 落地就是 320。
        let available = max(surfaceWidth, 360)
        let panelWidth = min(available * 0.9, min(max(available / 3, 320), 420))
        return episodesPane(controller, centersCurrentEpisode: true)
            .frame(width: panelWidth)
            .frame(maxHeight: .infinity)
            // 右缘别贴到安全区边上：留 16，加上这一侧的安全区就是离屏幕边的最小距离
            // （Colo：贴边时右上、右下那两格会被屏幕圆角切掉）。
            .padding(.trailing, 16)
            .background { GlassBackdrop() }
            // 只有左边两个角是圆的，右边贴着屏边（Colo §7：32）。
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 32,
                    bottomLeadingRadius: 32,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0,
                    style: .continuous
                )
            )
            .ignoresSafeArea(edges: .vertical)
    }

    private func openEpisodesPanel() {
        showControls()
        // 面板开着的时候控制层不许自己收走，不然底栏先没了、面板还挂着。
        pinControlsWhileMenuOpen()
        withAnimation(.easeOut(duration: 0.12)) {
            showsEpisodesPanel = true
        }
    }

    private func closeEpisodesPanel() {
        withAnimation(.easeOut(duration: 0.12)) {
            showsEpisodesPanel = false
        }
        closeMenu()
    }

    /// 横屏底栏里的发弹幕：白 38% 底、圆角、13 号、hint 照原版，右边一颗「发送」。
    /// 弹幕关着时整个框灰掉并挡住输入——发了也看不见，不如先说清楚。
    private var danmakuField: some View {
        HStack(spacing: 6) {
            TextField(
                "",
                text: $danmakuDraft,
                prompt: Text("发个友善的弹幕见证当下")
                    .foregroundStyle(.white.opacity(0.7))
            )
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .tint(.white)
            .focused($danmakuFieldFocused)
            .submitLabel(.send)
            .onSubmit { sendDanmaku() }
            .disabled(!danmakuEnabled)
            .onChange(of: danmakuFieldFocused) { _, focused in
                if focused {
                    // 只在真播着时停：本来暂停的不动。
                    if surface.isPlaying {
                        surface.pause()
                        pausedForDanmakuInput = true
                    }
                } else if pausedForDanmakuInput {
                    pausedForDanmakuInput = false
                    // 播完、或者还没就绪的，不替用户拉起来。
                    let atEnd = surface.duration > 0
                        && surface.currentTime >= surface.duration - 0.5
                    if controllerPhase == .ready, !atEnd, !surface.isPlaying {
                        surface.play()
                    }
                }
            }

            Button {
                sendDanmaku()
            } label: {
                Text("发送")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(canSendDanmaku ? .white : .white.opacity(0.45))
                    .padding(.horizontal, 6)
                    .frame(height: 33)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlayerPressStyle())
            .disabled(!canSendDanmaku)
            .accessibilityLabel("发送弹幕")
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .frame(height: 33)
        .background(.white.opacity(danmakuEnabled ? 0.38 : 0.18),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var canSendDanmaku: Bool {
        danmakuEnabled && !danmakuDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 发出去：只在本地画布上补一条（原版 `_sendDanmaku` 也不调接口），清空、收键盘。
    private func sendDanmaku() {
        let text = danmakuDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard danmakuEnabled, !text.isEmpty else { return }
        surface.danmakuOverlay?.sendLocal(text: text)
        danmakuDraft = ""
        danmakuFieldFocused = false
        noteInteraction()
        showControlsBriefly()
    }

    /// 进度条：交给系统 `Slider`（原生轨道与拇指），不再自绘。
    /// 拖动中读本地 `scrubValue` 预览，松手才真 seek——画面不跟着每一帧抖。
    /// 进度条：只有轨道，没有拇指。未播白 30%、已播纯白，靠色差看进度
    /// （LP 2026-10-27「胶囊白块除了占空毫无意义」）。交互不删：整条 44 高都能拖。
    private var scrubber: some View {
        let total = max(surface.duration, 0.001)
        let current = min(max(isScrubbing ? scrubValue : surface.currentTime, 0), total)
        let progress = total > 0 ? min(max(current / total, 0), 1) : 0
        return GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            // 目标时间那个小球：越靠两端越往里收，不让它跑出屏幕（Ato 6223）。
            let bubbleWidth: CGFloat = 72
            let bubbleX = min(max(scrubFingerX - bubbleWidth / 2, 0), max(width - bubbleWidth, 0))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.3))
                    .frame(height: 4)
                Capsule()
                    .fill(.white)
                    .frame(width: width * progress, height: 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isScrubbing { onScrub(true) }
                        let x = min(max(value.location.x, 0), width)
                        scrubFingerX = x
                        let ratio = x / width
                        scrubValue = Double(ratio) * total
                    }
                    .onEnded { _ in onScrub(false) }
            )
            .overlay(alignment: .topLeading) {
                if isScrubbing {
                    scrubTimeBubble
                        .frame(width: bubbleWidth)
                        .offset(x: bubbleX, y: -22)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityLabel("播放进度")
        .accessibilityValue(timeText(current))
    }

    /// 拖动时浮在轨道上方的那条目标时间：跟其他时间同一个格式，松手就收。
    private var scrubTimeBubble: some View {
        Text(timeText(scrubValue))
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.white.opacity(0.92), in: Capsule())
    }

    private func speedText(_ value: Double) -> String { PlaybackSpeed.label(value) }

    private func applySpeed(_ rate: Float) {
        playbackRate = rate
        surface.setPlaybackRate(rate)
        // 倍速指示跟长按倍速胶囊同一条线（画面 1/4 处），LP 4668。
        surface.hudToastMessage = PlaybackSpeed.label(Double(rate))
    }

    private func onScrub(_ editing: Bool) {
        if editing {
            scrubValue = surface.currentTime
            isScrubbing = true
        } else {
            surface.seek(to: scrubValue)
            isScrubbing = false
        }
        PlayerHaptics.tap()
    }

    private func timeText(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "00:00" }
        let total = Int(value)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - 进度与续播

    private func persistProgress(_ controller: PlayerController) {
        persistWatchProgress(
            library: environment.library,
            privateMode: settings.privateMode,
            controller: controller,
            position: surface.currentTime,
            duration: surface.duration
        )
        // 「自动标记看过」的消费端：看到 90% 就在 Bangumi 上把这集标成看过。
        // 隐身模式不标 —— 用户按下隐身就是不想在服务器留下痕迹。
        guard !settings.privateMode else { return }
        environment.bangumiProgress.onPosition(
            subjectID: controller.bangumiID,
            episodeNumber: controller.currentEpisode,
            position: surface.currentTime,
            duration: surface.duration
        )
    }

    /// 进入播放器时按「自动跳转」设置恢复同一集的播放位置。
    /// 只有存的正是当前这一集才续播，换集不迁跳（保留现有行为）。
    private func resumeIfNeeded(library: LibraryStore, controller: PlayerController) {
        guard settings.playResume else { return }
        // 按「这条规则 + 这部番」取记录，不是跨规则取最新那份（Fuck 4875）：
        // 详情页 / 推荐页是按这条规则算出集数和线路的，位置也得是这条规则记下的；
        // 拿最新那份一比规则名不一样就整个 bail，这条源存的进度就用不上了。
        // 没带源进来时（历史页进）记录本身就是那个源，按番剧号取。
        // 历史卡片进来时源还没重建，用卡片上带的那条规则名。
        let pluginName = controller.source?.pluginName ?? controller.resumeRule ?? ""
        let record = pluginName.isEmpty
            ? library.record(for: controller.bangumiID)
            : library.record(for: controller.bangumiID, pluginName: pluginName)
        guard let record else { return }
        guard record.episodeNumber == controller.currentEpisode else { return }
        guard record.progressSeconds > 1 else { return }
        // 存在结尾 5 秒内的一律当已看完，不续播（避免一进去就结束）。
        if record.durationSeconds > 0, record.progressSeconds >= record.durationSeconds - 5 {
            return
        }
        surface.pendingResumeTime = record.progressSeconds
    }

    // MARK: - 正在播放（控制中心 / 锁屏 / 灵动岛）

    /// 当前这一集在控制中心里叫什么、封面用哪张。
    /// 追番列表里有就用它，否则退到观看记录，再退到播放源里的条目名。
    private func nowPlayingMeta(_ controller: PlayerController) -> (title: String, artwork: String) {
        let library = environment.library
        if let entry = library.entry(for: controller.bangumiID), !entry.displayName.isEmpty {
            return (entry.displayName, entry.imageURL)
        }
        if let record = library.record(for: controller.bangumiID), !record.bangumiName.isEmpty {
            return (record.bangumiName, record.imageURL)
        }
        if let name = controller.source?.itemName, !name.isEmpty {
            return (name, "")
        }
        return ("Kazumi", "")
    }

    /// 把这一集的剧名、集数、封面、进度交给系统。
    /// 系统拿它画控制中心和锁屏那张卡；灵动岛上 Apple Music 那个样子也由它决定。
    private func syncNowPlaying() {
        guard let controller else { return }
        // 起播后再校一次音频会话：mpv 的音频输出会自己重设类别，
        // 一旦它盖成混音，系统就不会把我们当「正在播放」。
        // 注意这里**会写**：被盖成混音时要改类别，改不动就退一次会话再上，
        // 只在真的被盖掉时才发生，不是每次都写。
        PlayerAudioSession.shared.reapplyIfNeeded()
        // 还没拿到片源（时长 0）且没在播时不写：控制中心不该挂一张 00:00 的空卡片。
        guard surface.duration > 0 || surface.isPlaying else { return }
        // 「正在播放」这个位置是不是我们的？`isOtherAudioPlaying` 为 true 就说明
        // 会话还攥在别的 App 手里：卡能画出来，但点它不会回到这个 App
        // （LP 4976 第 2 条要查的就是这个）。只在变了的时候写，不每 2 秒刷一行。
        let otherAudioPlaying = AVAudioSession.sharedInstance().isOtherAudioPlaying
        if lastOtherAudioPlaying != otherAudioPlaying {
            lastOtherAudioPlaying = otherAudioPlaying
            KazumiLogBuffer.player("音频会话：别的 App 占着=\(otherAudioPlaying ? "是" : "否")")
        }
        let meta = nowPlayingMeta(controller)
        NowPlayingCenter.shared.update(
            title: meta.title,
            episode: controller.currentEpisode,
            episodeTitle: nil,
            artworkURL: meta.artwork,
            duration: surface.duration,
            elapsed: surface.currentTime,
            isPlaying: surface.isPlaying,
            // 真实倍速（含长按的临时倍速）：系统按这个速率自己往前推进度，
            // 写 1.0 的话 2 倍速下偏差每秒涨 1 秒，纠偏写入会从每 2 秒变成每 1.5 秒。
            //
            // 卡住（缓冲）那几秒要归零：`isPlaying` 这时仍然是 true
            // （`MPVPlayerContainer` 里「没暂停却没走，意图还在就算在播」，界面靠
            // `isStalled` 转圈），不归零的话系统照倍速自己往前推，恢复后要等一次
            // 1.5 秒纠偏才拉回来，卡片上就是「跑快了再跳回去」（LP 4925 第 2 条）。
            // `isPlaying` 不动：它一 false，`playbackState` 跟着变 paused，
            // 卡片上那颗按钮也变了 —— 那不是我们要的。
            rate: surface.isStalled ? 0 : Double(surface.desiredRate),
            // 队列长度（LP 5038）：系统靠「第几项 / 一共几项」把锁屏那两颗箭头
            // 当队列操作处理（main 经 audio_service 一直带着这个值）。
            episodeCount: controller.episodes.count
        )
    }

    /// 控制中心那几颗键接到画面上。只接一次；重复接会叠起来。
    private func configureNowPlayingCommands() {
        let center = NowPlayingCenter.shared
        let surface = self.surface
        center.onPlay = { [surface] in surface.play() }
        center.onPause = { [surface] in surface.pause() }
        center.onSeek = { [surface] position in
            surface.pendingResumeTime = nil
            surface.seek(to: position)
        }
        // 上一集 / 下一集**不在这里接**（LP 5033 / 5042）。
        //
        // 这个方法跑在 `.task` 里，启动那一瞬 `controller` 还是 nil（`bootstrapPlaybackIfNeeded`
        // 之后才创建）。`[weak controller]` 抓到的是「当时这个值」——nil，而且永远是 nil：
        // 真机日志里就是「遥控：收到下一集」紧接着「遥控：下一集拿不到播放控制器/集列表」，
        // 点几次都是这两行。播放/暂停那几颗用的是 `surface`，它从页面一出生就在，所以它们好使。
        // 接在 `controller = created` 之后（`bindEpisodeRemoteCommands`）。
        // 盒子接好就把指令注册上（Fuck 4881）：注册原来只在 `update()` 里发生，
        // 而 `update()` 被 `syncNowPlaying()` 的 `duration > 0 || isPlaying` 挡着——
        // 播放页刚打开、还没起播那一段，那几颗键是没注册的。
        center.configureRemoteCommands()
    }

    /// 上一集 / 下一集：**必须在 `controller` 创建之后接**（LP 5042）。
    /// 那时候 `created` 是个实打实的强引用，弱捕获才拿得到东西。
    private func bindEpisodeRemoteCommands(_ controller: PlayerController) {
        let center = NowPlayingCenter.shared
        let surface = self.surface
        center.onNext = { [weak controller, surface] in
            guard let controller else {
                KazumiLogBuffer.player("遥控：下一集播放控制器已经没了")
                return
            }
            guard !controller.episodes.isEmpty else {
                KazumiLogBuffer.player("遥控：下一集集列表还是空的")
                return
            }
            guard controller.currentEpisode < controller.episodes.count else {
                KazumiLogBuffer.player("遥控：已经是最后一集（\(controller.currentEpisode)/\(controller.episodes.count)）")
                return
            }
            KazumiLogBuffer.player("遥控：切到第 \(controller.currentEpisode + 1) 集")
            surface.prepareForNewEpisode()
            let target = controller.currentEpisode + 1
            Task { await controller.selectEpisode(target) }
        }
        center.onPrevious = { [weak controller, surface] in
            guard let controller else {
                KazumiLogBuffer.player("遥控：上一集播放控制器已经没了")
                return
            }
            guard !controller.episodes.isEmpty else {
                KazumiLogBuffer.player("遥控：上一集集列表还是空的")
                return
            }
            guard controller.currentEpisode > 1 else {
                KazumiLogBuffer.player("遥控：已经是第一集")
                return
            }
            KazumiLogBuffer.player("遥控：切回第 \(controller.currentEpisode - 1) 集")
            surface.prepareForNewEpisode()
            let target = controller.currentEpisode - 1
            Task { await controller.selectEpisode(target) }
        }
    }

    // MARK: - 上一集 / 下一集

    private func previousEpisode() {
        guard let controller else { return }
        // 章节还没抓回来时不报「已经是第一集」，否则正常加载会被误报成边界。
        guard !controller.episodes.isEmpty else { return }
        guard controller.currentEpisode > 1 else {
            surface.toastMessage = String(localized: "已经是第一集")
            return
        }
        persistProgress(controller)
        surface.prepareForNewEpisode()
        let target = controller.currentEpisode - 1
        Task { await controller.selectEpisode(target) }
    }

    private func nextEpisode() {
        guard let controller else { return }
        guard !controller.episodes.isEmpty else { return }
        guard controller.currentEpisode < controller.episodes.count else {
            surface.toastMessage = "已经是最新一集"
            return
        }
        persistProgress(controller)
        surface.prepareForNewEpisode()
        let target = controller.currentEpisode + 1
        Task { await controller.selectEpisode(target) }
    }

    // MARK: - 提示

    /// 竖滑浮层：亮度仍是小胶囊（`sun.max` + 系统玻璃）；
    /// 音量交给系统的 `MPVolumeView`，不再自绘第二条滑杆。
    @ViewBuilder
    /// 把一朵 HUD 摆在画面高度 1/4 的位置（水平居中）。
    /// 加载符号该不该出现。
    ///
    /// 三件事都算「在加载」：起播还没真正开始、中途卡住（网卡缓冲）、正在 seek。
    ///
    /// 判据只看引擎推过来的相位（`isLoadingFirstFrame`）：打开中、等首帧才转，
    /// 到「在播」就收，播完 / 暂停 / 拖进度各按自己的标志走（Fuck 4816 提的那两种）。
    /// 唯一的例外是「有画面但暂停着」：那时画面已经在了，不该用圈盖住它。
    private var showsLoadingHUD: Bool {
        // 缓冲 / 拖进度：短暂提示，跟首帧那套逻辑分开（LP 4818 第 7 条）。
        if surface.isSeeking || surface.isStalled { return true }
        return surface.isLoadingFirstFrame
    }

    /// 加载符号的**圆心**钉在画面正中那条线上——跟两侧快进快退同一水平，
    /// 加载信息与网速顺着往下排（LP 4913）。
    ///
    /// 钉的是圆心不是整块的中心：下面多一行 / 少一行字时，圈本身一动不动
    /// （LP 4870 说的「跳了一下」）。
    private func loadingAtCenterLine<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        let resolved = content()
        return GeometryReader { proxy in
            resolved
                .frame(maxWidth: .infinity)
                .padding(.top, proxy.size.height / 2 - PlayerLoadingHUD.circleHeight / 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .allowsHitTesting(false)
    }

    private func hudAtQuarter<Content: View>(
        interactive: Bool = false,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        // 先把内容求出来再交给 GeometryReader：直接在里面调 content()
        // 会被当成逃逸闭包捕获，编译报 escaping closure captures non-escaping parameter。
        let resolved = content()
        return GeometryReader { proxy in
            resolved
                .position(x: proxy.size.width / 2, y: proxy.size.height / 4)
        }
        // 纯提示的 HUD 不吃点击；错误提示里有「重新加载」那颗钮，要能点。
        .allowsHitTesting(interactive)
    }

    /// 亮度 / 音量的竖滑指示（Colo 2026-10-28）：两者同一个组件、同一位置、同一尺寸，
    /// 只有符号不同——横向圆头轨道宽 120、高 8，填充白色、其余 30%，
    /// 符号与当前值 13 号白字在同一行横排。
    private func gestureOverlay(_ hud: GestureHUDValue) -> some View {
        let value = max(0, min(1, hud.value))
        return HStack(spacing: 8) {
            Image(systemName: hud.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(hud.symbolColor)
                .contentTransition(.symbolEffect(.replace))

            // 轨道：底是 30% 白，填充是纯白，从左往右长。
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.3))
                Capsule()
                    .fill(.white)
                    .frame(width: max(6, 120 * value))
            }
            // 横向胶囊：宽 120、高 8。
            .frame(width: 120, height: 8)

            Text("\(Int((value * 100).rounded()))")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // HUD 胶囊吃系统玻璃底，亮画面上也读得清。
        .playerGlass(in: Capsule(style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 8, y: 2)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    /// 横滑 / 两侧跳转的进度：横滑显示目标时间与偏移，双击只显示偏移。
    private func seekOverlay(_ seconds: Int, target: Double?) -> some View {
        HStack(spacing: 8) {
            if let target {
                Text(timeText(target))
                    .font(.system(size: 17, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                Text(seconds > 0 ? "+\(seconds)s" : "\(seconds)s")
                    .font(.system(size: 13, weight: .regular).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                Text(seconds > 0 ? "+\(seconds)s" : "\(seconds)s")
                    .font(.system(size: 17, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .playerGlass(in: Capsule(style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transition(.opacity)
    }

    /// 双击中间那朵播放 / 暂停：小符号 + 「播放」/「暂停」，跟倍速、收藏、定时关闭
    /// 那些动作结果摆同一条线（LP 4687）。
    private func playPauseBubble(_ symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
            // 文字跟着「刚做了什么」走，符号不动（LP 2026-10-29 4800/4802：
            // 三角那颗写「暂停」，两条竖线那颗写「播放」）。
            Text(symbol == "play.fill" ? "暂停" : "播放")
                .font(.footnote.weight(.medium))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    /// 双击两侧：闪一下秒数。
    private func flashSeekHUD(_ seconds: Int) {
        withAnimation(.easeOut(duration: 0.2)) {
            gestureHUD = nil
            playPauseHUD = nil
            seekHUD = seconds
        }
        scheduleHUDHide(after: 1.2)
    }

    /// 双击中间：把刚切过去的状态画出来。暂停着就一直留着，播起来才淡出。
    /// 符号跟左下角那颗按钮读同一个状态：在播画 pause.fill、暂停画 play.fill，
    /// 两处不一致就是这里写反了（LP 2174）。
    ///
    /// 符号不动，文字翻过来（LP 2026-10-29 4800/4802）：三角那颗配「暂停」、
    /// 两条竖线那颗配「播放」。
    private func flashPlayPauseHUD() {
        withAnimation(.easeOut(duration: 0.2)) {
            gestureHUD = nil
            seekHUD = nil
            playPauseHUD = surface.isPlaying ? "pause.fill" : "play.fill"
        }
        scheduleHUDHide()
    }

    /// 音量浮层**只有这一条路径**：手势竖滑和音量键都走这里，画的都是 `gestureOverlay`
    /// 同一条横条、同一个位置、同一份玻璃（LP 2026-11-06）。
    private func showVolumeHUD(_ value: Double) {
        gestureHUD = GestureHUDValue(kind: .volume, value: max(0, min(1, value)))
    }

    /// 音量键只当触发器：值直接读回调里这个会话的当前音量（按键已经把它写进去了），
    /// 画出跟手势一模一样的那条。自己写音量引起的回声不算按键。
    private func observeSystemVolume() {
        volumeObserver?.invalidate()
        volumeObserver = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { session, _ in
            Task { @MainActor in
                guard !PlayerVolumeControl.shared.isWriting else { return }
                showVolumeHUD(Double(session.outputVolume))
                scheduleHUDHide()
            }
        }
    }

    /// 手指离开后淡出（默认 0.6 秒），0.2 秒 easeOut；三朵浮层共用这一个定时器。
    private func scheduleHUDHide(after seconds: Double = 0.6) {
        hudHideTask?.cancel()
        hudHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            let keepsPausedIndicator = playPauseHUD != nil && !surface.isPlaying
            withAnimation(.easeOut(duration: 0.2)) {
                gestureHUD = nil
                seekHUD = nil
                if !keepsPausedIndicator { playPauseHUD = nil }
            }
        }
    }

    /// 长按加速的浮层：顶部正中一颗胶囊，写当前倍数。
    private var temporarySpeedCapsule: some View {
        Text(PlaybackSpeed.label(Double(surface.desiredRate)))
            .font(.footnote.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minWidth: 48, minHeight: 24)
            .playerGlass(in: Capsule(style: .continuous))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// 提示挂在哪：顶部那条是说明性的话，画面 1/4 那条是动作结果（LP 4668）。
    private enum ToastSlot {
        case top
        case hud
    }

    /// 提示气泡本身：顶部那条和 HUD 那条线共用，只是位置不同。
    private func toastBubble(_ message: String) -> some View {
        Text(message)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
    }

    /// 2 秒后自己收；task 以文案为 id，快速连点时上一条定时器自然作废。
    private func hideToast(_ message: String, slot: ToastSlot) async {
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }
        switch slot {
        case .top:
            if surface.toastMessage == message { surface.toastMessage = nil }
        case .hud:
            if surface.hudToastMessage == message { surface.hudToastMessage = nil }
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let message = surface.toastMessage {
            toastBubble(message)
                .padding(.top, 8)
                .task(id: message) { await hideToast(message, slot: .top) }
        }
    }

    /// 「跳过秒数」弹框：对应原版 player_item_panel 的 _showForwardChange。
    @ViewBuilder
    private var skipSecondsDialog: some View {
        if isEditingSkipSeconds {
            ZStack {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture { dismissSkipSecondsDialog() }
                VStack(spacing: 14) {
                    Text("跳过秒数")
                        .font(.headline)
                    HStack(spacing: 8) {
                        TextField("秒", text: $skipSecondsInput)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                        Text("秒")
                            .foregroundStyle(.secondary)
                    }
                    if let error = skipSecondsError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 12) {
                        Button("取消") { dismissSkipSecondsDialog() }
                            .buttonStyle(.bordered)
                        Spacer(minLength: 0)
                        Button("确定") { commitSkipSeconds() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(20)
                .frame(maxWidth: 320)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.regularMaterial)
                )
                .padding(40)
            }
            .transition(.opacity)
        }
    }

    private func presentSkipSecondsDialog() {
        skipSecondsInput = "\(settings.buttonSkipTime)"
        skipSecondsError = nil
        withAnimation(.easeOut(duration: 0.15)) {
            isEditingSkipSeconds = true
        }
    }

    private func dismissSkipSecondsDialog() {
        withAnimation(.easeOut(duration: 0.15)) {
            isEditingSkipSeconds = false
        }
    }

    private func commitSkipSeconds() {
        let text = skipSecondsInput.trimmingCharacters(in: .whitespaces)
        guard let value = Int(text) else {
            skipSecondsError = String(localized: "请输入数字")
            return
        }
        guard value > 0 else {
            skipSecondsError = String(localized: "请输入大于0的数字")
            return
        }
        settings.buttonSkipTime = value
        dismissSkipSecondsDialog()
    }

    // MARK: - 选集与评论

    /// 画面下面这一片：上面两个页（选集 / 评论），下面是对应内容。
    /// 对应原版 video_page 的「选集 / 评论」两页。
    private func episodeArea(_ controller: PlayerController) -> some View {
        VStack(spacing: 0) {
            Picker("", selection: $detailTab) {
                ForEach(PlayerDetailTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .onChange(of: detailTab) { _, tab in
                if tab == .comments {
                    ensureDefaultCommentEpisode(controller)
                    loadCommentsIfNeeded()
                }
            }
            .onChange(of: isCommentsAscending) { _, _ in applyCommentsSort() }

            switch detailTab {
            case .episodes:
                episodesPane(controller)
            case .comments:
                commentsPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    /// 剧集没能加载时，这句话和「重试」就放在平时列剧集的位置（LP 3286 / Colo 3287）。
    /// 「返回选源」先留着：用户还能退回去挑别的来源。
    private func episodeFailure(_ message: String, controller: PlayerController) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            HStack(spacing: 10) {
                Button("重试") {
                    Task { await controller.retry() }
                }
                .buttonStyle(.borderedProminent)

                Button("返回选源") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 播放器整页被压成系统黑白，但失败页这两颗钮属于页面内容、不是播放区控制，
        // 要跟站点/详情页同一套主题色（LP 2026-10-29）。显式取色而不是 `.accentColor`，
        // 深色下才不偏（@design 4415）。
        .tint(KazumiPalette.accent(for: colorScheme))
    }

    @ViewBuilder
    private func episodesPane(
        _ controller: PlayerController,
        centersCurrentEpisode: Bool = false
    ) -> some View {
        let total = controller.episodes.count
        let pageSize = 100
        let pages = max(1, (total + pageSize - 1) / pageSize)
        let currentPage = min(episodeGridPage, max(0, pages - 1))
        let lo = currentPage * pageSize
        let hi = min(total, lo + pageSize)
        let pageSelection = SystemMenuButton.Selection(options: (0 ..< pages).map { page in
            let a = page * pageSize + 1
            let b = min(total, (page + 1) * pageSize)
            return SystemMenuButton.Selection.Option(
                title: String(localized: "\(String(describing: a))–\(String(describing: b)) 集"),
                isSelected: episodeGridPage == page
            ) {
                episodeGridPage = page
            }
        })
        let pageTitle = String(localized: "\(String(describing: lo + 1))–\(String(describing: hi)) 集")
        let pageAccessibilityLabel = String(
            localized: "快速跳转，现在显示第 \(String(describing: lo + 1)) 到 \(String(describing: hi)) 集"
        )

        VStack(spacing: 0) {
            // 线路选择器只在 2 条以上线路时才画，季选择器只在 2 季以上时才画，
            // 顶行：线路 / 页码在左，下载入口在最右。
            // 从前这两个都没有就整行不画；现在只要有集数就画，不然单线路的番
            // 就没有下载入口（Colo 5090）。
            if total > 0 || controller.roads.count > 1 || pages > 1 {
                HStack(spacing: 8) {
                    // 线路菜单：两条以上线路当然要给；只有一条但**没拿到线路名**时也给，
                    // 左边不能空着——顶行现在右边固定有下载按钮，空着看起来就是缺了块
                    // （LP 5127）。只有一条且有名字的番才不画（Colo 3371 的口径）。
                    if controller.roads.count > 1 || Self.selectedRoadHasNoName(controller) {
                        roadMenu(controller)
                            .onChange(of: controller.selectedRoad) {
                                // 换线路集数就换了对象，留着勾会下错集（LP 5100 之后的口径）。
                                downloadSelection.removeAll()
                            }
                    }
                    // 页码菜单在选择态里收起：顶行这时候要给三颗按钮腾位置（Colo 5090）。
                    if pages > 1 && !isChoosingDownloads {
                        Group {
                            if isFullscreen {
                                SystemMenuButton(
                                    selection: pageSelection,
                                    title: pageTitle,
                                    symbol: "",
                                    accessibilityLabel: pageAccessibilityLabel,
                                    tint: .accentColor,
                                    showsChevron: true,
                                    menuTint: .accentColor,
                                    capsule: true
                                )
                            } else {
                                SwiftSelectionMenuButton(
                                    selection: pageSelection,
                                    title: pageTitle,
                                    accessibilityLabel: pageAccessibilityLabel
                                )
                            }
                        }
                        .frame(height: 44)
                    }
                    Spacer(minLength: 0)
                    if isChoosingDownloads {
                        downloadSelectionActions(controller)
                    } else if total > 0 {
                        downloadEntryButton(controller)
                    }
                }
                .padding(.leading, 16)
                // 右边跟下面集数网格的 20 对齐（网格那侧多 4 是给屏幕圆角/刘
                // 海的，顶行下载按钮原来用 16，右边比集数差一格（LP 7391）。
                .padding(.trailing, 20)
                .frame(height: 44)
            }

            // 在线列表没抓到、只剩本地这份时，顶部说一句（Colo v3 第 9 条）。
            if controller.isOfflineEpisodeList {
                Text("在线列表没加载出来，只显示已下载的")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if case .failed(let message) = controller.phase {
                episodeFailure(message, controller: controller)
            } else if total == 0 {
                Text("暂无选集")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 64), spacing: 8)],
                            spacing: 8
                        ) {
                            ForEach(lo ..< hi, id: \.self) { index in
                                Button {
                                    let number = index + 1
                                    if isChoosingDownloads {
                                        // 选择态：点一下是勾选，不是切集。已下载 / 已加进下载的点不动。
                                        let lite = environment.downloads.liteStatus(
                                            recordKey: downloadRecordKey(controller),
                                            number: number
                                        )
                                        guard lite != .downloaded && !lite.isDownloading else { return }
                                        if downloadSelection.contains(number) {
                                            downloadSelection.remove(number)
                                        } else {
                                            downloadSelection.insert(number)
                                        }
                                    } else {
                                        // 没下载的那几集没有地址，点了只会报错，直接不动。
                                        if controller.isOfflineEpisodeList,
                                           !(controller.episodes.indices.contains(index) && !controller.episodes[index].isEmpty) {
                                            return
                                        }
                                        switchEpisode(to: number, controller: controller)
                                    }
                                } label: {
                                    episodeGridCell(controller, index: index)
                                }
                                .buttonStyle(PlayerPressStyle())
                                .id(index)
                            }
                        }
                        // 右边多留 4（Colo）：横屏这个窗口贴着屏幕右缘，
                        // 屏幕圆角和刘海那侧会吃掉最后一列，右边 20、左边 16。
                        .padding(.leading, 16)
                        .padding(.trailing, 20)
                        .padding(.vertical, 10)
                    }
                    .onAppear {
                        // 右侧面板打开时把在播那集滚到中间（LP 3640）。
                        // 等一帧再滚：LazyVGrid 那一刻还没把那一格建出来。
                        guard centersCurrentEpisode, total > 0 else { return }
                        let target = max(0, min(total - 1, controller.currentEpisode - 1))
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(80))
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
                }
            }
        }
        // 铺满并靠左：VStack 默认把没铺满的子视图摆到中间，线路按钮那一行
        // 就会被摆到屏幕中间（LP 3389 / Colo 3390）。
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            // 进来就把当前集那一块翻出来，不用用户再去找
            if total > 0 {
                let page = max(0, (controller.currentEpisode - 1) / pageSize)
                episodeGridPage = page
            }
        }
    }

    /// 网格里一格：当前集用主题色底与白字，其余白底。
    private func episodeGridCell(_ controller: PlayerController, index: Int) -> some View {
        let number = index + 1
        let isCurrent = number == controller.currentEpisode
        // 选择态里正在播改成描边，不然跟「已选」分不清（Colo 5090）。
        let isSelected = isChoosingDownloads && downloadSelection.contains(number)
        let lite = environment.downloads.liteStatus(recordKey: downloadRecordKey(controller), number: number)
        // 已下载 / 已加进下载的格子在选择态里点不动（不重复选），颜色不变浅。
        let locked = lite == .downloaded || lite == .queued || lite.isDownloading
        // 在线列表没抓到、退回下载记录时，没下好的集是空格子（Colo v3 第 9 条）。
        let missing = controller.isOfflineEpisodeList
            && !(controller.episodes.indices.contains(index) && !controller.episodes[index].isEmpty)
        let solid = isCurrent && !isChoosingDownloads ? true : isSelected

        return Text("\(number)")
            .font(.subheadline.monospacedDigit().weight(solid || (isCurrent && isChoosingDownloads) ? .semibold : .regular))
            .foregroundStyle(cellForeground(solid: solid, isCurrent: isCurrent, lite: lite))
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(solid ? Color.accentColor : Color(.secondarySystemBackground))
            )
            .overlay(alignment: .topTrailing) {
                // 已下载一颗下箭头、下载中一颗虚线下箭头、排队中一颗钟（Colo 5090 / LP 5187）。
                // 失败不再在格子上常驻：LP 5115 说那不该一直挂着，改成渲一句提示（见 failureNotice）。
                // LP 5187：符号颜色跟集数字一致，字号再大一级。
                let markColor = cellForeground(solid: solid, isCurrent: isCurrent, lite: lite)
                switch lite {
                case .downloaded:
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(markColor)
                        .padding(4)
                case .downloading:
                    Image(systemName: "arrow.down.circle.dotted")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(markColor)
                        .padding(4)
                case .queued:
                    Image(systemName: "clock")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(markColor)
                        .padding(4)
                case .failed:
                    // LP 5194：下载失败给一颗感叹号。
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(markColor)
                        .padding(4)
                default:
                    EmptyView()
                }
            }
            .overlay {
                // 真的在下才给进度，排队中只有钟（Colo 5090 特意分开的两条）。
                // 进度贴着格子自己的圆角绕一圈（LP 5481）：原来那条直条压在圆角底边上，
                // 两头戳出弧线以外，跟胶囊的 R 对不上。
                if case .downloading(let progress) = lite {
                    let fraction = max(0.02, min(1, progress))
                    // 从左边正中起画、顺着边框顺时针走（LP 5499）；颜色跟格子里的数字同一个，
                    // 不用主题色——主题色在这块底上会跟集数打架。
                    let ringColor = cellForeground(solid: solid, isCurrent: isCurrent, lite: lite)
                    EdgeProgressRing(fraction: fraction, cornerRadius: 10)
                        .stroke(
                            ringColor,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                        )
                        .padding(1)
                        .animation(.easeOut(duration: 0.25), value: fraction)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(cellStroke(solid: solid, isCurrent: isCurrent), lineWidth: isCurrent && isChoosingDownloads ? 1.5 : 0.5)
            )
            // 已下载 / 排队中的格子不让点，但颜色不变浅（LP 5187）。
            .opacity(missing ? 0.45 : 1)
            .contentShape(Rectangle())
    }

    /// 格子里的数字颜色：实心时白字，其余跟着系统。
    /// LP 5187：已下载不再变浅，数字跟普通集一个色。
    private func cellForeground(
        solid: Bool,
        isCurrent: Bool,
        lite: DownloadLiteStatus
    ) -> Color {
        if solid { return .white }
        if isCurrent { return Color.accentColor }
        return .primary
    }

    /// 描边：实心时不描；选择态里正在播描主题色，其余跟系统分隔线。
    private func cellStroke(solid: Bool, isCurrent: Bool) -> Color {
        if solid { return .clear }
        if isCurrent && isChoosingDownloads { return Color.accentColor }
        return Color(.separator)
    }

    // MARK: - 下载（LP 5084 / Colo 5090）

    /// 面板顶行最右端的下载入口：32 高的胶囊，点击区域给到 44。
    private func downloadEntryButton(_ controller: PlayerController) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) {
                isChoosingDownloads = true
                downloadSelection.removeAll()
            }
        } label: {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 32)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
                // 胶囊只有 32 高，但手指该点得中 44（Colo 5090）。
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlayerPressStyle())
        .accessibilityLabel("下载剧集")
    }

    /// 选择态的三颗按钮：取消 / 全选（取消全选）/ 下载 N 集。
    /// 线路菜单还在左边，这里不占它的位置（LP 5100）。
    private func downloadSelectionActions(_ controller: PlayerController) -> some View {
        let recordKey = downloadRecordKey(controller)
        let downloaded = environment.downloads.downloadedNumbers(recordKey: recordKey)
        let selectable = max(0, controller.episodes.count - downloaded.count)
        let allSelected = selectable > 0 && downloadSelection.count >= selectable

        return HStack(spacing: 4) {
            Button("取消") {
                withAnimation(.easeOut(duration: 0.18)) {
                    isChoosingDownloads = false
                    downloadSelection.removeAll()
                }
            }
            .buttonStyle(PlayerPressStyle())
            .font(.system(size: 14))
            .foregroundStyle(.primary)
            .frame(height: 44)

            Button(allSelected ? "取消全选" : "全选") {
                // 两个词都占位，按钮不跳（Colo 5090）。
                if allSelected {
                    downloadSelection.removeAll()
                } else {
                    downloadSelection = Set(1 ... max(1, controller.episodes.count))
                        .subtracting(downloaded)
                }
            }
            .buttonStyle(PlayerPressStyle())
            .font(.system(size: 14))
            .foregroundStyle(Color.accentColor)
            .frame(minWidth: 56, minHeight: 44)
            .disabled(selectable == 0)

            Button {
                startSelectedDownloads(controller)
            } label: {
                Text(downloadSelection.isEmpty ? "下载" : String(localized: "下载 \(String(describing: downloadSelection.count)) 集"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.accentColor)
                    )
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlayerPressStyle())
            .disabled(downloadSelection.isEmpty)
            .opacity(downloadSelection.isEmpty ? 0.4 : 1)
            .accessibilityLabel(String(localized: "下载选中的 \(String(describing: downloadSelection.count)) 集"))
        }
    }

    /// 这份记录的身份：同一部番 + 同一条规则 + 同一条线路一份。
    private func downloadRecordKey(_ controller: PlayerController) -> String {
        DownloadRecord.key(
            bangumiID: controller.bangumiID,
            pluginName: controller.source?.pluginName ?? "",
            road: controller.selectedRoad
        )
    }

    /// 把勾中的集数交给下载中心。
    private func startSelectedDownloads(_ controller: PlayerController) {
        let roadIndex = controller.selectedRoad
        guard controller.roads.indices.contains(roadIndex) else { return }
        let pages = controller.roads[roadIndex].data
        let items: [(number: Int, title: String, pageURL: String)] = downloadSelection.sorted().compactMap { number in
            let index = number - 1
            guard pages.indices.contains(index) else { return nil }
            let title = controller.episodes.indices.contains(index) ? controller.episodes[index] : ""
            return (number, title, pages[index])
        }
        guard !items.isEmpty else { return }

        environment.downloads.enqueue(
            bangumiID: controller.bangumiID,
            title: controller.source?.itemName ?? "",
            coverURL: "",
            pluginName: controller.source?.pluginName ?? "",
            road: roadIndex,
            // 条目身份一起存：回放时它才是接口模式要的 vod_id（LP 5508/5512）。
            itemSource: controller.source?.detailURL ?? "",
            episodes: items
        )
        withAnimation(.easeOut(duration: 0.18)) {
            isChoosingDownloads = false
            downloadSelection.removeAll()
        }
    }

    /// 评论页：默认当集（无整部番），条数居中只读；左右两颗都是 44 高的按钮。
    @ViewBuilder
    private var commentsPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // 左：当前集（默认当集，不再提供「整部番」）。
                SwiftSelectionMenuButton(
                    selection: commentEpisodeSelection(),
                    title: commentEpisode.map { String(localized: "第 \(String(describing: $0)) 集") } ?? String(localized: "第 — 集"),
                    accessibilityLabel: commentEpisode.map { String(localized: "当前查看第 \(String(describing: $0)) 集评论") } ?? String(localized: "当前查看集数评论")
                )
                .frame(height: 44)
                Spacer(minLength: 8)
                // 中：只读条数文案
                Text(commentTotal == 0 ? "还没有人评论" : String(localized: "共 \(String(describing: commentTotal)) 条评论"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Spacer(minLength: 8)
                // 右：排序（按钮上直接写当前排序方式） + 刷新
                SwiftSelectionMenuButton(
                    selection: .init(options: [
                        SystemMenuButton.Selection.Option(
                            title: String(localized: "最新优先"),
                            isSelected: !isCommentsAscending
                        ) {
                            if isCommentsAscending { isCommentsAscending = false }
                            applyCommentsSort()
                        },
                        SystemMenuButton.Selection.Option(
                            title: String(localized: "最早优先"),
                            isSelected: isCommentsAscending
                        ) {
                            if !isCommentsAscending { isCommentsAscending = true }
                            applyCommentsSort()
                        },
                    ]),
                    title: isCommentsAscending ? "最早优先" : "最新优先",
                    accessibilityLabel: String(localized: "评论排序")
                )
                .frame(height: 44)
                Button {
                    Task { await reloadComments() }
                } label: {
                    // 跟下载入口那颗同一种钮：图标钮、主题色、灰胶囊（LP 5441）。
                    // 同一行里一颗有底一颗没底，看着就是没做完。
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 44, height: 32)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color(.secondarySystemBackground))
                        )
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(isLoadingComments)
                .accessibilityLabel("刷新评论")
            }
            .padding(.horizontal, 16)
            .frame(height: 44)

            if isLoadingComments && comments.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在加载评论…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if comments.isEmpty {
                if commentLoadFailed {
                    VStack(spacing: 10) {
                        Text("评论暂时未能加载")
                            .font(.subheadline.weight(.medium))
                        Text("请检查网络后重试，或换一集看看。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        Button("重新加载") { Task { await reloadComments() } }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("还没有人评论")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                // 用 ScrollView 不用 List：展开回复时要喊列表滚一滚（Colo 3366），
                // List 不给滚。分隔线照原来 List 的留法，从左缩 16。
                ScrollViewReader { proxy in
                    ScrollView {
                        // 必须写 alignment: .leading：LazyVStack 默认居中，整条评论（连头像）
                        // 会被摆到屏幕中间（LP 3389 / Colo 3390）。
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(comments) { comment in
                                CommentRowView(
                                    comment: comment,
                                    score: comment.rate > 0 ? comment.rate : nil,
                                    onExpand: { proxy.scrollTo(comment.id, anchor: .center) }
                                )
                                // 行自己也要铺满：不然行宽只到内容那么宽，还是会被居中。
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                                .id(comment.id)

                                Divider().padding(.leading, 16)
                            }
                            if commentTotal > comments.count {
                                Text(String(localized: "已显示 \(String(describing: comments.count)) / \(String(describing: commentTotal)) 条评论"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 10)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
        }
        // 跟选集那块一样：铺满并靠左，头部那行才不会整体被摆到中间。
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 评论页左上那颗菜单的选项：每一集一条，当前这集由系统打勾。
    private func commentEpisodeSelection() -> SystemMenuButton.Selection {
        let total = controller?.episodes.count ?? 0
        guard total > 0 else { return .init(options: []) }
        return .init(options: (1 ... total).map { ep in
            .init(title: String(localized: "第 \(String(describing: ep)) 集"), isSelected: commentEpisode == ep) {
                switchCommentEpisode(ep)
            }
        })
    }

    /// 进评论页才拉，拉过就不重复拉；切集或刷新时也走 load。
    private func defaultCommentEpisode(_ controller: PlayerController) -> Int? {
        let ep = controller.currentEpisode
        guard controller.episodes.indices.contains(ep - 1) else { return nil }
        return ep
    }

    private func ensureDefaultCommentEpisode(_ controller: PlayerController) {
        // 只在「还没定过集」时默认到当集；用户切过就不再覆盖
        if commentEpisode == nil, let ep = defaultCommentEpisode(controller) {
            commentEpisode = ep
        }
    }

    private func loadCommentsIfNeeded() {
        guard comments.isEmpty, !isLoadingComments else { return }
        Task { await reloadComments() }
    }

    private func reloadComments() async {
        commentRequestGeneration &+= 1
        let generation = commentRequestGeneration
        isLoadingComments = true
        defer {
            if generation == commentRequestGeneration { isLoadingComments = false }
        }
        // 评论区默认只看当集：没定过就按当前集补上，失败才退回上一口径
        if commentEpisode == nil, let c = controller, let ep = defaultCommentEpisode(c) {
            commentEpisode = ep
        }
        let episode = commentEpisode
        let page: BangumiCommentPage
        if let ep = episode, let eid = await BangumiAPI.episodeID(subjectID: bangumiID, episode: ep) {
            guard generation == commentRequestGeneration, episode == commentEpisode else { return }
            page = await BangumiAPI.episodeComments(episodeID: eid)
        } else {
            // 兜底：当集还没解析出来或取不到 episodeID 时，退回整部番（避免空屏）
            guard generation == commentRequestGeneration, episode == commentEpisode else { return }
            page = await BangumiAPI.comments(subjectID: bangumiID)
        }
        guard generation == commentRequestGeneration, episode == commentEpisode else { return }
        var items = page.items
        // 排序：主分支在拿到就排好，这里沿用同一规则（按 updatedAt）
        items.sort { isCommentsAscending ? $0.updatedAt < $1.updatedAt : $0.updatedAt > $1.updatedAt }
        comments = items
        commentTotal = page.total
    }

    private func switchCommentEpisode(_ episode: Int?) {
        commentRequestGeneration &+= 1
        commentEpisode = episode
        comments = []
        commentTotal = 0
        Task { await reloadComments() }
    }

    private func applyCommentsSort() {
        guard !comments.isEmpty else { return }
        comments.sort { isCommentsAscending ? $0.updatedAt < $1.updatedAt : $0.updatedAt > $1.updatedAt }
    }

    /// 一行一集：集号在左，当前集打勾 + 主题色（不做「上次看到」推算）。
    private func episodeRow(_ controller: PlayerController, index: Int) -> some View {
        let number = index + 1
        let isCurrent = number == controller.currentEpisode
        return HStack(spacing: 8) {
            Text(String(localized: "第 \(String(describing: number)) 集"))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
            Spacer(minLength: 8)
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }

    /// 线路：多于一条时才出现，按钮上写当前实际在用的那条线路名。
    @ViewBuilder
    private func roadMenu(_ controller: PlayerController) -> some View {
        let selection = SystemMenuButton.Selection(
            options: controller.roads.enumerated().map { index, road in
                .init(
                    title: Self.roadItemTitle(road),
                    isSelected: index == controller.selectedRoad
                ) {
                    guard index != controller.selectedRoad else { return }
                    // 换线路 = 重新解析这一集，进度按原版先落一次。
                    persistProgress(controller)
                    surface.prepareForNewEpisode()
                    Task { await controller.selectRoad(index) }
                }
            }
        )
        // 不预设「线路 1」：来源给什么名字就显示什么名字（cht／chs 这种照抄），
        // 也不自己编号（LP 3370 / Colo 3371）。
        let title = controller.roads.indices.contains(controller.selectedRoad)
            ? Self.roadName(controller.roads[controller.selectedRoad])
            : String(localized: "线路")
        Group {
            if isFullscreen {
                // 字和箭头取设置里的主题色（LP 7379）：横屏这颗是 UIKit 按钮，
                // 传 .accentColor 经 UIColor 桥接脱离 SwiftUI 环境，解析不出
                // AppRoot 设的主题色；显式取调色板，底色仍是浅灰胶囊不动（Colo 7382）。
                let accent = KazumiPalette.accent(for: colorScheme)
                SystemMenuButton(
                    selection: selection,
                    title: title,
                    symbol: "",
                    accessibilityLabel: String(localized: "选择线路"),
                    tint: accent,
                    showsChevron: true,
                    menuTint: accent,
                    capsule: true
                )
            } else {
                SwiftSelectionMenuButton(
                    selection: selection,
                    title: title,
                    accessibilityLabel: String(localized: "选择线路")
                )
            }
        }
        .frame(height: 44)
    }

    /// 当前这条线路有没有名字：没名字时左边要写「线路」占位（LP 5127）。
    private static func selectedRoadHasNoName(_ controller: PlayerController) -> Bool {
        guard controller.roads.indices.contains(controller.selectedRoad) else { return true }
        return controller.roads[controller.selectedRoad].name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    /// 线路名照抄来源给的；来源没给名字就只写「线路」，不编号。
    private static func roadName(_ road: Road) -> String {
        let name = road.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "线路" : name
    }

    /// 菜单里那一条：线路名 · N 集（集数拿不到就不标，别写 0）。
    private static func roadItemTitle(_ road: Road) -> String {
        let name = roadName(road)
        return road.data.isEmpty ? name : String(localized: "\(String(describing: name)) · \(String(describing: road.data.count)) 集")
    }

    private func switchEpisode(to number: Int, controller: PlayerController) {
        // 点当前集是空操作（原版同样早退）；但上一次加载失败时允许重点重试。
        guard number != controller.currentEpisode || surface.errorMessage != nil else { return }
        persistProgress(controller)
        if commentEpisode != nil { commentEpisode = number }
        surface.prepareForNewEpisode()
        Task { await controller.selectEpisode(number) }
    }
}

/// 把一次播放位置写进观看历史（对应原版 history 记录）。
///
/// 抽成文件内自由函数是为了让 `surface.onFinish` 那个长期存活的开包
/// 也能直接写进度，而不必把整个 View 捕进去。
/// 距离结尾 5 秒以内视为已看完，进度归零保存，下次从头播（对应原版
/// `nearEndWatchedThreshold`）。
@MainActor
private func persistWatchProgress(
    library: LibraryStore,
    privateMode: Bool,
    controller: PlayerController,
    position: Double,
    duration: Double
) {
    // 隐身模式：不写观看记录（LP 清单「隐身模式」，Ato：进历史前判一下）。
    guard !privateMode else { return }
    // 没真播过就不进历史（LP 2026-10-25）：「剧集查询失败」那种一次都没起播的，
    // 位置停在 0、时长也拿不到，写进去就是一条 0 进度的空记录。
    guard position.isFinite, duration.isFinite, duration > 0, position >= 1 else { return }
    var progress = position
    if duration > 0, progress >= duration - 5 {
        progress = 0
    }
    let source = controller.source
    let entry = library.entry(for: controller.bangumiID)
    let storedName = source?.itemName ?? ""
    let storedImage = entry?.imageURL ?? ""
    // 走 store 那一个入口写进度：同一「规则 + 番剧」只留一份记录，
    // 每一集各带自己的线路号（main 的 History.progresses）。
    library.recordWatch(
        bangumiID: controller.bangumiID,
        bangumiName: storedName,
        imageURL: storedImage,
        pluginName: source?.pluginName ?? "",
        episodeNumber: controller.currentEpisode,
        // 原生这边只有 URL，没有集标题，留空由历史页回退成「第 N 话」。
        episodeTitle: "",
        // 下次从详情页「开始观看」时按这条线路接上（main 记线路的原因）。
        road: controller.selectedRoad,
        position: progress,
        duration: duration.isFinite && duration > 0 ? duration : 0
    )

    // 没追过番的条目，名字和封面在上面都是空串，记录就成了空壳。
    // Colo 3554：缺的那几样用番剧 ID 向 Bangumi 取一次、写回同一条记录；
    // 这里补、不在列表里就地补，别处读同一条记录也就都有名字了。
    guard storedName.isEmpty || storedImage.isEmpty else { return }
    let bangumiID = controller.bangumiID
    Task { @MainActor in
        guard let item = await BangumiAPI.info(id: bangumiID) else { return }
        library.backfillHistoryMeta(
            bangumiID: bangumiID,
            name: item.displayName,
            imageURL: item.largeImage
        )
    }
}

/// 画面框：竖屏里按画面比例的宽度占满（16:9 就是屏宽 × 屏宽×9/16），
/// 横屏全屏时铺满窗口。`.fit` 保证不裁画面——原版竖屏同样不裁。
private struct PlayerBoxModifier: ViewModifier {
    var fillsWindow: Bool
    var aspectRatio: CGFloat

    /// 不分叉。
    ///
    /// 这里原来是 `if fillsWindow { … } else { … }`，两种分支是两种视图类型，
    /// SwiftUI 会当成两棵不同的树：切横屏时整块画面被拆掉重建，mpv 跟着
    /// `dismantleUIView` 停引擎，进度从 0 重来（LP 2026-10-27「切横屏又丢失进度」）。
    /// 改成一条修饰符链，只让参数变、结构不变。
    func body(content: Content) -> some View {
        content
            // 全屏时 `aspectRatio` 传的是**容器自己的比例**（`boxAspectRatio`），
            // 不是 nil：传 nil 会退回内容的固有比例（mpv 视图是方的），
            // 于是横屏只铺了 382 宽（LP 2026-10-27）。
            .aspectRatio(aspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: fillsWindow ? .infinity : nil)
    }
}

/// 系统分享面板：把媒体地址交给别的 App（VLC、Infuse 之类）打开。
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - 一起看表单（从 PlayerScreen 抽出，避免 @Bindable 作用域问题）
private struct SyncPlaySheet: View {
    @Bindable var settings: SettingsStore
    @Binding var showingSyncPlay: Bool
    @Bindable var surface: PlayerSurfaceModel

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器") {
                    TextField("wss:// 或 ws://host:port", text: $settings.syncPlayEndPoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                Section("房间") {
                    TextField("房间名", text: $settings.syncPlayRoom)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("口令（可选）", text: $settings.syncPlayPassword)
                }
                Section {
                    Button("创建房间") {
                        showingSyncPlay = false
                        let roomName = settings.syncPlayRoom.isEmpty ? String(localized: "默认房间") : settings.syncPlayRoom
                        surface.toastMessage = String(localized: "一起看：\(roomName)（创建）")
                    }
                    Button("加入房间") {
                        showingSyncPlay = false
                        let roomName = settings.syncPlayRoom.isEmpty ? String(localized: "默认房间") : settings.syncPlayRoom
                        surface.toastMessage = String(localized: "一起看：\(roomName)（加入）")
                    }
                } header: {
                    Text("房间操作")
                } footer: {
                    Text("可填 wss:// 形式的外网房间服务器。播放同步（WS 客户端与心跳）后续接上。")
                }
            }
            .navigationTitle("一起看")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSyncPlay = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(Color.primary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("关闭")
                }
            }
        }
    }
}

/// 播放器里那块玻璃底（LP 3637：横屏选集窗口要用 UIKit 的玻璃）。
/// 用 iOS 26 的 `UIGlassEffect`；这块是浮在视频上的，取 `.regular` 那种，
/// 别用 `.clear`——画面一动，上面的白字就没地方站。
/// 播放页按钮的按压反馈：按下缩到 0.92、松开弹回，100ms easeOut。
/// 不加底色、不变色、不动投影，也不震——iOS 原生按钮本来就不震。
/// 播放器横竖屏共用的弹幕符号：圆角框里两条错落横线代表飞过的弹幕，
/// 右下角压一颗小齿轮（设置版）。不写汉字，简繁体、字号糊不糊都不用管。
/// 外框 18.5×15.5、线宽 1.6，跟 18pt Medium 的 `speedometer` / `sidebar.left`
/// 墨水高度 15~16pt、线宽 1.5~1.7pt 对齐；整张画布仍锁 20×18 装下齿轮。
struct DanmakuSettingsGlyph: View {
    /// 颜色由调用方定：播放器里白色，「更多」菜单渲成模板图后跟系统 tint。
    var color: Color = .white

    var body: some View {
        ZStack {
            // 主体框：可视高 15.5pt、宽 18.5pt，线宽 1.6pt。
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(lineWidth: 1.6)
                .frame(width: 18.5, height: 15.5)
                .overlay {
                    // 两条错落的胶囊横线＝弹幕，免去一切中文字体和简繁问题。
                    VStack(spacing: 2.5) {
                        Capsule()
                            .frame(width: 9, height: 1.6)
                            .offset(x: -1.5)
                        Capsule()
                            .frame(width: 7, height: 1.6)
                            .offset(x: 2)
                    }
                }
                .offset(x: -1, y: -1)
                .overlay(alignment: .bottomTrailing) {
                    // 齿轮位置的镂空避让圆，避免框线和齿轮叠在一起。
                    Circle()
                        .frame(width: 9.5, height: 9.5)
                        .offset(x: 1, y: 1)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()

            // 右下角小齿轮：8pt，精致但不抢主体。
            Image(systemName: "gearshape.fill")
                .font(.system(size: 8, weight: .bold))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .offset(x: 0.5, y: 0.5)
        }
        .foregroundStyle(color)
        // 严格锁死 20×18，绝不撑大外面的按钮。
        .frame(width: 20, height: 18)
        .contentShape(Rectangle())
    }
}

struct PlayerPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// 播放器浮层的玻璃底：iOS 26 用 SwiftUI 原生 `glassEffect`；
/// 低版本退回 `GlassBackdrop`，两边都能编译、观感一致。
/// 一律钉成深色（LP 2026-11-06）：播放器底下永远是画面，不跟系统浅色走。
private struct PlayerGlassShapeModifier<S: Shape>: ViewModifier {
    let shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(true), in: shape)
        } else {
            content.background {
                GlassBackdrop()
                    .clipShape(shape)
            }
        }
    }
}

private extension View {
    /// HUD 胶囊统一走这一个入口，调用点只写形状。
    func playerGlass<S: Shape>(in shape: S) -> some View {
        modifier(PlayerGlassShapeModifier(shape: shape))
    }
}

struct GlassBackdrop: UIViewRepresentable {
    func makeUIView(context: Context) -> UIVisualEffectView {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        let view = UIVisualEffectView(effect: effect)
        view.backgroundColor = .clear
        view.clipsToBounds = true
        view.overrideUserInterfaceStyle = .dark
        return view
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}

/// 转屏被拒时系统给的那句话，从后台队列交回主线程的盒子。
///
/// UIKit 在自己的队列（崩溃报告里是 `com.apple.root.default-qos`）上回调
/// `requestGeometryUpdate` 的 errorHandler。闭包字面量写在 `@MainActor` 的
/// `Task` 里会继承主线程隔离，UIKit 在后台队列上一叫就撞
/// `_swift_task_checkIsolatedSwift` 断言、整页闪退——平时看不出来，只有系统
/// **拒绝**这次转屏（回调真的被调）才死（LP 4753 的崩溃报告，真机一进全屏被拒）。
///
/// 所以回调里一个字都不碰主线程状态，只往这个带锁的盒子里放一句话，
/// 主线程那边轮询时再取出来。
private final class OrientationFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (generation: Int, message: String)?

    func record(generation: Int, message: String) {
        lock.lock()
        defer { lock.unlock() }
        // 旧请求迟到的回调不许盖掉新请求的结论。
        if let stored, stored.generation > generation { return }
        stored = (generation, message)
    }

    /// 取走属于这一代请求的那句话；不是这一代的就当没发生过。
    func take(generation: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let stored, stored.generation == generation else { return nil }
        self.stored = nil
        return stored.message
    }
}


/// 沿着圆角矩形边框走一圈的进度线，起点是左边正中、方向顺时针（LP 5499）。
///
/// 不用 `RoundedRectangle().trim`：`trim` 的起点由路径自己决定（落在上边一带），
/// 换不了，只能自己按段的长度铺。
private struct EdgeProgressRing: Shape {
    /// 0…1，画满整圈的多少。
    var fraction: Double
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        let arc = CGFloat.pi * r / 2
        let straightV = max(0, rect.height - 2 * r) / 2   // 单侧竖直线（上下一半）
        let straightH = max(0, rect.width - 2 * r)        // 单侧水平线
        // 九段都在这里排好：从左边正中往上，绕一圈回到左边正中。
        let lengths: [CGFloat] = [straightV, arc, straightH, arc, 2 * straightV, arc, straightH, arc, straightV]
        let total = lengths.reduce(0, +)
        guard total > 0 else { return Path() }
        var remaining = total * max(0, min(1, fraction))

        let midY = rect.midY
        var cursor = CGPoint(x: rect.minX, y: midY)
        var path = Path()
        path.move(to: cursor)

        for (index, length) in lengths.enumerated() where remaining > 0 {
            let take = min(length, remaining)
            remaining -= take
            switch index {
            case 0: // 左中 → 左上角起点
                cursor.y -= take
                path.addLine(to: cursor)
            case 1: // 左上角
                let center = CGPoint(x: rect.minX + r, y: rect.minY + r)
                path.addArc(center: center, radius: r,
                            startAngle: .radians(.pi),
                            endAngle: .radians(.pi + (take / max(arc, 0.0001)) * (.pi / 2)),
                            clockwise: false)
                cursor = Self.point(center: center, r: r, angle: .pi + (take / max(arc, 0.0001)) * (.pi / 2))
            case 2: // 上边
                cursor.x += take
                path.addLine(to: cursor)
            case 3: // 右上角
                let center = CGPoint(x: rect.maxX - r, y: rect.minY + r)
                path.addArc(center: center, radius: r,
                            startAngle: .radians(.pi * 1.5),
                            endAngle: .radians(.pi * 1.5 + (take / max(arc, 0.0001)) * (.pi / 2)),
                            clockwise: false)
                cursor = Self.point(center: center, r: r, angle: .pi * 1.5 + (take / max(arc, 0.0001)) * (.pi / 2))
            case 4: // 右边
                cursor.y += take
                path.addLine(to: cursor)
            case 5: // 右下角
                let center = CGPoint(x: rect.maxX - r, y: rect.maxY - r)
                path.addArc(center: center, radius: r,
                            startAngle: .radians(0),
                            endAngle: .radians((take / max(arc, 0.0001)) * (.pi / 2)),
                            clockwise: false)
                cursor = Self.point(center: center, r: r, angle: (take / max(arc, 0.0001)) * (.pi / 2))
            case 6: // 下边
                cursor.x -= take
                path.addLine(to: cursor)
            case 7: // 左下角
                let center = CGPoint(x: rect.minX + r, y: rect.maxY - r)
                path.addArc(center: center, radius: r,
                            startAngle: .radians(.pi / 2),
                            endAngle: .radians(.pi / 2 + (take / max(arc, 0.0001)) * (.pi / 2)),
                            clockwise: false)
                cursor = Self.point(center: center, r: r, angle: .pi / 2 + (take / max(arc, 0.0001)) * (.pi / 2))
            default: // 左边 → 回到正中
                cursor.y -= take
                path.addLine(to: cursor)
            }
        }
        return path
    }

    private static func point(center: CGPoint, r: CGFloat, angle: CGFloat) -> CGPoint {
        CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
    }
}

private struct DanmakuSourceSheet: View {
    let initialKeyword: String
    let onSelectEpisode: (DanmakuEpisode) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var keyword: String
    @State private var animes: [DanmakuSearchAnime] = []
    @State private var selectedAnime: DanmakuSearchAnime?
    @State private var episodes: [DanmakuEpisode] = []
    @State private var loading = false
    @State private var errorMessage: String?

    init(
        initialKeyword: String,
        onSelectEpisode: @escaping (DanmakuEpisode) async -> String?
    ) {
        self.initialKeyword = initialKeyword
        self.onSelectEpisode = onSelectEpisode
        _keyword = State(initialValue: initialKeyword)
    }

    var body: some View {
        Group {
            if let selectedAnime {
                episodeContent(selectedAnime)
            } else {
                searchContent
            }
        }
        .navigationTitle(selectedAnime == nil ? "选择弹幕源" : "选择分集")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("关闭") { dismiss() }
            }
        }
        .overlay {
            if loading {
                ProgressView()
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .disabled(loading)
    }

    private var searchContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("番剧名称", text: $keyword)
                    .submitLabel(.search)
                    .onSubmit { Task { await search() } }
                    .textFieldStyle(.roundedBorder)
                Button("搜索") {
                    Task { await search() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()

            if let errorMessage {
                errorLabel(errorMessage)
            }

            List(animes) { anime in
                Button {
                    Task { await loadEpisodes(for: anime) }
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(anime.animeTitle)
                                .foregroundStyle(.primary)
                            if !anime.typeDescription.isEmpty {
                                Text(anime.typeDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }

    private func episodeContent(_ anime: DanmakuSearchAnime) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    selectedAnime = nil
                    episodes = []
                    errorMessage = nil
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回")
                Text(anime.animeTitle)
                    .lineLimit(1)
                Spacer()
            }
            .padding()

            if let errorMessage {
                errorLabel(errorMessage)
            }

            List(episodes) { episode in
                Button {
                    Task { await select(episode) }
                } label: {
                    HStack {
                        Text(episode.episodeTitle)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "captions.bubble")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }

    private func errorLabel(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.bottom, 8)
    }

    private func search() async {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            errorMessage = String(localized: "请输入番剧名称")
            return
        }
        loading = true
        errorMessage = nil
        animes = []
        defer { loading = false }
        do {
            animes = try await DanmakuAPI.searchAnimes(query)
            if animes.isEmpty {
                errorMessage = String(localized: "未找到番剧")
            }
        } catch {
            errorMessage = String(localized: "搜索失败：\(error.localizedDescription)")
        }
    }

    private func loadEpisodes(for anime: DanmakuSearchAnime) async {
        loading = true
        errorMessage = nil
        episodes = []
        defer { loading = false }
        do {
            let result = try await DanmakuAPI.episodes(animeID: anime.animeID)
            selectedAnime = anime
            episodes = result
            if result.isEmpty {
                errorMessage = String(localized: "暂无分集")
            }
        } catch {
            errorMessage = String(localized: "分集加载失败：\(error.localizedDescription)")
        }
    }

    private func select(_ episode: DanmakuEpisode) async {
        loading = true
        errorMessage = nil
        if let failure = await onSelectEpisode(episode) {
            errorMessage = String(localized: "弹幕源切换失败：\(failure)")
            loading = false
        } else {
            dismiss()
        }
    }
}
