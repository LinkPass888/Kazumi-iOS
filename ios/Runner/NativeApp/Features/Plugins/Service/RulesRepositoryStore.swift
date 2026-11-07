//
//  RulesRepositoryStore.swift
//  Kazumi
//
//  自定义规则仓库（design-repo.md）：内置仓库不可删，自定义仓库是一个列表。
//
//  与旧的单条 `KazumiEndpoints.customPluginShop` 的关系：
//  列表里**第一条**就是当前生效的仓库，写回 `customPluginShop` 给规则目录加载用。
//  列表为空时回落到官方仓库（KazumiRules）。这样目录加载那条链路一行不用改。
//

import Foundation
import os

/// 一个规则仓库。
struct RulesRepository: Identifiable, Equatable, Sendable, Codable {
    let id: String
    /// 仓库地址（https）。
    let url: String
    /// 预览时拿到的仓库名；还没预览过就是 nil。
    var name: String?
    /// 预览时拿到的规则数。
    var ruleCount: Int?

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return URL(string: url)?.host ?? url
    }
}

@Observable
@MainActor
final class RulesRepositoryStore {
    /// 官方仓库的展示信息（内置、不可删）。
    static let builtInName = "KazumiRules"
    static let builtInURL = "https://raw.githubusercontent.com/Predidit/KazumiRules/main/index.json"

    private static let storageKey = "customRulesRepositories"

    private(set) var custom: [RulesRepository]

    init() {
        // 只读 UserDefaults；@State 会在 MainActor 上建这个实例。
        custom = Self.load()
    }

    /// 首次进面板时把列表第一条同步给规则目录那条链路。
    func activate() {
        syncActive()
    }

    /// 当前生效的自定义仓库；nil 就是走官方仓库。
    var active: RulesRepository? { custom.first }

    func add(_ repository: RulesRepository) {
        // 新加的排最前：加完立刻生效，列表第一行也就是「正在用」的那条。
        custom.removeAll { $0.url == repository.url }
        custom.insert(repository, at: 0)
        persist()
    }

    func remove(_ repository: RulesRepository) {
        custom.removeAll { $0.id == repository.id }
        persist()
    }

    func updatePreview(name: String?, ruleCount: Int?, for url: String) {
        guard let index = custom.firstIndex(where: { $0.url == url }) else { return }
        custom[index].name = name
        custom[index].ruleCount = ruleCount
        persist()
    }

    // MARK: 落盘

    private func persist() {
        syncActive()
        guard let data = try? JSONEncoder().encode(custom) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    /// 列表第一条写回 `customPluginShop`：规则目录那条链路读的是它。
    private func syncActive() {
        KazumiEndpoints.setCustomPluginShop(custom.first?.url)
    }

    private static func load() -> [RulesRepository] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let list = try? JSONDecoder().decode([RulesRepository].self, from: data) else {
            // 从旧版单条地址迁移过来：老用户填过的那条还在，别丢。
            if let legacy = KazumiEndpoints.customPluginShop {
                return [RulesRepository(id: legacy, url: legacy)]
            }
            return []
        }
        return list
    }
}

// MARK: - 预览

/// 加仓库前的预览：拉一次地址、按规则目录格式解析。
///
/// 失败只说「连不上」或「不是规则仓库」（Camo 7719 定稿），不细分 404 / 超时 /
/// JSON 解析错 / 证书错。
enum RulesRepositoryPreview {
    struct Result: Sendable {
        var name: String
        var ruleCount: Int
    }

    enum Failure: Error {
        case connection
        case notARepository
    }

    static func fetch(url: String) async throws -> Result {
        guard let parsed = URL(string: url), parsed.scheme?.lowercased() == "https" else {
            throw Failure.notARepository
        }
        var request = URLRequest(url: parsed)
        request.timeoutInterval = 12
        request.setValue(HTTPHeaders.randomUserAgent(), forHTTPHeaderField: "user-agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.connection
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure.connection
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw Failure.notARepository
        }

        do {
            let catalog = try PluginCatalogParser.parse(text)
            guard !catalog.items.isEmpty else { throw Failure.notARepository }
            // 规则仓库的 index.json 没有「仓库名」这个字段，用域名当名字；
            // 不造固定句（design-repo.md §3.3）。
            return Result(name: parsed.host ?? url, ruleCount: catalog.items.count)
        } catch {
            throw Failure.notARepository
        }
    }
}
