//
//  PluginCatalogAPI.swift
//  Kazumi
//
//  1:1 翻译 lib/request/apis/plugin_catalog_api.dart。
//

import Foundation

struct PluginCatalogAPI: Sendable {
    let client: RulesRepoClient

    init(client: RulesRepoClient = .shared) {
        self.client = client
    }

    /// 对应 getPluginList：解析成功的条目之外，跳过数量会写入日志。
    func getPluginList() async throws -> [PluginHTTPItem] {
        let raw = try await client.getText(KazumiEndpoints.pluginShopIndex)
        let result = try PluginCatalogParser.parse(raw)
        if result.skippedItems > 0 {
            KazumiLog.plugin.warning("Plugin: skipped \(result.skippedItems) invalid rule catalog item(s)")
        }
        return result.items
    }

    /// 对应 getPlugin(name)：目录里的规则文件必须是 JSON object。
    func getPlugin(name: String) async throws -> Plugin {
        let raw = try await client.getText(KazumiEndpoints.pluginShop + name + ".json")
        let decoded = try JSONValue.decode(raw)
        guard decoded.objectValue != nil else {
            throw CatalogError.invalidItem
        }
        return Plugin(json: decoded)
    }
}
