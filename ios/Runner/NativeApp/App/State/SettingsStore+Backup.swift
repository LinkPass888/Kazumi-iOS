//
//  SettingsStore+Backup.swift
//  Kazumi
//
//  设置的导出 / 导入，对应 lib/pages/settings/backup_settings.dart。
//
//  原版的设置存在 Hive 的 settings box 里，键名就是下面 legacyKeys 的右列。
//  导出时用原版键名写，导入时原版键名与本地键名都认，
//  于是旧版（Flutter）导出的备份能原样导入这边。
//

import Foundation

extension SettingsStore {
    /// 本地键名 -> 原版（Hive）键名。
    private static let legacyKeys: [String: String] = [
        SettingsKey.webDAVURL: "webDavURL",
        SettingsKey.webDAVUser: "webDavUsername",
        SettingsKey.webDAVPassword: "webDavPasswd",
        SettingsKey.webDAVAutoSync: SettingsKey.webDavEnable,
        SettingsKey.bangumiSyncEnabled: SettingsKey.bangumiSyncEnable,
        SettingsKey.danmakuEnabled: "danmakuEnabledByDefault",
        SettingsKey.playSpeed: "defaultPlaySpeed",
        // 以下三项在原版设置箱里就是同名键，写出来是为了让导出 / 恢复走同一条
        // 「本地键 -> 原版键」通道，而不是被当成未建模的透传键。
        SettingsKey.playResume: "playResume",
        SettingsKey.backgroundPlayback: "backgroundPlayback",
        SettingsKey.brightnessVolumeGesture: "brightnessVolumeGesture",
        SettingsKey.privateMode: "privateMode",
        SettingsKey.buttonSkipTime: "buttonSkipTime",
        SettingsKey.playerControllerLayerDisappearTime: "playerControllerLayerDisappearTime",
        SettingsKey.proxyEnabled: "proxyEnable",
        SettingsKey.proxyUrl: "proxyUrl",
        SettingsKey.proxyConfigured: "proxyConfigured",
        SettingsKey.proxyTestUrl: "proxyTestUrl",
        SettingsKey.updateNotificationEnabled: "bangumiUpdateNotifyEnable",
        SettingsKey.anime4kMode: "defaultSuperResolutionType",
        SettingsKey.danmakuShieldSyncEnabled: SettingsKey.webDavEnableDanmakuShield,
    ]

    /// 备份里使用的键名：有原版键名就用原版的。
    private static func backupKey(_ localKey: String) -> String {
        legacyKeys[localKey] ?? localKey
    }

    // 凭据类键统一由 `SettingsBackup.credentialKeys` 提供（非隔离枚举，
    // 导出时的范围过滤与恢复确认弹窗的提示读同一份清单，不会两处走偏）。

    /// 不参与备份的键，对应 lib/services/storage/settings_backup.dart 的
    /// `excludedKeys`：
    ///   * 设备标识与同步游标 —— 每台设备必须自己生成，拷过来会和另一台撞车；
    ///   * 同步内部状态与待办队列 —— 来自远端数据，不是用户设置；
    ///   * 代理「已测试通过」标记 —— 换设备后网络环境不同，必须重新测试；
    ///   * 设置备份「不含账号与密码」开关 —— 这是本机导出偏好，不随备份迁移；
    ///   * 下载目录与安全作用域书签 —— 都是这台设备的沙箱状态；
    ///   * 引导与提示条「已显示」标记 —— 那份体验跟着设备走。
    ///   * Bangumi 用户名与用户 ID —— **只是缓存，不是设置**。每次连上都会
    ///     用令牌重新换回来（main 根本不落盘，只在内存里），令牌一改就作废。
    ///     带进备份等于把一张可能已经失效的身份带到另一台设备上显示。
    private static let excludedKeys: Set<String> = [
        "historySyncDeviceId",
        "historySyncSequence",
        "historySyncSnapshotInitialized",
        "danmakuShieldSyncDeviceId",
        "danmakuShieldSyncState",
        "danmakuShieldSyncCorruptState",
        "bangumiProgressQueue",
        "bangumiUsername",
        "bangumiUserId",
        "proxyConfigured",
        SettingsKey.settingsBackupOmitCredentials,
        "downloadDirectory",
        "downloadDirectoryBookmark",
        "onboardingCompleted",
        "onboardingAgreementVersion",
        "shortcutDialogShown",
    ]

    /// 动态键名（按番剧 id 存的搜索历史等）同样不参与备份。
    private static let excludedPrefixes = [
        "shortcut_",
        "danmakuSearchHistory_",
    ]

    /// 是否属于「不参与备份」的键。
    private static func isExcludedKey(_ key: String) -> Bool {
        excludedKeys.contains(key) || excludedPrefixes.contains { key.hasPrefix($0) }
    }

    /// 已经由具体属性接收的键（原版键名与本地键名都算），
    /// 恢复时剩下的键才走透传落盘。
    private static let consumedKeys: Set<String> = {
        var keys: Set<String> = [
            SettingsKey.themeMode,
            SettingsKey.themeColor,
            SettingsKey.oledEnhance,
            SettingsKey.autoPlayNext,
            SettingsKey.autoSkipOpEd,
            SettingsKey.playResume,
            SettingsKey.backgroundPlayback,
            SettingsKey.backgroundAutoPiP,
            SettingsKey.resumeOnForeground,
            SettingsKey.brightnessVolumeGesture,
            SettingsKey.privateMode,
            SettingsKey.buttonSkipTime,
            SettingsKey.doubleTapSkipTime,
            SettingsKey.longPressSpeed,
            SettingsKey.playerAspectRatio,
            SettingsKey.hapticFeedbackEnabled,
            SettingsKey.showRating,
            SettingsKey.tabBarShrinkOnScroll,
            SettingsKey.playerControllerLayerDisappearTime,
            SettingsKey.danmakuOpacity,
            SettingsKey.danmakuFontSize,
            SettingsKey.danmakuArea,
            SettingsKey.danmakuAPIURL,
            SettingsKey.danmakuAPIRequestHeaders,
            SettingsKey.downloadParallelEpisodes,
            SettingsKey.downloadDanmaku,
            SettingsKey.defaultStartupPage,
            SettingsKey.enableBangumiProxy,
            SettingsKey.rulesMirror,
            SettingsKey.useSystemProxy,
            SettingsKey.imageAcceleration,
            SettingsKey.selectedPluginIndex,
            SettingsKey.autoUpdate,
            SettingsKey.checkPluginUpdateOnStartup,
            SettingsKey.meteredNetworkLimit,
            SettingsKey.updateNotificationEnabled,
            SettingsKey.bangumiAccessToken,
            SettingsKey.bangumiUsername,
            SettingsKey.proxyUrl,
            SettingsKey.proxyConfigured,
            SettingsKey.proxyTestUrl,
            SettingsKey.bangumiSyncEnable,
            SettingsKey.bangumiSyncPriority,
            SettingsKey.bangumiImmediateSyncToastEnable,
            SettingsKey.bangumiAutoMarkWatched,
            SettingsKey.webDavEnable,
            SettingsKey.webDavEnableHistory,
            SettingsKey.webDavEnableCollect,
            SettingsKey.webDavEnableDanmakuShield,
            SettingsKey.lastDLNAAddress,
        ]
        for (local, legacy) in legacyKeys {
            keys.insert(local)
            keys.insert(legacy)
        }
        return keys
    }()

    /// 由属性读出的「当前设置」。这些值是最新的，
    /// 磁盘上可能还是旧值（个别键只在内存里改），导出时覆盖上去。
    private func propertySnapshot(omitCredentials: Bool) -> [(String, JSONValue)] {
        var pairs: [(String, JSONValue)] = [
            (SettingsKey.themeMode, .string(themeMode.rawValue)),
            (SettingsKey.themeColor, .string(Self.backupThemeColorValue(themeColor))),
            (SettingsKey.oledEnhance, .bool(oledEnhance)),
            (SettingsKey.autoPlayNext, .bool(autoPlayNext)),
            (SettingsKey.autoSkipOpEd, .bool(autoSkipOpEd)),
            (SettingsKey.anime4kMode, .int(superResolutionMode.rawValue)),
            (SettingsKey.playSpeed, .double(playSpeed)),
            (SettingsKey.playResume, .bool(playResume)),
            (SettingsKey.backgroundPlayback, .bool(backgroundPlayback)),
            (SettingsKey.backgroundAutoPiP, .bool(backgroundAutoPiP)),
            (SettingsKey.resumeOnForeground, .bool(resumeOnForeground)),
            (SettingsKey.brightnessVolumeGesture, .bool(brightnessVolumeGesture)),
            (SettingsKey.privateMode, .bool(privateMode)),
            (SettingsKey.buttonSkipTime, .int(buttonSkipTime)),
            (SettingsKey.doubleTapSkipTime, .int(doubleTapSkipTime)),
            (SettingsKey.longPressSpeed, .double(longPressSpeed)),
            (SettingsKey.playerAspectRatio, .string(defaultAspectRatio.rawValue)),
            (SettingsKey.hapticFeedbackEnabled, .bool(hapticFeedbackEnabled)),
            (SettingsKey.showRating, .bool(showRating)),
            (SettingsKey.tabBarShrinkOnScroll, .bool(tabBarShrinkOnScroll)),
            (SettingsKey.playerControllerLayerDisappearTime, .int(playerControllerLayerDisappearTime)),
            (SettingsKey.danmakuEnabled, .bool(danmakuEnabled)),
            (SettingsKey.danmakuOpacity, .double(danmakuOpacity)),
            (SettingsKey.danmakuFontSize, .double(danmakuFontSize)),
            (SettingsKey.danmakuArea, .double(danmakuArea)),
            (SettingsKey.downloadParallelEpisodes, .int(downloadParallelEpisodes)),
            (SettingsKey.downloadDanmaku, .bool(downloadDanmaku)),
            (SettingsKey.defaultStartupPage, .string(defaultStartupPage)),
            (SettingsKey.enableBangumiProxy, .bool(enableBangumiProxy)),
            (SettingsKey.meteredNetworkLimit, .bool(meteredNetworkLimit)),
            (SettingsKey.updateNotificationEnabled, .bool(updateNotificationEnabled)),
            (SettingsKey.selectedPluginIndex, .int(selectedPluginIndex)),
            (SettingsKey.autoUpdate, .bool(autoUpdateCheck)),
            (SettingsKey.checkPluginUpdateOnStartup, .bool(checkPluginUpdateOnStartup)),
            (SettingsKey.bangumiSyncEnable, .bool(bangumiSyncEnable)),
            (SettingsKey.bangumiSyncPriority, .int(bangumiSyncPriority)),
            (SettingsKey.bangumiImmediateSyncToastEnable, .bool(bangumiImmediateSyncToastEnable)),
            (SettingsKey.bangumiAutoMarkWatched, .bool(bangumiAutoMarkWatched)),
            (SettingsKey.webDavEnable, .bool(webDavEnable)),
            (SettingsKey.webDavEnableHistory, .bool(webDavEnableHistory)),
            (SettingsKey.webDavEnableCollect, .bool(webDavEnableCollect)),
            (SettingsKey.webDavEnableDanmakuShield, .bool(webDavEnableDanmakuShield)),
            (SettingsKey.proxyEnabled, .bool(proxyEnabled)),
            (SettingsKey.lastDLNAAddress, .string(lastDLNAAddress)),
        ]
        if !omitCredentials {
            pairs += [
                (SettingsKey.webDAVURL, .string(webDAVURL)),
                (SettingsKey.webDAVUser, .string(webDAVUser)),
                (SettingsKey.webDAVPassword, .string(webDAVPassword)),
                (SettingsKey.bangumiAccessToken, .string(bangumiAccessToken)),
                (SettingsKey.bangumiUsername, .string(bangumiUsername)),
                (SettingsKey.proxyUrl, .string(proxyUrl)),
                (SettingsKey.proxyTestUrl, .string(proxyTestUrl)),
                (SettingsKey.danmakuAPIURL, .string(danmakuAPIURL)),
                (
                    SettingsKey.danmakuAPIRequestHeaders,
                    .string(danmakuAPIRequestHeaders)
                ),
            ]
        }
        return pairs
    }

    /// 原版设置箱里 `themeColor` 存的字符串：
    /// 默认色写 `'default'`，其余写 8 位 ARGB 十六进制（`'ff4caf50'`）。
    /// 导出时照这个格式写，旧版（Flutter）才认得。
    private static func backupThemeColorValue(_ theme: KazumiThemeColor) -> String {
        theme.id == KazumiThemeColor.standard.id
            ? "default"
            : String(format: "%08x", theme.seed)
    }

    /// 当前设置的备份快照。
    ///
    /// `omitCredentials` 为 true 时跳过账号与密码，
    /// 对应原版「不含账号与密码」的导出范围。
    ///
    /// 取数与原版一致：先摊开磁盘上的全部设置项（包括本地没有建模、
    /// 但确实存在的那些），再用属性值覆盖一遍，最后剔掉不参与备份的键。
    /// 这样导出的内容不会比原版少，旧版也认得出键名。
    func backupSnapshot(omitCredentials: Bool) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for (localKey, value) in rawSettingsSnapshot() {
            let key = Self.backupKey(localKey)
            guard !Self.isExcludedKey(key) else { continue }
            if omitCredentials, SettingsBackup.credentialKeys.contains(key) { continue }
            result[key] = value
        }
        for (localKey, value) in propertySnapshot(omitCredentials: omitCredentials) {
            let key = Self.backupKey(localKey)
            guard !Self.isExcludedKey(key) else { continue }
            result[key] = value
        }
        return result
    }

    /// 从备份里恢复设置，返回真正恢复的项数。
    ///
    /// 备份里可能同时出现原版键名与本地键名，原版键名优先。
    @discardableResult
    func applyBackup(_ settings: [String: JSONValue]) -> Int {
        func value(_ localKey: String) -> JSONValue? {
            if let legacy = Self.legacyKeys[localKey], let value = settings[legacy] {
                return value
            }
            return settings[localKey]
        }

        var restored = 0
        if let raw = value(SettingsKey.themeMode)?.stringValue,
           let mode = KazumiThemeMode(rawValue: raw) {
            themeMode = mode
            restored += 1
        }
        if let raw = value(SettingsKey.themeColor)?.stringValue, !raw.isEmpty {
            themeColor = KazumiThemeColor.named(raw)
            restored += 1
        }
        if let flag = value(SettingsKey.oledEnhance)?.boolValue {
            oledEnhance = flag
            restored += 1
        }
        if let flag = value(SettingsKey.autoPlayNext)?.boolValue {
            autoPlayNext = flag
            restored += 1
        }
        if let flag = value(SettingsKey.autoSkipOpEd)?.boolValue {
            autoSkipOpEd = flag
            restored += 1
        }
        if let flag = value(SettingsKey.danmakuEnabled)?.boolValue {
            danmakuEnabled = flag
            restored += 1
        }
        if let number = value(SettingsKey.danmakuOpacity)?.doubleValue {
            danmakuOpacity = number
            restored += 1
        }
        if let number = value(SettingsKey.danmakuFontSize)?.doubleValue {
            danmakuFontSize = number
            restored += 1
        }
        if let number = value(SettingsKey.danmakuArea)?.doubleValue {
            danmakuArea = number
            restored += 1
        }
        if let number = value(SettingsKey.playSpeed)?.doubleValue {
            playSpeed = number
            restored += 1
        }
        if let flag = value(SettingsKey.playResume)?.boolValue {
            playResume = flag
            restored += 1
        }
        if let flag = value(SettingsKey.backgroundPlayback)?.boolValue {
            backgroundPlayback = flag
            restored += 1
        }
        if let flag = value(SettingsKey.backgroundAutoPiP)?.boolValue {
            backgroundAutoPiP = flag
            restored += 1
        }
        if let flag = value(SettingsKey.resumeOnForeground)?.boolValue {
            resumeOnForeground = flag
            restored += 1
        }
        if let flag = value(SettingsKey.brightnessVolumeGesture)?.boolValue {
            brightnessVolumeGesture = flag
            restored += 1
        }
        if let flag = value(SettingsKey.privateMode)?.boolValue {
            privateMode = flag
            restored += 1
        }
        if let number = value(SettingsKey.buttonSkipTime)?.intValue {
            buttonSkipTime = max(1, number)
            restored += 1
        }
        if let number = value(SettingsKey.doubleTapSkipTime)?.intValue {
            doubleTapSkipTime = max(1, number)
            restored += 1
        }
        if let number = value(SettingsKey.longPressSpeed)?.doubleValue {
            longPressSpeed = PlaybackSpeed.nearest(number)
            restored += 1
        }
        if let raw = value(SettingsKey.playerAspectRatio)?.stringValue,
           let mode = PlayerAspectRatioMode(rawValue: raw) {
            defaultAspectRatio = mode
            restored += 1
        }
        if let flag = value(SettingsKey.hapticFeedbackEnabled)?.boolValue {
            hapticFeedbackEnabled = flag
            restored += 1
        }
        if let flag = value(SettingsKey.showRating)?.boolValue {
            showRating = flag
            restored += 1
        }
        if let flag = value(SettingsKey.tabBarShrinkOnScroll)?.boolValue {
            tabBarShrinkOnScroll = flag
            restored += 1
        }
        if let number = value(SettingsKey.playerControllerLayerDisappearTime)?.intValue {
            playerControllerLayerDisappearTime = min(10_000, max(1_000, number))
            restored += 1
        }
        if let raw = value(SettingsKey.anime4kMode)?.intValue,
           let mode = SuperResolutionMode(rawValue: raw) {
            superResolutionMode = mode
            restored += 1
        }
        if let number = value(SettingsKey.downloadParallelEpisodes)?.intValue {
            downloadParallelEpisodes = min(8, max(1, number))
            restored += 1
        }
        if let flag = value(SettingsKey.downloadDanmaku)?.boolValue {
            downloadDanmaku = flag
            restored += 1
        }
        if let text = value(SettingsKey.defaultStartupPage)?.stringValue, !text.isEmpty {
            defaultStartupPage = text
            restored += 1
        }
        if let flag = value(SettingsKey.enableBangumiProxy)?.boolValue {
            enableBangumiProxy = flag
            restored += 1
        }
        if let text = value(SettingsKey.rulesMirror)?.stringValue,
           RulesMirror(rawValue: text) != nil {
            rulesMirror = text
            restored += 1
        } else if let flag = value(SettingsKey.enableGitProxy)?.boolValue {
            // 旧备份里还是开关：开着落 gh-proxy，关着落直连。
            rulesMirror = (flag ? RulesMirror.ghProxy : RulesMirror.direct).rawValue
            restored += 1
        }
        if let flag = value(SettingsKey.useSystemProxy)?.boolValue {
            useSystemProxy = flag
            restored += 1
        }
        if let text = value(SettingsKey.imageAcceleration)?.stringValue,
           ImageAcceleration(rawValue: text) != nil {
            imageAcceleration = text
            restored += 1
        }
        if let number = value(SettingsKey.selectedPluginIndex)?.intValue {
            selectedPluginIndex = max(0, number)
            restored += 1
        }
        if let flag = value(SettingsKey.autoUpdate)?.boolValue {
            autoUpdateCheck = flag
            restored += 1
        }
        if let flag = value(SettingsKey.checkPluginUpdateOnStartup)?.boolValue {
            checkPluginUpdateOnStartup = flag
            restored += 1
        }
        if let flag = value(SettingsKey.meteredNetworkLimit)?.boolValue {
            meteredNetworkLimit = flag
            restored += 1
        }
        if let flag = value(SettingsKey.updateNotificationEnabled)?.boolValue {
            updateNotificationEnabled = flag
            restored += 1
        }
        if let text = value(SettingsKey.webDAVURL)?.stringValue {
            webDAVURL = text
            restored += 1
        }
        if let text = value(SettingsKey.webDAVUser)?.stringValue {
            webDAVUser = text
            restored += 1
        }
        if let text = value(SettingsKey.webDAVPassword)?.stringValue {
            webDAVPassword = text
            restored += 1
        }
        if let flag = value(SettingsKey.webDavEnable)?.boolValue {
            webDavEnable = flag
            webDAVAutoSync = flag
            restored += 1
        }
        if let text = value(SettingsKey.bangumiAccessToken)?.stringValue {
            bangumiAccessToken = text
            restored += 1
        }
        if !Self.isExcludedKey(SettingsKey.bangumiUsername),
           let text = value(SettingsKey.bangumiUsername)?.stringValue {
            bangumiUsername = text
            restored += 1
        }
        if let flag = value(SettingsKey.bangumiSyncEnable)?.boolValue {
            bangumiSyncEnable = flag
            bangumiSyncEnabled = flag
            restored += 1
        }
        if let number = value(SettingsKey.bangumiSyncPriority)?.intValue {
            bangumiSyncPriority = number
            restored += 1
        }
        if let flag = value(SettingsKey.bangumiImmediateSyncToastEnable)?.boolValue {
            bangumiImmediateSyncToastEnable = flag
            restored += 1
        }
        if let flag = value(SettingsKey.bangumiAutoMarkWatched)?.boolValue {
            bangumiAutoMarkWatched = flag
            restored += 1
        }
        if let flag = value(SettingsKey.webDavEnableHistory)?.boolValue {
            webDavEnableHistory = flag
            restored += 1
        }
        if let flag = value(SettingsKey.webDavEnableCollect)?.boolValue {
            webDavEnableCollect = flag
            restored += 1
        }
        if let flag = value(SettingsKey.webDavEnableDanmakuShield)?.boolValue {
            webDavEnableDanmakuShield = flag
            danmakuShieldSyncEnabled = flag
            restored += 1
        }
        if let flag = value(SettingsKey.proxyEnabled)?.boolValue {
            proxyEnabled = flag
            restored += 1
        }
        if let text = value(SettingsKey.proxyUrl)?.stringValue {
            proxyUrl = text
            restored += 1
        }
        if !Self.isExcludedKey(SettingsKey.proxyConfigured),
           let flag = value(SettingsKey.proxyConfigured)?.boolValue {
            proxyConfigured = flag
            restored += 1
        }
        if let text = value(SettingsKey.proxyTestUrl)?.stringValue {
            proxyTestUrl = text
            restored += 1
        }
        if let text = value(SettingsKey.danmakuAPIURL)?.stringValue {
            danmakuAPIURL = text
            restored += 1
        }
        if let text = value(SettingsKey.danmakuAPIRequestHeaders)?.stringValue {
            danmakuAPIRequestHeaders = text
            restored += 1
        }
        if let text = value(SettingsKey.lastDLNAAddress)?.stringValue {
            lastDLNAAddress = text
            restored += 1
        }
        // 未被上面任何属性接收的键整段写回（原版恢复备份就是整段覆盖设置箱）。
        //
        // 这一层有两个作用：
        //   1. 备份里的键与本地属性名不完全对应（同一份 Flutter 设置箱里有
        //      近百个键，这边只建模了其中一部分），不认识的键不能丢，
        //      否则「导出 → 恢复 → 再导出」会一路缩水；
        //   2. 恢复后的项数按备份实际内容统计，与原版 toast 的
        //      「已恢复 N 项设置」对齐。
        //
        // 这里不按白名单挑键：原版是整段覆盖设置箱，挑键会让本机自己的键
        // （弹幕屏蔽规则 danmakuFilterRules 等）导出后恢复不回来，
        // 项数也会比备份里少。
        for (key, rawValue) in settings where !Self.consumedKeys.contains(key) {
            guard !Self.isExcludedKey(key) else { continue }
            guard persistRawSetting(rawValue, forKey: key) else { continue }
            restored += 1
        }
        return restored
    }
}
