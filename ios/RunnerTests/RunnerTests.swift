//
//  RunnerTests.swift
//  RunnerTests
//
//  原生工程冒烟测试：验证包信息与内置资源（Anime4K 着色器）确实打进了 Bundle。
//

import Foundation
import Testing
@testable import Runner

struct RunnerTests {
    @Test("应用包信息保持原样")
    func hostAppIdentity() {
        let host = Bundle.main
        #expect(host.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "Kazumi")
        #expect(host.object(forInfoDictionaryKey: "CFBundleName") as? String == "kazumi")
    }

    @Test("Anime4K 着色器随包分发")
    func anime4kShadersBundled() {
        let host = Bundle.main
        let shader = host.url(
            forResource: "Anime4K_Upscale_CNN_x2_M",
            withExtension: "glsl",
            subdirectory: "shaders"
        )
        #expect(shader != nil)
    }

    @Test("DLNA 重连地址会保留描述端口")
    func dlnaReconnectAddressKeepsPort() throws {
        let location = try #require(URL(string: "http://192.168.31.88:8895/description.xml"))
        let control = try #require(URL(string: "http://192.168.31.88:8895/ctl/AVTransport"))
        let device = DLNADevice(
            name: "TV",
            ip: "192.168.31.88",
            location: location,
            controlURL: control
        )

        #expect(device.reconnectAddress == "192.168.31.88:8895")
    }

    @Test("DLNA 地址会持久化并跟随设置备份恢复")
    @MainActor
    func dlnaAddressPersistsAndRestores() {
        let sourceSuite = "RunnerTests.DLNA.Source.\(UUID().uuidString)"
        let targetSuite = "RunnerTests.DLNA.Target.\(UUID().uuidString)"
        let sourceDefaults = UserDefaults(suiteName: sourceSuite)!
        let targetDefaults = UserDefaults(suiteName: targetSuite)!
        defer {
            sourceDefaults.removePersistentDomain(forName: sourceSuite)
            targetDefaults.removePersistentDomain(forName: targetSuite)
        }

        let source = SettingsStore(defaults: sourceDefaults)
        source.lastDLNAAddress = "192.168.31.88:8895"
        #expect(SettingsStore(defaults: sourceDefaults).lastDLNAAddress == "192.168.31.88:8895")

        let snapshot = source.backupSnapshot(omitCredentials: false)
        #expect(snapshot[SettingsKey.lastDLNAAddress]?.stringValue == "192.168.31.88:8895")

        let target = SettingsStore(defaults: targetDefaults)
        target.applyBackup(snapshot)
        #expect(target.lastDLNAAddress == "192.168.31.88:8895")
    }

    @Test("规则仓库筛选把可更新规则算作已安装")
    func pluginShopInstalledFilterIncludesUpdates() {
        #expect(PluginShopFilter.all.includes(.install))
        #expect(PluginShopFilter.all.includes(.installed))
        #expect(PluginShopFilter.all.includes(.update))
        #expect(PluginShopFilter.installed.includes(.installed))
        #expect(PluginShopFilter.installed.includes(.update))
        #expect(!PluginShopFilter.installed.includes(.install))
        #expect(PluginShopFilter.update.includes(.update))
        #expect(!PluginShopFilter.update.includes(.installed))
    }

    @Test("规则仓库搜索匹配名称和作者")
    func pluginShopSearchMatchesNameAndAuthor() {
        let item = PluginHTTPItem(
            name: "Anime Garden",
            version: "1.0.0",
            useNativePlayer: true,
            author: "Kazumi Team",
            lastUpdate: 0
        )

        #expect(item.matchesCatalogSearch("garden"))
        #expect(item.matchesCatalogSearch("kazumi"))
        #expect(item.matchesCatalogSearch("  "))
        #expect(!item.matchesCatalogSearch("mikan"))
    }

    @Test("AniSkip 起播稳定前不判定片头")
    @MainActor
    func aniSkipWaitsForPlaybackStart() {
        let model = SkipSegmentPillModel()
        model.segments = SkipSegments(
            opening: SkipRange(start: 100, end: 110, source: .aniskip),
            ending: nil
        )
        model.duration = 1_400
        model.position = 96
        model.isPlaybackReady = false
        model.update()
        #expect(!model.isVisible)

        model.isPlaybackReady = true
        model.update()
        #expect(model.isVisible)
        #expect(model.mode == .countdown)
    }

    @Test("片尾贴结尾且没有下一集时不弹 AniSkip")
    @MainActor
    func aniSkipSuppressesShortEndingWithoutNextEpisode() {
        let model = SkipSegmentPillModel()
        model.segments = SkipSegments(
            opening: nil,
            ending: SkipRange(start: 100, end: 110, source: .aniskip)
        )
        model.duration = 113
        model.position = 96
        model.hasNextEpisode = false
        model.isPlaybackReady = true
        model.update()
        #expect(!model.isVisible)
    }

    @Test("片尾贴结尾时按有没有下一集决定弹窗")
    @MainActor
    func aniSkipEndingPromptMatchesNextEpisodeAvailability() {
        let model = SkipSegmentPillModel()
        model.segments = SkipSegments(
            opening: nil,
            ending: SkipRange(start: 100, end: 110, source: .aniskip)
        )
        model.duration = 113
        model.position = 96
        model.isPlaybackReady = true

        model.hasNextEpisode = true
        model.update()
        #expect(model.isVisible)
        #expect(model.mode == .nextEpisode)

        model.duration = 120
        model.update()
        #expect(model.isVisible)
        #expect(model.mode == .countdown)
    }
}
