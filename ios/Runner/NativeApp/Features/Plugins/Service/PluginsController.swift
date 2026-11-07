//
//  PluginsController.swift
//  Kazumi
//
//  1:1 翻译 lib/plugins/plugins_controller.dart（MobX → Swift Observation）。
//
//  * 规则列表持久化到 Application Support/Kazumi/rules/v2/plugins.json；
//  * 所有变更串行执行，写盘失败回滚内存状态；
//  * 目录刷新 5 分钟内复用，显式刷新绕过；
//  * 批量更新最多 4 个并发下载，且绝不降级已安装规则。
//

import Foundation
import Observation

enum PluginUpdateAvailability: Sendable {
    case unknown
    case notInCatalog
    case latest
    case updatable
}

enum PluginCatalogItemStatus: Sendable {
    case install
    case installed
    case update
}

enum PluginUpdateResult: Sendable {
    case updated
    case requiresNewerClient
    case failed
    case notNewer
}

struct PluginBatchUpdateResult: Sendable {
    var candidates: Int
    var updated: Int
    var requiresNewerClient: Int
    var failed: Int
    var notNewer: Int

    var hasNoCandidates: Bool { candidates == 0 }
}

enum PluginControllerError: Error, LocalizedError, Sendable {
    case catalogNotLoaded
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case .catalogNotLoaded: String(localized: "规则目录尚未加载")
        case .persistence(let message): message
        }
    }
}

@MainActor
@Observable
final class PluginsController {
    typealias CatalogLoader = @Sendable () async throws -> [PluginHTTPItem]
    typealias PluginLoader = @Sendable (String) async throws -> Plugin

    /// 规则存储文件：Application Support/Kazumi/rules/v2/plugins.json。
    static var defaultFileURL: URL {
        AppEnvironment.rulesRoot
            .appending(path: "v2", directoryHint: .isDirectory)
            .appending(path: "plugins.json")
    }

    private static let catalogMaxAge: TimeInterval = 5 * 60
    private static let maxConcurrentRuleDownloads = 4

    private(set) var pluginList: [Plugin] = []
    private(set) var pluginHTTPList: [PluginHTTPItem] = []
    let validityTracker = PluginValidityTracker()

    private var catalogByName: [String: PluginHTTPItem] = [:]
    private var catalogRefreshedAt: Date?
    private var catalogSource: String?
    private var isRefreshInFlight = false

    private let fileURL: URL
    private let catalogLoader: CatalogLoader
    private let pluginLoader: PluginLoader
    private let errorReporter: @Sendable (String, Error) -> Void
    private var mutations: Task<Void, Never> = Task {}

    init(
        fileURL: URL = PluginsController.defaultFileURL,
        catalogLoader: @escaping CatalogLoader = { try await PluginCatalogAPI().getPluginList() },
        pluginLoader: @escaping PluginLoader = { try await PluginCatalogAPI().getPlugin(name: $0) },
        errorReporter: (@Sendable (String, Error) -> Void)? = nil
    ) {
        self.fileURL = fileURL
        self.catalogLoader = catalogLoader
        self.pluginLoader = pluginLoader
        self.errorReporter = errorReporter ?? { message, error in
            KazumiLog.plugin.error("\(message, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 对应 init()：读取规则文件；文件不存在时迁移旧版单文件规则。
    func load() {
        pluginList = []
        if FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            do {
                let text = try String(contentsOf: fileURL, encoding: .utf8)
                let decoded = try JSONValue.decode(text)
                var loaded = (decoded.arrayValue ?? []).map(Plugin.init(json:))
                // 老版本把规则里的数字写成了布尔（page: 1 → page: true），
                // 读出来时按数字键反推还原一次，修好了就落盘（LP 3446）。
                var repairedCount = 0
                for index in loaded.indices where loaded[index].repairMangledQueryNumbers() {
                    repairedCount += 1
                }
                pluginList = loaded
                if repairedCount > 0 {
                    KazumiLog.plugin.info("Plugin: repaired mangled numeric query values in \(repairedCount) rule(s)")
                    do {
                        try self.persist()
                    } catch {
                        self.errorReporter("Plugin: failed to persist repaired rules", error)
                    }
                }
                KazumiLog.plugin.info("Plugin: Current Plugin number: \(self.pluginList.count)")
            } catch {
                errorReporter("Plugin: failed to read rule file", error)
            }
        } else {
            migrateLegacyPlugins()
        }
    }

    /// 1.5.1 之前每条规则是一个独立 JSON 文件（父目录），迁移后删除旧文件。
    private func migrateLegacyPlugins() {
        let legacyDirectory = fileURL.deletingLastPathComponent().deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: legacyDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        var migrated: [Plugin] = []
        var migratedURLs: [URL] = []
        for url in entries where url.pathExtension == "json" {
            do {
                let decoded = try JSONValue.decode(try String(contentsOf: url, encoding: .utf8))
                migrated.append(Plugin(json: decoded))
                migratedURLs.append(url)
            } catch {
                errorReporter("Plugin: failed to migrate legacy rule \(url.lastPathComponent)", error)
            }
        }
        guard !migrated.isEmpty else { return }
        let legacyURLs = migratedURLs
        pluginList = migrated
        mutations = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try self.persist()
                for url in legacyURLs {
                    try? FileManager.default.removeItem(at: url)
                }
            } catch {
                self.errorReporter("Plugin: failed to persist migrated rules", error)
            }
        }
    }

    // MARK: - 查询

    func plugin(named name: String) -> Plugin? {
        let key = pluginNameKey(name)
        return pluginList.first { pluginNameKey($0.name) == key }
    }

    func isInstalled(_ name: String) -> Bool {
        plugin(named: name) != nil
    }

    var isCatalogFresh: Bool {
        guard catalogSource == KazumiEndpoints.pluginShopIndex,
              let refreshedAt = catalogRefreshedAt else { return false }
        return Date().timeIntervalSince(refreshedAt) < Self.catalogMaxAge
    }

    func pluginStatus(_ item: PluginHTTPItem) -> PluginCatalogItemStatus {
        guard let local = plugin(named: item.name) else { return .install }
        return remoteIsNewer(local: local.version, remote: item.version) ? .update : .installed
    }

    func pluginUpdateStatus(_ plugin: Plugin) -> PluginUpdateAvailability {
        guard catalogRefreshedAt != nil else { return .unknown }
        guard let remote = catalogByName[pluginNameKey(plugin.name)] else { return .notInCatalog }
        return remoteIsNewer(local: plugin.version, remote: remote.version) ? .updatable : .latest
    }

    var updatablePluginCount: Int {
        updatablePluginNames().count
    }

    func updatablePluginNames() -> [String] {
        pluginList.compactMap { plugin in
            guard pluginUpdateStatus(plugin) == .updatable,
                  let remote = catalogByName[pluginNameKey(plugin.name)] else { return nil }
            return remote.name
        }
    }

    /// 对应 _remoteIsNewer：解析失败（原实现会抛异常）时退化为字符串不等判断。
    private func remoteIsNewer(local: String, remote: String) -> Bool {
        VersionCompare.needUpdate(local: local, remote: remote)
    }
    // MARK: - 变更（串行 + 失败回滚）

    func removePlugin(_ plugin: Plugin) async throws {
        let key = pluginNameKey(plugin.name)
        try await mutate("Plugin: failed to persist rule removal") {
            self.pluginList.removeAll { pluginNameKey($0.name) == key }
        }
    }

    func updatePlugin(_ plugin: Plugin) async throws {
        try await mutate("Plugin: failed to persist rule update") {
            self.replacePlugin(plugin)
        }
    }

    func updatePlugins(_ plugins: [Plugin]) async throws {
        try await mutate("Plugin: failed to persist imported rules") {
            for plugin in plugins { self.replacePlugin(plugin) }
        }
    }

    func removePlugins(named names: Set<String>) async throws {
        let keys = Set(names.map(pluginNameKey))
        try await mutate("Plugin: failed to persist batch rule removal") {
            self.pluginList.removeAll { keys.contains(pluginNameKey($0.name)) }
        }
    }

    /// 拖动排序：先乐观更新，写盘失败且期间没有新的排序时回滚。
    func move(fromOffsets source: IndexSet, toOffset destination: Int) async throws {
        let previous = pluginList
        pluginList.move(fromOffsets: source, toOffset: destination)
        let revision = reorderRevision &+ 1
        reorderRevision = revision
        do {
            // enqueue 的闭包要求 @Sendable，快照在轮到本次写入时再取，避免覆盖更早的变更。
            try await enqueue {
                let snapshotToWrite = self.pluginList
                let targetURL = self.fileURL
                do {
                    try Self.write(snapshotToWrite, to: targetURL)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
        } catch {
            if revision == reorderRevision { pluginList = previous }
            errorReporter("Plugin: failed to persist rule order", error)
            throw error
        }
    }

    private var reorderRevision = 0

    private func replacePlugin(_ plugin: Plugin) {
        let key = pluginNameKey(plugin.name)
        if let index = pluginList.firstIndex(where: { pluginNameKey($0.name) == key }) {
            pluginList[index] = plugin
        } else {
            pluginList.append(plugin)
        }
    }

    /// 所有变更的统一入口：串行执行 body → 写盘 → 失败回滚内存状态。
    private func mutate(_ errorMessage: String, _ body: @escaping @Sendable @MainActor () -> Void) async throws {
        try await enqueue {
            // 队列 task 本身就在主 actor 上，可直接读写内存状态。
            let previous = self.pluginList
            body()
            let snapshot = self.pluginList
            do {
                try Self.write(snapshot, to: self.fileURL)
                return .success(())
            } catch {
                self.pluginList = previous
                self.errorReporter(errorMessage, error)
                return .failure(error)
            }
        }
    }

    /// 串行队列：把任务接在上一个 task 之后，保证写盘顺序与调用顺序一致。
    /// 队列只用于排序，错误通过返回值交给发起调用的一方。
    private func enqueue(
        _ operation: @escaping @MainActor @Sendable () async -> Result<Void, Error>
    ) async throws {
        let previous = mutations
        let task = Task { @MainActor () -> Result<Void, Error> in
            await previous.value
            return await operation()
        }
        mutations = Task { @MainActor in
            _ = await task.value
        }
        try await task.value.get()
    }

    /// 写盘只剩纯 IO，因此不要求 actor 隔离，可安全地在 @Sendable 闭包里调用。
    @discardableResult
    private static func write(_ plugins: [Plugin], to fileURL: URL) throws -> URL {
        let payload = JSONValue.array(plugins.map { $0.toJSON() })
        let text = payload.serialized(pretty: false)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: fileURL, options: .atomic)
        KazumiLog.plugin.info("Plugin: updated plugin file plugins.json")
        return fileURL
    }

    /// 实例写盘：默认落盘当前内存列表，供同步路径复用。
    private func persist(_ plugins: [Plugin]? = nil) throws {
        try Self.write(plugins ?? pluginList, to: fileURL)
    }

    // MARK: - 规则目录

    func refreshPluginCatalog() async throws -> [PluginHTTPItem] {
        if isRefreshInFlight {
            // 单飞：仓库没变就复用；仓库变了则等旧请求结束后再拉新地址。
            while isRefreshInFlight {
                try await Task.sleep(for: .milliseconds(50))
            }
            if catalogSource == KazumiEndpoints.pluginShopIndex {
                return pluginHTTPList
            }
            return try await refreshPluginCatalog()
        }
        let source = KazumiEndpoints.pluginShopIndex
        isRefreshInFlight = true
        do {
            let catalog = try await catalogLoader()
            isRefreshInFlight = false
            guard source == KazumiEndpoints.pluginShopIndex else {
                return try await refreshPluginCatalog()
            }
            catalogByName = Dictionary(
                catalog.map { (pluginNameKey($0.name), $0) },
                uniquingKeysWith: { _, latest in latest }
            )
            pluginHTTPList = catalog
            catalogRefreshedAt = Date()
            catalogSource = source
            return catalog
        } catch {
            isRefreshInFlight = false
            errorReporter("Plugin: failed to refresh rule catalog", error)
            throw error
        }
    }

    func ensurePluginCatalog() async throws -> [PluginHTTPItem] {
        if isCatalogFresh { return pluginHTTPList }
        return try await refreshPluginCatalog()
    }

    /// 启动时检查可更新规则数量（对应 checkPluginUpdatesOnStartup）。
    func checkPluginUpdatesOnStartup(enabled: Bool) async -> Int {
        guard enabled else { return 0 }
        _ = try? await refreshPluginCatalog()
        return updatablePluginNames().count
    }

    // MARK: - 更新

    @discardableResult
    func tryUpdatePlugin(named name: String) async -> PluginUpdateResult {
        let catalogName = catalogByName[pluginNameKey(name)]?.name ?? name
        let attempt = await prepareUpdate(named: catalogName)
        // prepareUpdate 总是返回非可选结果；只有 .updated 会带回待落盘的规则。
        guard case .updated = attempt.result, let plugin = attempt.plugin else {
            return attempt.result
        }
        do {
            try await mutate("Plugin: failed to persist downloaded rule \(catalogName)") {
                self.replacePlugin(plugin)
            }
            return .updated
        } catch {
            return .failed
        }
    }

    @discardableResult
    func tryUpdateAllPlugins(ensureCatalog: Bool = true) async throws -> PluginBatchUpdateResult {
        if ensureCatalog {
            _ = try await ensurePluginCatalog()
        } else if catalogRefreshedAt == nil {
            throw PluginControllerError.catalogNotLoaded
        }

        let candidates = updatablePluginNames()
        let attempts = await prepareUpdates(names: candidates)
        var updated: [Plugin] = []
        var result = PluginBatchUpdateResult(
            candidates: candidates.count,
            updated: 0,
            requiresNewerClient: 0,
            failed: 0,
            notNewer: 0
        )
        for attempt in attempts {
            switch attempt.result {
            case .updated:
                result.updated += 1
                if let plugin = attempt.plugin { updated.append(plugin) }
            case .requiresNewerClient:
                result.requiresNewerClient += 1
            case .failed:
                result.failed += 1
            case .notNewer:
                result.notNewer += 1
            }
        }
        if !updated.isEmpty {
            try await mutate("Plugin: failed to persist batch rule update") {
                for plugin in updated { self.replacePlugin(plugin) }
            }
        }
        return result
    }

    /// tryUpdatePlugin / tryUpdateAllPlugins 的单次下载结果，会跨 actor 边界返回，故需 Sendable。
    private struct UpdateAttempt: Sendable {
        var result: PluginUpdateResult
        var plugin: Plugin?
    }

    private func prepareUpdate(named name: String) async -> UpdateAttempt {
        let remotePlugin: Plugin
        do {
            remotePlugin = try await pluginLoader(name)
        } catch {
            errorReporter("Plugin: failed to download rule \(name)", error)
            return UpdateAttempt(result: .failed, plugin: nil)
        }
        // 在加载边界处校验完整性，防止目录与文件内容不一致的投毒规则。
        if remotePlugin.name.isEmpty || pluginNameKey(remotePlugin.name) != pluginNameKey(name) {
            errorReporter(
                "Plugin: rejected mismatched rule payload",
                PluginControllerError.persistence("Downloaded rule name \(remotePlugin.name) does not match \(name)")
            )
            return UpdateAttempt(result: .failed, plugin: nil)
        }
        var remote = remotePlugin
        // 保留目录中的拼写。
        remote.name = name
        if remote.requiresNewerClient {
            return UpdateAttempt(result: .requiresNewerClient, plugin: nil)
        }
        // 镜像可能落后上游，绝不降级已安装规则。
        if let local = plugin(named: name), !remoteIsNewer(local: local.version, remote: remote.version) {
            return UpdateAttempt(result: .notNewer, plugin: nil)
        }
        return UpdateAttempt(result: .updated, plugin: remote)
    }

    /// 批量更新用的取件入口：把下标一并传入，避免子任务捕获 `@MainActor` 属性。
    private func prepareUpdate(index: Int, names: [String]) async -> UpdateAttempt {
        await prepareUpdate(named: names[index])
    }

    private func prepareUpdates(names: [String]) async -> [UpdateAttempt] {
        guard !names.isEmpty else { return [] }
        let batchSize = Self.maxConcurrentRuleDownloads
        var results = [UpdateAttempt?](repeating: nil, count: names.count)
        var start = 0
        while start < names.count {
            let end = min(start + batchSize, names.count)
            // 每批内部并发，批与批之间串行，保证同时最多 4 个下载。
            // 注意：不能在 addTask 闭包里写 `@MainActor in`，Swift 6 的
            // region-based isolation 检查器无法分析这种写法（会直接报错），
            // 因此改成在子任务内 await 主 actor 上的方法。
            let batch = await withTaskGroup(of: (Int, UpdateAttempt).self) { group in
                for index in start..<end {
                    group.addTask {
                        (index, await self.prepareUpdate(index: index, names: names))
                    }
                }
                var collected: [(Int, UpdateAttempt)] = []
                collected.reserveCapacity(end - start)
                for await item in group {
                    collected.append(item)
                }
                return collected
            }
            for (index, attempt) in batch {
                results[index] = attempt
            }
            start = end
        }
        return results.compactMap { $0 }
    }
}
