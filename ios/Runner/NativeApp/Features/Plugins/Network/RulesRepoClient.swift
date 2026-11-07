//
//  RulesRepoClient.swift
//  Kazumi
//
//  1:1 翻译 lib/request/clients/rules_repo_client.dart 与 dio_factory.dart 中的
//  _RulesMirrorInterceptor：规则目录默认走 raw.githubusercontent.com，
//  按「规则仓库加速」的选择改写前缀（上游 2.4.1 起从开关改成四选一）。
//

import Foundation
import os

enum KazumiEndpoints {
    static let officialPluginShop = "https://raw.githubusercontent.com/Predidit/KazumiRules/main/"
    private static let customPluginShopKey = "customRulesRepositoryURL"

    static var customPluginShop: String? {
        let value = UserDefaults.standard.string(forKey: customPluginShopKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    static var pluginShop: String {
        guard let customPluginShop,
              let url = URL(string: customPluginShop) else { return officialPluginShop }
        if url.pathExtension.lowercased() == "json" {
            let root = url.deletingLastPathComponent().absoluteString
            return root.hasSuffix("/") ? root : root + "/"
        }
        return url.absoluteString.hasSuffix("/") ? url.absoluteString : url.absoluteString + "/"
    }

    static var pluginShopIndex: String {
        guard let customPluginShop,
              let url = URL(string: customPluginShop) else { return officialPluginShop + "index.json" }
        return url.pathExtension.lowercased() == "json"
            ? url.absoluteString
            : url.appendingPathComponent("index.json").absoluteString
    }

    static func setCustomPluginShop(_ value: String?) {
        if let value, !value.isEmpty {
            UserDefaults.standard.set(value, forKey: customPluginShopKey)
        } else {
            UserDefaults.standard.removeObject(forKey: customPluginShopKey)
        }
    }

    /// 规则仓库镜像。gh-proxy 和 ghfast 是「前缀 + 完整原地址」，
    /// GitCode 是「换掉域名后那段」。
    static let ghProxyMirror = "https://gh-proxy.org/"
    static let ghfastMirror = "https://ghfast.top/"
    static let gitcodeMirror = "https://raw.gitcode.com/gh_mirrors/ka/KazumiRules/raw/main/"
}

/// 规则仓库加速方式（对应上游 `enableGitProxy` 之后的四选一）。
enum RulesMirror: String, Sendable, CaseIterable {
    case ghProxy
    case ghfast
    case gitcode
    case direct

    var shortTitle: String {
        switch self {
        case .ghProxy: "gh-proxy"
        case .ghfast: "ghfast"
        case .gitcode: "GitCode"
        case .direct: String(localized: "直连")
        }
    }

    /// 展开后跟在名字后面的说明（13 pt 灰字）。
    var note: String {
        switch self {
        case .ghProxy: String(localized: "默认镜像")
        case .ghfast: String(localized: "备用镜像")
        case .gitcode: String(localized: "国内镜像")
        case .direct: String(localized: "不走镜像")
        }
    }
}

final class RulesRepoClient: Sendable {
    static let shared = RulesRepoClient()

    /// 由设置页写入；仅影响后续请求，与 interceptor 的即时读取行为一致。
    static let mirror = OSAllocatedUnfairLock(initialState: RulesMirror.ghProxy)

    private let sessionProvider: ProxyAwareURLSession

    /// 代理变了就重建，见 `ProxyAwareURLSession`。
    private var session: URLSession { sessionProvider.session }

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 24
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionProvider = ProxyAwareURLSession {
            KazumiNetworkPolicy.applyProxy(to: config)
            return config
        }
    }

    /// 对应 RulesRepoClient.instance.getText。
    func getText(_ url: String) async throws -> String {
        let finalURL = Self.mirrored(url)
        var request = URLRequest(url: URL(string: finalURL) ?? URL(string: url) ?? KazumiAppInfo.projectURL)
        request.httpMethod = "GET"
        request.setValue(HTTPHeaders.randomUserAgent(), forHTTPHeaderField: "user-agent")
        KazumiLog.network.debug("Rules repo GET \(finalURL, privacy: .public)")
        do {
            let (data, response) = try await session.data(for: request)
            let body = String(data: data, encoding: .utf8) ?? ""
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw NetworkError.badResponse(status: http.statusCode, body: body, headers: [:]) 
            }
            return body
        } catch let error as URLError {
            if error.code == .cancelled { throw NetworkError.cancelled }
            throw NetworkError.transport(error.localizedDescription)
        }
    }

    /// 对应 _RulesMirrorInterceptor：只改写规则仓库前缀。
    static func mirrored(_ url: String) -> String {
        mirrored(url, mirror: Self.mirror.withLock { $0 })
    }

    /// 按指定镜像改写；测速也走这里，保证测的就是实际会用的地址。
    static func mirrored(_ url: String, mirror: RulesMirror) -> String {
        guard mirror != .direct,
              url.hasPrefix(KazumiEndpoints.officialPluginShop) else { return url }
        let path = url.dropFirst(KazumiEndpoints.officialPluginShop.count)
        switch mirror {
        case .ghProxy: return KazumiEndpoints.ghProxyMirror + url
        case .ghfast: return KazumiEndpoints.ghfastMirror + url
        case .gitcode: return KazumiEndpoints.gitcodeMirror + path
        case .direct: return url
        }
    }

    /// 测这条镜像通不通、往返多少毫秒：只取规则列表文件的开头，3 秒不上就算不通。
    func measureLatency(for mirror: RulesMirror) async -> Int? {
        let urlString = Self.mirrored(KazumiEndpoints.officialPluginShop + "index.json", mirror: mirror)
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("bytes=0-0", forHTTPHeaderField: "range")
        request.setValue(HTTPHeaders.randomUserAgent(), forHTTPHeaderField: "user-agent")
        request.timeoutInterval = 3
        let start = Date()
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<400).contains(http.statusCode) else { return nil }
            return Int(Date().timeIntervalSince(start) * 1000)
        } catch {
            return nil
        }
    }
}
