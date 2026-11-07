//
//  SettingsStore.swift
//  Kazumi
//
//  设置项的持久化容器（替代 Hive 中的 settings box）。
//  存储实现只依赖 UserDefaults，Step 3 会用同一套 API 把 WebDAV 备份的
//  `settings` 段落写回这里，因此键名刻意与原版保持一致。
//

import CoreFoundation
import Foundation
import Observation
import SwiftUI

/// 主题模式（对照 bean/settings/theme_provider.dart 的 ThemeMode）。
enum KazumiThemeMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "跟随系统")
        case .light: String(localized: "浅色")
        case .dark: String(localized: "深色")
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum HardwareDecodeMode: String, CaseIterable, Identifiable, Sendable {
    case videotoolbox
    case videotoolboxCopy = "videotoolbox-copy"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .videotoolbox: String(localized: "直通")
        case .videotoolboxCopy: String(localized: "非直通")
        }
    }
}

/// 超分辨率档位：关 / 效率 / 质量，三档。
///
/// 数值沿用原版 Anime4K 设置的存储值（1=关闭，2=效率，3=质量），
/// 这样老用户的设置备份还能直接读回来。
///
/// 效果就是给 mpv 挂 Anime4K v4.0.1 的官方 preset：效率档 = Fast 的 Mode A，
/// 质量档 = HQ 的 Mode A，关闭就不挂任何着色器。
enum SuperResolutionMode: Int, CaseIterable, Identifiable, Sendable {
    case off = 1
    case efficiency = 2
    case quality = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: String(localized: "关闭")
        case .efficiency: String(localized: "效率档")
        case .quality: String(localized: "质量档")
        }
    }

    /// 交给 mpv 的 GLSL 着色器文件路径（Anime4K v4.0.1，官方 preset）。
    ///
    /// 两档都取官方 Mode A：效率档用 Fast 那一套（小模型，省电），
    /// 质量档用 HQ 那一套（VL 模型，线条修得更细、更吃 GPU）。
    /// 顺序就是官方的顺序，不要打乱：Clamp 先压高光，Restore 修线条，
    /// Upscale 放大，AutoDownscalePre 在放大后又把超过屏幕的部分缩回去。
    ///
    /// 文件在包里是 folder reference（`shaders/`），所以拼出来的路径是
    /// `shaders/Anime4K_*.glsl`；真机上找不到就返回空数组，等于不超分，
    /// 不至于让 mpv 因为路径错而报错。
    var shaderPaths: [String] {
        guard self != .off else { return [] }
        let names: [String] = self == .quality
            ? [
                "Anime4K_Clamp_Highlights",
                "Anime4K_Restore_CNN_VL",
                "Anime4K_Upscale_CNN_x2_VL",
                "Anime4K_AutoDownscalePre_x2",
                "Anime4K_AutoDownscalePre_x4",
                "Anime4K_Upscale_CNN_x2_M"
            ]
            : [
                "Anime4K_Clamp_Highlights",
                "Anime4K_Restore_CNN_M",
                "Anime4K_Upscale_CNN_x2_M",
                "Anime4K_AutoDownscalePre_x2",
                "Anime4K_AutoDownscalePre_x4",
                "Anime4K_Upscale_CNN_x2_S"
            ]
        return names.compactMap { name in
            Bundle.main.path(forResource: name, ofType: "glsl", inDirectory: "shaders")
                ?? Bundle.main.path(forResource: name, ofType: "glsl")
        }
    }

}

/// 播放倍速档位：0.5 → 3.0 共九档，具体见 `all`。原版 `lib/utils/constants.dart` 的
/// `defaultPlaySpeedList` 是从 0.25 起、每档 0.25 的十二档；这里去掉 0.25，2.0 以上
/// 改成 0.5 的步长。播放器菜单与设置页的「默认倍速」共用这一份，避免两处档位再次走偏。
enum PlaybackSpeed {
    /// 播放器菜单与设置页给的档位：0.5 到 3.0，够用又不至于一长串。
    static let all: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    /// 档位文案：统一两位小数——`0.50x`、`1.25x`、`2.00x`、`3.00x`
    /// （LP 4674：菜单里不要再出现 `2x` / `1.5x` 这种长短不一的写法）。
    /// 菜单、控制栏那颗钮、长按倍速胶囊、设置页都走这一个函数，不会再分叉。
    static func label(_ value: Double) -> String {
        String(format: "%.2fx", value)
    }

    /// 播放器按钮文案：1 倍时写「倍速」，其余写档位（对应原版的按钮用字）。
    static func buttonLabel(_ value: Double) -> String {
        abs(value - 1) < 0.001 ? String(localized: "倍速") : label(value)
    }

    /// 把任意倍速归到最近的档位（越界自然取首 / 末档）。
    /// 旧备份或旧安装里可能写着不在档位表上的值，直接拿来会让设置页的选择项对不上。
    static func nearest(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return all.min { abs($0 - value) < abs($1 - value) } ?? 1
    }
}

/// 设置键。命名沿用原项目 setting keys 的语义，便于备份文件互通。
enum SettingsKey {
    /// 设置键在 UserDefaults 里的统一前缀。
    ///
    /// 放在这个非隔离的枚举里：设置备份扩展与静态工具方法都要在
    /// `SettingsStore`（`@MainActor`）之外读取它，避免 Swift 6
    /// 严格并发下的 actor 隔离报错。
    static let keyPrefix = "kazumi.settings."
    static let themeMode = "themeMode"
    static let colorType = "colorType"
    /// 配色方案标识，沿用原版 `SettingsKeys.themeColor` 的键名。
    static let themeColor = "themeColor"
    /// OLED 纯黑，沿用原版 `SettingsKeys.oledEnhance` 的键名。
    static let oledEnhance = "oledEnhance"
    static let selectedPluginIndex = "selectedPluginIndex"
    static let playerQuality = "playerQuality"
    static let hardwareDecoder = "hardwareDecoder"
    static let anime4kMode = "anime4kMode"
    static let autoPlayNext = "autoPlayNext"
    static let autoSkipOpEd = "autoSkipOpEd"
    static let playSpeed = "playSpeed"
    /// 顶部快进按钮的秒数，沿用原版 `SettingsKeys.buttonSkipTime` 的键名，默认 80。
    static let buttonSkipTime = "buttonSkipTime"
    /// 画面上左右两侧双击快进 / 快退的秒数，默认 15。
    static let doubleTapSkipTime = "doubleTapSkipTime"
    /// 画面长按时的临时倍速（默认 2.0×）。
    static let longPressSpeed = "longPressSpeed"
    /// 默认视频比例（LP 清单「默认视频比例」，默认自动）。
    static let playerAspectRatio = "playerAspectRatio"
    /// 触感反馈总开关（LP 清单「触感反馈」），默认开启。
    static let hapticFeedbackEnabled = "hapticFeedbackEnabled"
    /// 时间表是否显示评分（Ato 2026-10-24：只管时间表，详情页照旧）。
    static let showRating = "showRating"
    /// 时间表星期条是否显示每天番剧数量（LP 5039，默认关）。
    /// 关掉时星期条换成规则编辑页顶部那种分段 tab。
    static let timelineShowCount = "timelineShowCount"
    /// 上滑时缩小底部标签栏（LP 2586 定稿：名字带「缩小」，默认开）。
    static let tabBarShrinkOnScroll = "tabBarShrinkOnScroll"
    /// 进入播放器时跳到上次播放位置，沿用原版 `SettingsKeys.playResume` 的键名，默认开启。
    static let playResume = "playResume"
    /// 后台播放，沿用原版 `SettingsKeys.backgroundPlayback` 的键名，默认关闭。
    static let backgroundPlayback = "backgroundPlayback"
    /// 切后台时自动起画中画（LP 2026-10-29），默认开启。
    static let backgroundAutoPiP = "backgroundAutoPiP"
    /// 回到前台自动接着播（LP 2026-10-29），默认开启。
    static let resumeOnForeground = "resumeOnForeground"
    /// 竖向滑动调节音量和亮度，沿用原版 `SettingsKeys.brightnessVolumeGesture` 的键名，默认开启。
    static let brightnessVolumeGesture = "brightnessVolumeGesture"
    /// 隐身模式（不保留观看记录），沿用原版 `SettingsKeys.privateMode` 的键名，默认关闭。
    static let privateMode = "privateMode"
    /// 低内存模式三档（跟随网络 / 始终开启 / 始终关闭），沿用 main 的 `lowMemoryPolicy`。
    static let lowMemoryPolicy = "lowMemoryPolicy"
    /// 硬件解码开关，与解码模式独立保存。
    static let hardwareDecodeEnabled = "hardwareDecodeEnabled"
    static let hardwareDecodeMode = "hardwareDecodeMode"
    /// AniSkip 片头片尾时间轴，沿用原版 `SettingsKeys.aniSkipLookup` 的键名，默认开启。
    static let aniSkipLookup = "aniSkipLookup"
    /// 控制栏自动隐藏前的停留时长（毫秒），沿用原版
    /// `SettingsKeys.playerControllerLayerDisappearTime` 的键名，默认 4000。
    static let playerControllerLayerDisappearTime = "playerControllerLayerDisappearTime"
    static let danmakuEnabled = "danmakuEnabled"
    static let danmakuOpacity = "danmakuOpacity"
    static let danmakuFontSize = "danmakuFontSize"
    static let danmakuArea = "danmakuArea"
    // 以下键名与 main 的 settings 完全一致（settings_keys.dart 的 danmaku 组），
    // 这样两版的设置备份可以互认。
    /// 滚动弹幕横穿屏幕的秒数，默认 8。
    static let danmakuDuration = "danmakuDuration"
    /// 弹幕行高倍数，默认 1.6。
    static let danmakuLineHeight = "danmakuLineHeight"
    /// 弹幕速度跟随视频倍速，默认开。
    static let danmakuFollowSpeed = "danmakuFollowSpeed"
    /// 顶部弹幕，默认开。
    static let danmakuTop = "danmakuTop"
    /// 底部弹幕，默认关。
    static let danmakuBottom = "danmakuBottom"
    /// 滚动弹幕，默认开。
    static let danmakuScroll = "danmakuScroll"
    /// 海量弹幕（轨满了也不丢，叠着画），默认关。
    static let danmakuMassive = "danmakuMassive"
    /// 弹幕去重（5 秒内相同内容合并成一条），默认关。
    static let danmakuDeduplication = "danmakuDeduplication"
    /// 弹幕描边，默认开。
    static let danmakuBorder = "danmakuBorder"
    /// 描边粗细，默认 1.5（main 的 0.1~3 那档）。
    static let danmakuBorderSize = "danmakuBorderSize"
    /// 弹幕颜色（关掉就一律白字），默认开。
    static let danmakuColor = "danmakuColor"
    /// 字体字重，1~9 对应 w100~w900，main 默认 4。
    static let danmakuFontWeight = "danmakuFontWeight"
    /// 三路来源开关（main 的 danmakuBiliBiliSource / danmakuGamerSource /
    /// danmakuDanDanSource，默认都开）。弹弹play 的弹幕自带来源标记，
    /// 这三颗就是按标记筛。
    static let danmakuBiliBiliSource = "danmakuBiliBiliSource"
    static let danmakuGamerSource = "danmakuGamerSource"
    static let danmakuDanDanSource = "danmakuDanDanSource"
    static let danmakuAPIURL = "danmakuAPIURL"
    static let danmakuAPIRequestHeaders = "danmakuAPIRequestHeaders"
    static let danmakuFilterRules = "danmakuFilterRules"
    static let danmakuSourcePriority = "danmakuSourcePriority"
    /// 设置备份是否跳过账号与密码；只记在本机，不随设置备份迁移。
    static let settingsBackupOmitCredentials = "settingsBackupOmitCredentials"
    static let webDAVURL = "webDAVURL"
    static let webDAVUser = "webDAVUser"
    static let webDAVPassword = "webDAVPassword"
    static let webDAVAutoSync = "webDAVAutoSync"
    /// 本机在云盘上的设备名（弹幕屏蔽词一份一个文件）。
    static let webDAVDeviceID = "webDAVDeviceID"
    static let bangumiAccessToken = "bangumiAccessToken"
    static let bangumiUsername = "bangumiUsername"
    /// 令牌换回来的数字 ID 的缓存。只当缓存用：同步引擎合并前必须自己再问一次
    /// `/v0/me`，不能拿它去拼收藏列表地址——它可能过期。
    static let bangumiUserId = "bangumiUserId"
    static let bangumiSyncEnabled = "bangumiSyncEnabled"
    static let danmakuShieldSyncEnabled = "danmakuShieldSyncEnabled"
    /// 以下键名与默认值对齐 Flutter `lib/services/storage/settings_keys.dart`，
    /// 便于双方生成的设置备份互相恢复。
    static let bangumiSyncEnable = "bangumiSyncEnable"
    static let bangumiSyncPriority = "bangumiSyncPriority"
    static let bangumiImmediateSyncToastEnable = "bangumiImmediateSyncToastEnable"
    static let bangumiAutoMarkWatched = "bangumiAutoMarkWatched"
    /// 「自动标记看过」的待补队列（原版 bangumiProgressQueue）。
    static let bangumiProgressQueue = "bangumiProgressQueue"
    static let webDavEnable = "webDavEnable"
    static let webDavEnableHistory = "webDavEnableHistory"
    static let webDavEnableCollect = "webDavEnableCollect"
    static let webDavEnableDanmakuShield = "webDavEnableDanmakuShield"
    static let proxyEnabled = "proxyEnabled"
    /// 代理地址，一整串（原版 `proxyUrl`）。
    static let proxyUrl = "proxyUrl"
    /// 代理地址测通了没有（原版 `proxyConfigured`）。
    static let proxyConfigured = "proxyConfigured"
    /// 「保存并测试」用的测试地址（原版 `proxyTestUrl`）。
    static let proxyTestUrl = "proxyTestUrl"
    /// 播放内核跟随系统代理（LP 5063 加，LP 5331 把设置里那行拿掉）。
    ///
    /// 现在没有界面用它，存储留着：旧备份里带着这个键，恢复时不丢。
    static let useSystemProxy = "useSystemProxy"
    /// 规则仓库加速方式（上游 2.4.1 起四选一：ghProxy / ghfast / gitcode / direct）。
    static let rulesMirror = "rulesMirror"
    /// 旧的规则仓库镜像开关，只用于把老值接成新四选一。
    static let enableGitProxy = "enableGitProxy"
    /// 图片加速方式（原版 `imageAcceleration`，direct / mirror）。
    static let imageAcceleration = "imageAcceleration"
    /// 首次引导是否已完成（这台设备自己的状态，不进设置备份）。
    static let onboardingCompleted = "onboardingCompleted"
    /// 已经同意的使用约定版本。
    static let onboardingAgreementVersion = "onboardingAgreementVersion"
    static let meteredNetworkLimit = "meteredNetworkLimit"
    static let updateNotificationEnabled = "updateNotificationEnabled"
    /// 下载并发数，沿用原版 `SettingsKeys.downloadParallelEpisodes` 的键名。
    static let downloadParallelEpisodes = "downloadParallelEpisodes"
    /// 每集分片并发数（原版 `downloadParallelSegments`），HLS 一集内部同时拉几个分片。
    static let downloadParallelSegments = "downloadParallelSegments"
    /// 是否随下载一起缓存弹幕，沿用原版 `SettingsKeys.downloadDanmaku` 的键名。
    static let downloadDanmaku = "downloadDanmaku"
    /// 启动页，沿用原版 `SettingsKeys.defaultStartupPage` 的键名。
    static let defaultStartupPage = "defaultStartupPage"
    /// 追番页「在看」列表记住的排序，存 `CollectSort.rawValue`，默认 `updateTime`。
    /// 切分类不写这个键：它只记「在看」里选的排序。
    static let librarySort = "librarySort"
    /// Bangumi 加速（镜像）开关，沿用原版 `SettingsKeys.enableBangumiProxy` 的键名。
    static let enableBangumiProxy = "enableBangumiProxy"
    /// 启动时检查应用更新，沿用原版 `SettingsKeys.autoUpdate` 的键名。
    static let autoUpdate = "autoUpdate"
    /// 启动时检查规则更新，沿用原版 `checkPluginUpdateOnStartup` 的键名。
    static let checkPluginUpdateOnStartup = "checkPluginUpdateOnStartup"
    /// 一起看房间配置
    static let syncPlayEndPoint = "syncPlayEndPoint"
    static let syncPlayRoom = "syncPlayRoom"
    static let syncPlayPassword = "syncPlayPassword"
    /// 上次成功连接的 DLNA 描述地址（IP 或 IP:端口），用于下次手动连接预填与设置备份。
    static let lastDLNAAddress = "lastDLNAAddress"
}

/// 可观察的设置存储。所有写入立即同步到磁盘，避免进程被系统回收后丢设置。
@MainActor
@Observable
final class SettingsStore {
    // 键名前缀统一由非隔离的 `SettingsKey.keyPrefix` 提供（备份扩展也读它）。
    // 这里不再包一层嵌套类型或 `@MainActor` 静态属性：`@MainActor` 类型里的
    // 静态属性受 actor 隔离，经由非隔离上下文（如嵌套类型初始化器）读取会触发
    // Swift 6 的「main actor-isolated default value in a nonisolated context」编译错误。
    private let defaults: UserDefaults

    var themeMode: KazumiThemeMode {
        didSet {
            persist(themeMode.rawValue, SettingsKey.themeMode)
        }
    }

    /// 选中的配色方案（对应原版 `themeColor` 设置，默认绿色）。
    var themeColor: KazumiThemeColor {
        didSet {
            persist(themeColor.id, SettingsKey.themeColor)
            KazumiThemeColor.current = themeColor
        }
    }

    /// 深色模式是否使用纯黑背景（对应原版 `oledEnhance`）。
    var oledEnhance: Bool {
        didSet {
            persist(oledEnhance, SettingsKey.oledEnhance)
            KazumiThemeColor.oledEnhance = oledEnhance
        }
    }

    /// 当前选中的规则源下标（对应 PluginsController.currentPlugin）。
    var selectedPluginIndex: Int {
        didSet { persist(selectedPluginIndex, SettingsKey.selectedPluginIndex) }
    }

    /// 默认超分辨率档位（对应原版 `defaultSuperResolutionMode`，沿用 `anime4kMode` 键名）。
    var superResolutionMode: SuperResolutionMode {
        didSet {
            persist(superResolutionMode.rawValue, SettingsKey.anime4kMode)
            superResolutionOverride = nil
        }
    }

    private var superResolutionOverride: SuperResolutionMode? = nil

    var playbackSuperResolutionMode: SuperResolutionMode {
        get { superResolutionOverride ?? superResolutionMode }
        set { superResolutionOverride = newValue }
    }

    /// 进入播放器时的初始画面比例。播放器里改只影响这一次，不写回这里。
    var defaultAspectRatio: PlayerAspectRatioMode {
        didSet { persist(defaultAspectRatio.rawValue, SettingsKey.playerAspectRatio) }
    }

    /// 触感反馈总开关：关掉后底栏、时间表等处的轻震一起停。
    var hapticFeedbackEnabled: Bool {
        didSet { persist(hapticFeedbackEnabled, SettingsKey.hapticFeedbackEnabled) }
    }

    /// 概览、番剧列表与番剧详情页是否显示评分。
    var showRating: Bool {
        didSet { persist(showRating, SettingsKey.showRating) }
    }

    /// 时间表星期条是否带每天的番剧数量（LP 5039，默认关）。
    var timelineShowCount: Bool {
        didSet { persist(timelineShowCount, SettingsKey.timelineShowCount) }
    }

    /// 上滑时缩小底部标签栏。默认开：上滑把标签栏收起。
    var tabBarShrinkOnScroll: Bool {
        didSet { persist(tabBarShrinkOnScroll, SettingsKey.tabBarShrinkOnScroll) }
    }

    /// AniSkip：在线查片头片尾时间轴，进入片头/片尾时提示跳过。
    /// 键名与默认值照 main 的 `SettingsKeys.aniSkipLookup`（默认开），
    /// 两边的设置备份因此能互认。
    var aniSkipLookup: Bool {
        didSet { persist(aniSkipLookup, SettingsKey.aniSkipLookup) }
    }

    var danmakuEnabled: Bool {
        didSet { persist(danmakuEnabled, SettingsKey.danmakuEnabled) }
    }

    var danmakuOpacity: Double {
        didSet { persist(danmakuOpacity, SettingsKey.danmakuOpacity) }
    }

    var danmakuFontSize: Double {
        didSet { persist(danmakuFontSize, SettingsKey.danmakuFontSize) }
    }

    /// 弹幕显示区域（0.25 ~ 1.0 的屏幕高度占比）。
    var danmakuArea: Double {
        didSet { persist(danmakuArea, SettingsKey.danmakuArea) }
    }

    /// 滚动弹幕横穿屏幕的秒数（main 滑杆 2~16、默认 8）。
    var danmakuDuration: Double {
        didSet { persist(danmakuDuration, SettingsKey.danmakuDuration) }
    }

    /// 弹幕行高倍数（main 滑杆 0~3、默认 1.6）。
    var danmakuLineHeight: Double {
        didSet { persist(danmakuLineHeight, SettingsKey.danmakuLineHeight) }
    }

    /// 弹幕速度是否跟随视频倍速（默认开）。
    var danmakuFollowSpeed: Bool {
        didSet { persist(danmakuFollowSpeed, SettingsKey.danmakuFollowSpeed) }
    }

    var danmakuTop: Bool {
        didSet { persist(danmakuTop, SettingsKey.danmakuTop) }
    }

    /// main 里底部弹幕默认是关的，跟着来。
    var danmakuBottom: Bool {
        didSet { persist(danmakuBottom, SettingsKey.danmakuBottom) }
    }

    var danmakuScroll: Bool {
        didSet { persist(danmakuScroll, SettingsKey.danmakuScroll) }
    }

    var danmakuMassive: Bool {
        didSet { persist(danmakuMassive, SettingsKey.danmakuMassive) }
    }

    var danmakuDeduplication: Bool {
        didSet { persist(danmakuDeduplication, SettingsKey.danmakuDeduplication) }
    }

    var danmakuBorder: Bool {
        didSet { persist(danmakuBorder, SettingsKey.danmakuBorder) }
    }

    var danmakuBorderSize: Double {
        didSet { persist(danmakuBorderSize, SettingsKey.danmakuBorderSize) }
    }

    var danmakuColor: Bool {
        didSet { persist(danmakuColor, SettingsKey.danmakuColor) }
    }

    /// 1~9，对应 w100~w900（main 是同一套数字）。
    var danmakuFontWeight: Int {
        didSet { persist(danmakuFontWeight, SettingsKey.danmakuFontWeight) }
    }

    var danmakuBiliBiliSource: Bool {
        didSet { persist(danmakuBiliBiliSource, SettingsKey.danmakuBiliBiliSource) }
    }

    var danmakuGamerSource: Bool {
        didSet { persist(danmakuGamerSource, SettingsKey.danmakuGamerSource) }
    }

    var danmakuDanDanSource: Bool {
        didSet { persist(danmakuDanDanSource, SettingsKey.danmakuDanDanSource) }
    }

    var danmakuAPIURL: String {
        didSet {
            persist(danmakuAPIURL, SettingsKey.danmakuAPIURL)
            syncDanDanConfiguration()
        }
    }

    var danmakuAPIRequestHeaders: String {
        didSet {
            persist(danmakuAPIRequestHeaders, SettingsKey.danmakuAPIRequestHeaders)
            syncDanDanConfiguration()
        }
    }

    var hasCustomDanmakuAPI: Bool {
        !danmakuAPIURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !danmakuAPIRequestHeaders.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 设置备份是否跳过账号与密码，默认关。
    var settingsBackupOmitCredentials: Bool {
        didSet {
            persist(settingsBackupOmitCredentials, SettingsKey.settingsBackupOmitCredentials)
        }
    }

    var autoPlayNext: Bool {
        didSet { persist(autoPlayNext, SettingsKey.autoPlayNext) }
    }

    var autoSkipOpEd: Bool {
        didSet { persist(autoSkipOpEd, SettingsKey.autoSkipOpEd) }
    }

    var playSpeed: Double {
        didSet { persist(playSpeed, SettingsKey.playSpeed) }
    }

    /// 播放器进入时自动跳到上次播放位置（对应原版「自动跳转」开关）。
    var playResume: Bool {
        didSet { persist(playResume, SettingsKey.playResume) }
    }

    /// 退到后台或熄屏时继续播放音频（设置里叫「切后台继续播放音频」，默认关闭）。
    var backgroundPlayback: Bool {
        didSet { persist(backgroundPlayback, SettingsKey.backgroundPlayback) }
    }

    /// 切到后台时自动起画中画，让画面继续看得见（默认开启）。
    var backgroundAutoPiP: Bool {
        didSet { persist(backgroundAutoPiP, SettingsKey.backgroundAutoPiP) }
    }

    /// 回到前台时，把「因为切后台才停下的」那一集自动接着播（默认开启）。
    var resumeOnForeground: Bool {
        didSet { persist(resumeOnForeground, SettingsKey.resumeOnForeground) }
    }

    /// 画面上竖向滑动调节亮度与音量（对应原版「滑动手势」开关，默认开启）。
    var brightnessVolumeGesture: Bool {
        didSet { persist(brightnessVolumeGesture, SettingsKey.brightnessVolumeGesture) }
    }

    /// 隐身模式：不写入观看记录（对应原版「隐身模式」开关，默认关闭）。
    var privateMode: Bool {
        didSet { persist(privateMode, SettingsKey.privateMode) }
    }

    /// 关闭时使用纯软解，不改变已选的硬件解码模式。
    var hardwareDecodeEnabled: Bool {
        didSet { persist(hardwareDecodeEnabled, SettingsKey.hardwareDecodeEnabled) }
    }

    var hardwareDecodeMode: HardwareDecodeMode {
        didSet { persist(hardwareDecodeMode.rawValue, SettingsKey.hardwareDecodeMode) }
    }

    /// 低内存模式：决定解复用缓存是 1500 MiB 还是 2 MiB（对齐 main，LP 5547）。
    ///
    /// 「跟随网络」是默认档，只在按流量计费的网络下开；本地文件永远不降。
    var lowMemoryMode: LowMemoryMode {
        didSet { persist(lowMemoryMode.rawValue, SettingsKey.lowMemoryPolicy) }
    }

    /// 顶部快进按钮的跳转秒数（对应原版 `buttonSkipTime`，默认 80 秒）。
    var buttonSkipTime: Int {
        didSet { persist(buttonSkipTime, SettingsKey.buttonSkipTime) }
    }

    /// 快进快退的秒数只给系统符号自带数字的那几档：
    /// 10 / 15 / 30 / 45 / 60 / 75 / 90（`goforward.15` 这种）。
    /// 选到别的数就没符号可用，按钮只能自己叠数字，位置和字号都得另管
    /// （LP 2026-10-28 / Colo）。
    static let skipSecondTiers = [10, 15, 30, 45, 60, 75, 90]

    /// 老用户存过 5 秒、20 秒这种没有符号的档，读的时候落到最近的一档
    /// （5→10、20→15），别让按钮空着（Colo）。
    static func nearestSkipSecond(_ seconds: Int) -> Int {
        skipSecondTiers.min { abs($0 - seconds) < abs($1 - seconds) } ?? 15
    }

    /// 画面两侧双击的快进 / 快退秒数（默认 15 秒）。
    var doubleTapSkipTime: Int {
        didSet { persist(doubleTapSkipTime, SettingsKey.doubleTapSkipTime) }
    }

    /// 画面长按时的临时倍速（松手恢复原倍速），默认 2 倍。
    var longPressSpeed: Double {
        didSet { persist(longPressSpeed, SettingsKey.longPressSpeed) }
    }

    /// 控制栏自动隐藏前的停留时长（毫秒，对应原版
    /// `playerControllerLayerDisappearTime`，默认 4000；设置页按 1–10 秒、0.5 秒步进调）。
    var playerControllerLayerDisappearTime: Int {
        didSet {
            persist(playerControllerLayerDisappearTime, SettingsKey.playerControllerLayerDisappearTime)
        }
    }

    var bangumiSyncEnabled: Bool {
        didSet {
            persist(bangumiSyncEnabled, SettingsKey.bangumiSyncEnabled)
            bangumiSyncEnable = bangumiSyncEnabled
        }
    }

    var danmakuShieldSyncEnabled: Bool {
        didSet {
            persist(danmakuShieldSyncEnabled, SettingsKey.danmakuShieldSyncEnabled)
            webDavEnableDanmakuShield = danmakuShieldSyncEnabled
        }
    }

    var bangumiSyncEnable: Bool {
        didSet { persist(bangumiSyncEnable, SettingsKey.bangumiSyncEnable) }
    }

    var bangumiSyncPriority: Int {
        didSet { persist(bangumiSyncPriority, SettingsKey.bangumiSyncPriority) }
    }

    var bangumiImmediateSyncToastEnable: Bool {
        didSet { persist(bangumiImmediateSyncToastEnable, SettingsKey.bangumiImmediateSyncToastEnable) }
    }

    var bangumiAutoMarkWatched: Bool {
        didSet { persist(bangumiAutoMarkWatched, SettingsKey.bangumiAutoMarkWatched) }
    }

    var bangumiAccessToken: String {
        didSet {
            persist(bangumiAccessToken, SettingsKey.bangumiAccessToken)
            BangumiAPI.accessToken = bangumiAccessToken
            // 令牌一改，之前那个 ID 就不再代表当前令牌了，清掉免得屏上留着旧身份。
            if bangumiAccessToken != oldValue, !bangumiUserId.isEmpty {
                bangumiUserId = ""
            }
        }
    }

    var bangumiUsername: String {
        didSet { persist(bangumiUsername, SettingsKey.bangumiUsername) }
    }

    /// 令牌换回来的数字 ID，缓存用。令牌清空时一并清掉：没有令牌就没有身份，
    /// 留着一串数字会让「用户 ID」那行替一个已经失效的令牌担保。
    var bangumiUserId: String {
        didSet { persist(bangumiUserId, SettingsKey.bangumiUserId) }
    }

    var webDAVURL: String {
        didSet { persist(webDAVURL, SettingsKey.webDAVURL) }
    }

    var webDAVUser: String {
        didSet { persist(webDAVUser, SettingsKey.webDAVUser) }
    }

    var webDAVPassword: String {
        didSet { persist(webDAVPassword, SettingsKey.webDAVPassword) }
    }

    /// 本机在云盘上的设备名，弹幕屏蔽词按设备一份文件（原版也是这个办法）。
    /// 第一次用到时生成 32 位十六进制，之后不再变 —— 变了就等于新设备，
    /// 云盘上会多出一份空文件。
    var webDAVDeviceID: String {
        get {
            if storedWebDAVDeviceID.isEmpty {
                storedWebDAVDeviceID = UUID().uuidString
                    .replacingOccurrences(of: "-", with: "")
                    .lowercased()
            }
            return storedWebDAVDeviceID
        }
        set { storedWebDAVDeviceID = newValue }
    }

    private var storedWebDAVDeviceID: String {
        didSet { persist(storedWebDAVDeviceID, SettingsKey.webDAVDeviceID) }
    }

    var webDAVAutoSync: Bool {
        didSet {
            persist(webDAVAutoSync, SettingsKey.webDAVAutoSync)
            webDavEnable = webDAVAutoSync
        }
    }

    var webDavEnable: Bool {
        didSet { persist(webDavEnable, SettingsKey.webDavEnable) }
    }

    var webDavEnableHistory: Bool {
        didSet { persist(webDavEnableHistory, SettingsKey.webDavEnableHistory) }
    }

    var webDavEnableCollect: Bool {
        didSet { persist(webDavEnableCollect, SettingsKey.webDavEnableCollect) }
    }

    var webDavEnableDanmakuShield: Bool {
        didSet { persist(webDavEnableDanmakuShield, SettingsKey.webDavEnableDanmakuShield) }
    }

    /// 代理开关（LP 5331 加，LP 5342 起照 main 的存法）。
    var proxyEnabled: Bool {
        didSet {
            persist(proxyEnabled, SettingsKey.proxyEnabled)
            syncNetworkProxyPolicy()
        }
    }

    /// 代理地址，一整串（`127.0.0.1:6152`，也可以带 `http://` 壳），对应原版 `proxyUrl`。
    ///
    /// 之前拆成地址 / 端口两栏（LP 5331），LP 5342 起并成一栏：main 就是让用户贴
    /// 一整串、`ProxyUtils.parseProxyUrl` 一次解析，我们没有更优的原生做法。
    var proxyUrl: String {
        didSet {
            persist(proxyUrl, SettingsKey.proxyUrl)
            syncNetworkProxyPolicy()
        }
    }

    /// 代理地址测通了才算「已配置」，对应原版 `proxyConfigured`。
    /// 开关打开前要求这个，跟 main 一样。
    var proxyConfigured: Bool {
        didSet { persist(proxyConfigured, SettingsKey.proxyConfigured) }
    }

    /// 「保存并测试」时拿哪个地址试，对应原版 `proxyTestUrl`。
    var proxyTestUrl: String {
        didSet { persist(proxyTestUrl, SettingsKey.proxyTestUrl) }
    }

    /// 播放内核要用的代理，形如 `http://127.0.0.1:6152`；开关关着或地址写错了就是 nil。
    ///
    /// iOS 上 App 拿不到代理软件（Surge 之类）在 HTTP 模式下监听的那个端口，
    /// 读系统那份（Wi-Fi 代理）对不上，所以只认用户自己填的（LP 5331）。
    var playerProxyURL: String? {
        guard proxyEnabled else { return nil }
        return ProxyURL.formatted(proxyUrl)
    }

    /// 把代理同步进那份进程内网络策略（各 URLSession 建配置时读它）。
    private func syncNetworkProxyPolicy() {
        KazumiNetworkPolicy.proxyURL = proxyEnabled ? proxyUrl : ""
    }

    /// 播放内核跟随系统代理（LP 5063/5067 加，LP 5331 把设置里那行拿掉了）。
    ///
    /// 现在没有界面用它，存储留着：旧备份里带着这个键，恢复时不丢。
    var useSystemProxy: Bool {
        didSet { persist(useSystemProxy, SettingsKey.useSystemProxy) }
    }

    /// 规则仓库加速方式（上游 2.4.1 起从开关改成四选一）。
    var rulesMirror: String {
        didSet {
            persist(rulesMirror, SettingsKey.rulesMirror)
            // withLock 的闭包是 Sendable 的，先把值取成局部常量再进去。
            let selected = RulesMirror(rawValue: rulesMirror) ?? .ghProxy
            RulesRepoClient.mirror.withLock { $0 = selected }
        }
    }

    /// 图片加速方式（对应原版 `imageAcceleration`）。
    var imageAcceleration: String {
        didSet {
            persist(imageAcceleration, SettingsKey.imageAcceleration)
            KazumiNetworkPolicy.imageAcceleration = ImageAcceleration(rawValue: imageAcceleration) ?? .direct
        }
    }

    var meteredNetworkLimit: Bool {
        didSet { persist(meteredNetworkLimit, SettingsKey.meteredNetworkLimit) }
    }

    /// 首次引导走完没有。跟着设备走，恢复别人的设置备份不会把引导跳过去。
    var onboardingCompleted: Bool {
        didSet { persist(onboardingCompleted, SettingsKey.onboardingCompleted) }
    }

    /// 同意过的使用约定版本号，欢迎页点「继续」时写入。
    var onboardingAgreementVersion: Int {
        didSet { persist(onboardingAgreementVersion, SettingsKey.onboardingAgreementVersion) }
    }

    var updateNotificationEnabled: Bool {
        didSet { persist(updateNotificationEnabled, SettingsKey.updateNotificationEnabled) }
    }

    /// 下载并发数（对应原版 `downloadParallelEpisodes`）。
    var downloadParallelEpisodes: Int {
        didSet { persist(downloadParallelEpisodes, SettingsKey.downloadParallelEpisodes) }
    }

    /// 每集分片并发数（对应原版 `downloadParallelSegments`，1–10）。
    var downloadParallelSegments: Int {
        didSet { persist(downloadParallelSegments, SettingsKey.downloadParallelSegments) }
    }

    /// 是否随下载一起缓存弹幕（对应原版 `downloadDanmaku`）。
    var downloadDanmaku: Bool {
        didSet { persist(downloadDanmaku, SettingsKey.downloadDanmaku) }
    }

    /// 启动页（对应原版 `defaultStartupPage`，存的是页面路径）。
    var defaultStartupPage: String {
        didSet { persist(defaultStartupPage, SettingsKey.defaultStartupPage) }
    }

    /// 追番页「在看」列表上次选的排序（`CollectSort.rawValue`）。
    var librarySort: String {
        didSet { persist(librarySort, SettingsKey.librarySort) }
    }

    /// 是否走 Bangumi 镜像加速（对应原版 `enableBangumiProxy`）。
    var enableBangumiProxy: Bool {
        didSet {
            persist(enableBangumiProxy, SettingsKey.enableBangumiProxy)
            BangumiAcceleration.mode = enableBangumiProxy ? .mirror : .direct
        }
    }

    /// 启动时检查应用更新（对应原版 `autoUpdate`，默认开启）。
    var autoUpdateCheck: Bool {
        didSet { persist(autoUpdateCheck, SettingsKey.autoUpdate) }
    }

    /// 启动时检查规则更新（对应原版 `checkPluginUpdateOnStartup`，默认开启）。
    var checkPluginUpdateOnStartup: Bool {
        didSet { persist(checkPluginUpdateOnStartup, SettingsKey.checkPluginUpdateOnStartup) }
    }

    /// 一起看的房间服务器地址、房间名与口令
    var syncPlayEndPoint: String {
        didSet { persist(syncPlayEndPoint, SettingsKey.syncPlayEndPoint) }
    }

    var syncPlayRoom: String {
        didSet { persist(syncPlayRoom, SettingsKey.syncPlayRoom) }
    }

    var syncPlayPassword: String {
        didSet { persist(syncPlayPassword, SettingsKey.syncPlayPassword) }
    }

    /// 上次实际投屏成功的 DLNA 地址；不是凭据，会跟随设置备份迁移。
    var lastDLNAAddress: String {
        didSet { persist(lastDLNAAddress, SettingsKey.lastDLNAAddress) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 旧版 Swift 键 -> Flutter 键的一次性迁移。只在目标键从未写过时复制，
        // 原键保留不删，旧属性仍可读取；旧 UI 改值时由 didSet 同步到新键。
        Self.migrateLegacySetting(defaults, from: SettingsKey.bangumiSyncEnabled, to: SettingsKey.bangumiSyncEnable)
        Self.migrateLegacySetting(defaults, from: SettingsKey.webDAVAutoSync, to: SettingsKey.webDavEnable)
        Self.migrateLegacySetting(
            defaults,
            from: SettingsKey.danmakuShieldSyncEnabled,
            to: SettingsKey.webDavEnableDanmakuShield
        )
        // 主题模式也要用局部变量承载：初始化阶段读实例属性（`themeMode`）
        // 会触发「self 在全部存储属性就绪前被访问」的编译错误。
        //
        // 存的是 rawValue 字符串（见 `themeMode.didSet`），因此不能用
        // `Self.read(..., KazumiThemeMode.system)` —— 那是 `as? KazumiThemeMode`
        // 强转，字符串永远转不过去，重启后会静默回落到「跟随系统」。
        let storedThemeMode = defaults.object(
            forKey: SettingsKey.keyPrefix + SettingsKey.themeMode
        ) as? String
        let resolvedThemeMode = storedThemeMode
            .flatMap { KazumiThemeMode(rawValue: $0) } ?? .system
        themeMode = resolvedThemeMode
        // 原版把 'default' 视为绿色；这里额外兼容旧备份里可能出现的 ARGB 字符串。
        let storedThemeColor = defaults.object(forKey: SettingsKey.keyPrefix + SettingsKey.themeColor) as? String
        let resolvedThemeColor = KazumiThemeColor.named(storedThemeColor ?? KazumiThemeColor.standard.id)
        themeColor = resolvedThemeColor
        // 静态成员不能经由 `self` 读取（等价于访问未初始化完成的实例），
        // 因此局部变量承载读取结果，等构造结束再同步到全局调色板。
        let resolvedOLEDEnhance = Self.read(defaults, SettingsKey.oledEnhance, false)
        oledEnhance = resolvedOLEDEnhance
        // 在全部存储属性初始化完成后再同步全局调色板，避免 'self' 提前访问。
        KazumiThemeColor.current = resolvedThemeColor
        KazumiThemeColor.oledEnhance = resolvedOLEDEnhance
        // 应用主题的明暗不再需要额外注明：强调色按 SwiftUI 的 `colorScheme` 显式取，
        // 而 `colorScheme` 就是下面那个 `preferredColorScheme` 的结果。
        selectedPluginIndex = Self.read(defaults, SettingsKey.selectedPluginIndex, 0)
        superResolutionMode = SuperResolutionMode(
            rawValue: Self.read(defaults, SettingsKey.anime4kMode, 1)
        ) ?? .off
        defaultAspectRatio = PlayerAspectRatioMode(
            rawValue: Self.read(defaults, SettingsKey.playerAspectRatio, "automatic")
        ) ?? .automatic
        hapticFeedbackEnabled = Self.read(defaults, SettingsKey.hapticFeedbackEnabled, true)
        showRating = Self.read(defaults, SettingsKey.showRating, true)
        timelineShowCount = Self.read(defaults, SettingsKey.timelineShowCount, false)
        tabBarShrinkOnScroll = Self.read(defaults, SettingsKey.tabBarShrinkOnScroll, true)
        aniSkipLookup = Self.read(defaults, SettingsKey.aniSkipLookup, true)
        danmakuEnabled = Self.read(defaults, SettingsKey.danmakuEnabled, true)
        danmakuOpacity = Self.read(defaults, SettingsKey.danmakuOpacity, 1.0)
        danmakuFontSize = Self.read(defaults, SettingsKey.danmakuFontSize, 20.0)
        danmakuArea = Self.read(defaults, SettingsKey.danmakuArea, 0.5)
        // 弹幕显示与样式：默认值照 main 的 settings_keys.dart（4 号键组）。
        danmakuDuration = min(16, max(2, Self.read(defaults, SettingsKey.danmakuDuration, 8.0)))
        danmakuLineHeight = min(3, max(0, Self.read(defaults, SettingsKey.danmakuLineHeight, 1.6)))
        danmakuFollowSpeed = Self.read(defaults, SettingsKey.danmakuFollowSpeed, true)
        danmakuTop = Self.read(defaults, SettingsKey.danmakuTop, true)
        danmakuBottom = Self.read(defaults, SettingsKey.danmakuBottom, false)
        danmakuScroll = Self.read(defaults, SettingsKey.danmakuScroll, true)
        danmakuMassive = Self.read(defaults, SettingsKey.danmakuMassive, false)
        danmakuDeduplication = Self.read(defaults, SettingsKey.danmakuDeduplication, false)
        danmakuBorder = Self.read(defaults, SettingsKey.danmakuBorder, true)
        danmakuBorderSize = min(3, max(0.1, Self.read(defaults, SettingsKey.danmakuBorderSize, 1.5)))
        danmakuColor = Self.read(defaults, SettingsKey.danmakuColor, true)
        danmakuFontWeight = min(9, max(1, Self.read(defaults, SettingsKey.danmakuFontWeight, 4)))
        danmakuBiliBiliSource = Self.read(defaults, SettingsKey.danmakuBiliBiliSource, true)
        danmakuGamerSource = Self.read(defaults, SettingsKey.danmakuGamerSource, true)
        danmakuDanDanSource = Self.read(defaults, SettingsKey.danmakuDanDanSource, true)
        danmakuAPIURL = Self.read(defaults, SettingsKey.danmakuAPIURL, "")
        danmakuAPIRequestHeaders = Self.read(
            defaults,
            SettingsKey.danmakuAPIRequestHeaders,
            ""
        )
        settingsBackupOmitCredentials = Self.read(
            defaults,
            SettingsKey.settingsBackupOmitCredentials,
            false
        )
        autoPlayNext = Self.read(defaults, SettingsKey.autoPlayNext, true)
        autoSkipOpEd = Self.read(defaults, SettingsKey.autoSkipOpEd, false)
        playSpeed = PlaybackSpeed.nearest(Self.read(defaults, SettingsKey.playSpeed, 1.0))
        playResume = Self.read(defaults, SettingsKey.playResume, true)
        backgroundPlayback = Self.read(defaults, SettingsKey.backgroundPlayback, false)
        backgroundAutoPiP = Self.read(defaults, SettingsKey.backgroundAutoPiP, true)
        resumeOnForeground = Self.read(defaults, SettingsKey.resumeOnForeground, true)
        brightnessVolumeGesture = Self.read(defaults, SettingsKey.brightnessVolumeGesture, true)
        privateMode = Self.read(defaults, SettingsKey.privateMode, false)
        hardwareDecodeEnabled = Self.read(defaults, SettingsKey.hardwareDecodeEnabled, true)
        hardwareDecodeMode = HardwareDecodeMode(
            rawValue: Self.read(defaults, SettingsKey.hardwareDecodeMode, HardwareDecodeMode.videotoolbox.rawValue)
        ) ?? .videotoolbox
        // 老版本只写过 `lowMemoryMode` 那个布尔。它不是这里的三档键，读不到就回默认档，
        // 与 main「旧值留着、新键没写过就当自动」的做法一致。
        lowMemoryMode = LowMemoryMode(
            rawValue: Self.read(defaults, SettingsKey.lowMemoryPolicy, LowMemoryMode.auto.rawValue)
        ) ?? .auto
        // 秒数必须为正：备份或旧数据里若写进了 0 / 负数，快进按钮会变成空操作。
        buttonSkipTime = max(1, Self.read(defaults, SettingsKey.buttonSkipTime, 80))
        // 老数据里存过 5 / 20 这种没有对应符号的档，读出来就落到最近的一档
        // （5→10、20→15），不然按钮画不出数字（Colo 2026-10-28）。
        doubleTapSkipTime = Self.nearestSkipSecond(
            max(1, Self.read(defaults, SettingsKey.doubleTapSkipTime, 15))
        )
        // 长按倍速固定归到菜单里那几档，存进来的怪值不至于让播放器跑飞。
        longPressSpeed = PlaybackSpeed.nearest(Self.read(defaults, SettingsKey.longPressSpeed, 2.0))
        // 与原版滑杆的上下限一致（1–10 秒）；越界值夹回范围内，避免控制栏永不隐藏或瞬间消失。
        playerControllerLayerDisappearTime = min(
            10_000,
            max(1_000, Self.read(defaults, SettingsKey.playerControllerLayerDisappearTime, 4000))
        )
        bangumiSyncEnabled = Self.read(defaults, SettingsKey.bangumiSyncEnabled, false)
        danmakuShieldSyncEnabled = Self.read(defaults, SettingsKey.danmakuShieldSyncEnabled, false)
        bangumiSyncEnable = Self.read(defaults, SettingsKey.bangumiSyncEnable, false)
        bangumiSyncPriority = Self.read(defaults, SettingsKey.bangumiSyncPriority, BangumiSyncPriority.bangumiFirst.rawValue)
        bangumiImmediateSyncToastEnable = Self.read(
            defaults,
            SettingsKey.bangumiImmediateSyncToastEnable,
            true
        )
        // 默认关：LP 4744 明确要求保持关，别自己改成默认开。
        bangumiAutoMarkWatched = Self.read(defaults, SettingsKey.bangumiAutoMarkWatched, false)
        bangumiAccessToken = Self.read(defaults, SettingsKey.bangumiAccessToken, "")
        bangumiUsername = Self.read(defaults, SettingsKey.bangumiUsername, "")
        bangumiUserId = Self.read(defaults, SettingsKey.bangumiUserId, "")
        webDAVURL = Self.read(defaults, SettingsKey.webDAVURL, "")
        webDAVUser = Self.read(defaults, SettingsKey.webDAVUser, "")
        webDAVPassword = Self.read(defaults, SettingsKey.webDAVPassword, "")
        webDAVAutoSync = Self.read(defaults, SettingsKey.webDAVAutoSync, false)
        storedWebDAVDeviceID = Self.read(defaults, SettingsKey.webDAVDeviceID, "")
        webDavEnable = Self.read(defaults, SettingsKey.webDavEnable, false)
        webDavEnableHistory = Self.read(defaults, SettingsKey.webDavEnableHistory, false)
        webDavEnableCollect = Self.read(defaults, SettingsKey.webDavEnableCollect, false)
        webDavEnableDanmakuShield = Self.read(defaults, SettingsKey.webDavEnableDanmakuShield, false)
        proxyEnabled = Self.read(defaults, SettingsKey.proxyEnabled, false)
        useSystemProxy = Self.read(defaults, SettingsKey.useSystemProxy, false)
        proxyUrl = Self.read(defaults, SettingsKey.proxyUrl, "")
        proxyConfigured = Self.read(defaults, SettingsKey.proxyConfigured, false)
        proxyTestUrl = Self.read(defaults, SettingsKey.proxyTestUrl, "")
        // 规则仓库加速：新键优先；老用户按旧开关接（开着落 gh-proxy，关着落直连）；
        // 全新安装没有旧键，落 gh-proxy（上游默认）。
        if let storedMirror = defaults.string(forKey: SettingsKey.rulesMirror),
           RulesMirror(rawValue: storedMirror) != nil {
            rulesMirror = storedMirror
        } else if let legacyFlag = defaults.object(forKey: SettingsKey.enableGitProxy) as? Bool {
            rulesMirror = (legacyFlag ? RulesMirror.ghProxy : RulesMirror.direct).rawValue
        } else {
            rulesMirror = RulesMirror.ghProxy.rawValue
        }
        onboardingCompleted = Self.read(defaults, SettingsKey.onboardingCompleted, false)
        onboardingAgreementVersion = Self.read(defaults, SettingsKey.onboardingAgreementVersion, 0)
        imageAcceleration = Self.read(defaults, SettingsKey.imageAcceleration, ImageAcceleration.mirror.rawValue)
        meteredNetworkLimit = Self.read(defaults, SettingsKey.meteredNetworkLimit, false)
        // LP 2530：提醒范围默认关，用户自己打开时才申请通知权限。
        updateNotificationEnabled = Self.read(defaults, SettingsKey.updateNotificationEnabled, false)
        downloadParallelEpisodes = Self.read(defaults, SettingsKey.downloadParallelEpisodes, 2)
        // 与原版滑杆一致（1–10，默认 3）；越界值夹回范围内。
        downloadParallelSegments = min(
            10,
            max(1, Self.read(defaults, SettingsKey.downloadParallelSegments, 3))
        )
        downloadDanmaku = Self.read(defaults, SettingsKey.downloadDanmaku, true)
        defaultStartupPage = Self.read(defaults, SettingsKey.defaultStartupPage, "/tab/popular/")
        librarySort = Self.read(defaults, SettingsKey.librarySort, "updateTime")
        // LP 5063：番剧条目和图片两处默认都改走镜像。只有全新安装会用到这个默认值，
        // 已经存在机器上的设置不会被改（用户自己选过就尊重他的选择）。
        enableBangumiProxy = Self.read(defaults, SettingsKey.enableBangumiProxy, true)
        autoUpdateCheck = Self.read(defaults, SettingsKey.autoUpdate, true)
        checkPluginUpdateOnStartup = Self.read(defaults, SettingsKey.checkPluginUpdateOnStartup, true)
        syncPlayEndPoint = Self.read(defaults, SettingsKey.syncPlayEndPoint, "")
        syncPlayRoom = Self.read(defaults, SettingsKey.syncPlayRoom, "")
        syncPlayPassword = Self.read(defaults, SettingsKey.syncPlayPassword, "")
        lastDLNAAddress = Self.read(defaults, SettingsKey.lastDLNAAddress, "")
        // 加速方式在全部存储属性初始化完成后再同步到全局开关。
        BangumiAcceleration.mode = enableBangumiProxy ? .mirror : .direct
        // 网络那几项同样要补一次：init 里赋初值不触发 didSet，
        // 不补的话冷启动后镜像开关、代理、图片加速都还是默认值。
        let selectedMirror = RulesMirror(rawValue: rulesMirror) ?? .ghProxy
        RulesRepoClient.mirror.withLock { $0 = selectedMirror }
        KazumiNetworkPolicy.imageAcceleration =
            ImageAcceleration(rawValue: imageAcceleration) ?? .direct
        // 代理也得补：漏了这一行，冷启动后开关是开着的、各 URLSession 却是
        // 不带代理那份（`ProxyAwareURLSession` 的代号还是 0），得等用户进设置页
        // 动一下才生效。模拟器上就是这样：开关开着指向一个没在听的端口，
        // 主页照样正常加载。
        syncNetworkProxyPolicy()
        syncDanDanConfiguration()
        // init 中给存储属性赋初值不会触发 didSet，这里补一次启动时的令牌注入；
        // 之后设置页改令牌、恢复备份都会走 `bangumiAccessToken.didSet`。
        BangumiAPI.accessToken = bangumiAccessToken
    }

    /// 把播放相关设置恢复为出厂值（LP 清单「恢复默认设置」）。
    ///
    /// 只动播放器与超分辨率：规则、网络、同步这些不在这里，
    /// 所以设置页那颗按钮的确认文案也只提这两块，不夸大范围。
    func resetPlayerSettings() {
        autoPlayNext = true
        playResume = true
        backgroundPlayback = false
        backgroundAutoPiP = true
        resumeOnForeground = true
        brightnessVolumeGesture = true
        privateMode = false
        hardwareDecodeEnabled = true
        hardwareDecodeMode = .videotoolbox
        lowMemoryMode = .auto
        playSpeed = 1.0
        buttonSkipTime = 80
        doubleTapSkipTime = 15
        longPressSpeed = 2.0
        playerControllerLayerDisappearTime = 4000
        superResolutionMode = .off
        defaultAspectRatio = .automatic
    }

    /// 弹幕设置的「恢复默认设置」（main: resetDanmakuSettings）。
    /// 只动弹幕观感这几项，关键词屏蔽规则和来源优先级是内容不是观感，不碰。
    func resetDanmakuSettings() {
        danmakuEnabled = true
        danmakuFontSize = 20
        danmakuOpacity = 1.0
        danmakuArea = 0.5
        danmakuDuration = 8
        danmakuLineHeight = 1.6
        danmakuFollowSpeed = true
        danmakuTop = true
        danmakuBottom = false
        danmakuScroll = true
        danmakuMassive = false
        danmakuDeduplication = false
        danmakuBorder = true
        danmakuBorderSize = 1.5
        danmakuColor = true
        danmakuFontWeight = 4
        danmakuBiliBiliSource = true
        danmakuGamerSource = true
        danmakuDanDanSource = true
    }

    private func persist(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: SettingsKey.keyPrefix + key)
    }

    private func syncDanDanConfiguration() {
        DanDanRuntimeConfiguration.apply(
            baseURL: danmakuAPIURL,
            requestHeaders: (try? DanDanRequestHeaders.parse(danmakuAPIRequestHeaders)) ?? [:]
        )
    }

    // MARK: - 原始快照（设置备份用）

    /// 「自动标记看过」的待补队列（原版 `bangumiProgressQueue`，一份 JSON 数组）。
    ///
    /// 键名与格式跟原版一致，方便两边互相读懂；这个键不进设置备份
    /// （`excludedKeys` 里已经写明：队列是这台设备的待办，不该搬到另一台）。
    var bangumiProgressQueue: String {
        get { defaults.string(forKey: SettingsKey.keyPrefix + SettingsKey.bangumiProgressQueue) ?? "" }
        set { defaults.set(newValue, forKey: SettingsKey.keyPrefix + SettingsKey.bangumiProgressQueue) }
    }

    /// 弹幕屏蔽词的原文（一条一行）。
    ///
    /// 这个键不在本类建模的属性里：屏蔽词页（DanmakuShieldScreen）自己按同一个
    /// 键名读写，WebDAV 同步也需要整串带出去，所以在这里开一个读写口，
    /// 让两处用同一份键名，避免再出现「写得进、读不出」的偏差。
    var danmakuFilterRulesText: String {
        get { defaults.string(forKey: SettingsKey.keyPrefix + SettingsKey.danmakuFilterRules) ?? "" }
        set { defaults.set(newValue, forKey: SettingsKey.keyPrefix + SettingsKey.danmakuFilterRules)
            // 改完就来一条通知：同步那边防抖 500ms 后上传（原版的时机）。
            NotificationCenter.default.post(name: .kazumiDanmakuRulesChanged, object: nil)
        }
    }

    /// 已落盘的设置快照：键名（去掉前缀）-> 值。
    ///
    /// 对应原版 `GStorage.rawSettingsSnapshot()`。备份导出以它为底，
    /// 这样本地没有建模、但确实在磁盘上的设置项（旧版留下的快捷键、
    /// 时间表过滤条件、低内存策略等）也能原样带走，
    /// 不会因为「这边没有对应属性」就被静默丢掉。
    func rawSettingsSnapshot() -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for (key, value) in defaults.dictionaryRepresentation() {
            guard key.hasPrefix(SettingsKey.keyPrefix) else { continue }
            let name = String(key.dropFirst(SettingsKey.keyPrefix.count))
            guard let json = Self.jsonValue(fromStored: value) else { continue }
            result[name] = json
        }
        return result
    }

    /// 把「本地没有建模」的设置项原样落盘（键名沿用原版 Hive 键名）。
    ///
    /// 原版恢复备份是整段写回设置箱，这边同样不挑键：认得的键由各属性接收，
    /// 认不得的先存着，下次导出还能原样带出去。
    @discardableResult
    func persistRawSetting(_ value: JSONValue, forKey key: String) -> Bool {
        guard let stored = Self.storedValue(from: value) else { return false }
        defaults.set(stored, forKey: SettingsKey.keyPrefix + key)
        return true
    }

    /// UserDefaults 里的值 -> JSONValue。只认标量与字符串列表，
    /// 与 SettingsBackup 支持的取值范围保持一致。
    private static func jsonValue(fromStored value: Any) -> JSONValue? {
        switch value {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            // UserDefaults 把布尔、整数、浮点都包成 NSNumber，
            // 且 Bool 也会以 NSNumber 的身份回来，所以先按 CFBoolean 的类型区分，
            // 否则 true 会被写成 1。
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            // 整数值按 Int 存（备份里 2 与 2.0 对 Flutter 是两种类型），
            // 带小数的才写 double。
            let doubleValue = number.doubleValue
            if doubleValue == doubleValue.rounded(),
               doubleValue <= Double(Int.max),
               doubleValue >= Double(Int.min) {
                return .int(number.intValue)
            }
            return .double(doubleValue)
        case let array as [Any]:
            // 只认字符串列表：混合类型数组不是设置项（与原版 _encodeValue 一致）。
            var strings: [String] = []
            for item in array {
                guard let text = item as? String else { return nil }
                strings.append(text)
            }
            return .array(strings.map(JSONValue.string))
        default:
            return nil
        }
    }

    /// JSONValue -> 可写入 UserDefaults 的值。对象与 null 不是设置项，返回 nil。
    private static func storedValue(from value: JSONValue) -> Any? {
        switch value {
        case .null, .object:
            return nil
        case .bool(let flag):
            return flag
        case .int(let number):
            return number
        case .double(let number):
            return number
        case .string(let text):
            return text
        case .array(let items):
            let strings: [String] = items.compactMap { item in
                if case .string(let text) = item { return text }
                return nil
            }
            guard strings.count == items.count else { return nil }
            return strings
        }
    }

    private static func read<Value>(_ defaults: UserDefaults, _ key: String, _ fallback: Value) -> Value {
        defaults.object(forKey: SettingsKey.keyPrefix + key) as? Value ?? fallback
    }

    /// 目标键从未写入、且旧键有值时，把旧值按原类型复制到新键。
    ///
    /// 旧键保持原样，既能被旧属性继续读取，也不会丢失用户已存的值。
    private static func migrateLegacySetting(
        _ defaults: UserDefaults,
        from oldKey: String,
        to newKey: String
    ) {
        let newFullKey = SettingsKey.keyPrefix + newKey
        guard defaults.object(forKey: newFullKey) == nil,
              let legacyValue = defaults.object(forKey: SettingsKey.keyPrefix + oldKey) else {
            return
        }
        defaults.set(legacyValue, forKey: newFullKey)
    }
}
