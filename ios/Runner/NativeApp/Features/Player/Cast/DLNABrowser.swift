//
//  DLNABrowser.swift
//  Kazumi
//
//  DLNA 设备发现：**单播**探测，不用 SSDP 组播。
//

import Foundation
import Network
import Observation
import Darwin
import os

/// 一台找到的 DLNA 渲染设备。
struct DLNADevice: Identifiable, Equatable, Sendable {
    var id: String { controlURL.absoluteString }
    let name: String
    let ip: String
    let location: URL
    let controlURL: URL

    var detail: String? { ip }

    /// 下次手动连接可直接使用的地址；HTTP/HTTPS 未显式写端口时补标准端口。
    var reconnectAddress: String {
        let port = location.port ?? controlURL.port ?? (location.scheme?.lowercased() == "https" ? 443 : 80)
        return "\(ip):\(port)"
    }
}

/// 设备发现状态机。一次只跑一轮，收到就往后抛。
@Observable
@MainActor
final class DLNABrowser {
    enum Failure: Equatable {
        case notFound
        case permission

        var symbol: String {
            switch self {
            case .notFound: "wifi.exclamationmark"
            case .permission: "lock.circle"
            }
        }

        var title: String {
            switch self {
            case .notFound: String(localized: "没搜到设备")
            case .permission: String(localized: "没有本地网络权限")
            }
        }

        var message: String {
            switch self {
            case .notFound: String(localized: "确认电视/电脑和手机连的是同一个 Wi-Fi。也可以直接输入 IP 或 IP:端口。")
            case .permission: String(localized: "需要在设置里允许 Kazumi 访问本地网络，才能搜到设备。")
            }
        }

        var allowsRetry: Bool { true }
        var allowsSettings: Bool { self == .permission }
    }

    enum State: Equatable {
        case idle
        case searching
        case found([DLNADevice])
        case failed(Failure)
    }

    private(set) var state: State = .idle
    private(set) var progressText: String?

    private let prober = DLNAUnicastProber()
    private var searchTask: Task<Void, Never>?
    /// 独立保存已发现列表，搜索态切走后手动连接仍能把设备并回原列表。
    private var knownDevices: [DLNADevice] = []
    /// 每次开始、手动连接或停止都换代；较早操作即使晚返回也不能覆盖新状态。
    private var operationGeneration = 0

    func start() {
        guard state != .searching else { return }
        operationGeneration &+= 1
        let generation = operationGeneration
        knownDevices = []
        state = .searching
        progressText = nil
        searchTask = Task { [weak self] in
            await self?.runSearch(generation: generation)
        }
    }

    func restart() {
        stop()
        start()
    }

    func stop() {
        operationGeneration &+= 1
        searchTask?.cancel()
        searchTask = nil
        knownDevices = []
        state = .idle
        progressText = nil
    }

    /// 手动输入电视/电脑 IP（支持 "192.168.1.10"、"192.168.1.10:端口" 或完整 "http://..." 链接）
    func probeIP(_ raw: String) async {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        // 手动连接优先于后台网段扫描；旧扫描即使晚返回也不能盖掉手动结果。
        searchTask?.cancel()
        searchTask = nil
        operationGeneration &+= 1
        let generation = operationGeneration
        state = .searching
        progressText = String(localized: "正在连接 \(input)…")

        let device = await prober.probeSingleInput(input)
        guard !Task.isCancelled, generation == operationGeneration else { return }

        guard let device else {
            state = .failed(.notFound)
            progressText = nil
            return
        }
        knownDevices.removeAll { $0.id == device.id }
        knownDevices.insert(device, at: 0)
        state = .found(knownDevices)
        progressText = nil
    }

    private func runSearch(generation: Int) async {
        // 仅当明确为策略拒绝（PolicyDenied）时才拦截，防止 Info.plist 漏配 Bonjour 导致误杀
        if await LocalNetworkPermission.isExplicitlyDenied() {
            guard generation == operationGeneration else { return }
            state = .failed(.permission)
            progressText = nil
            return
        }
        guard !Task.isCancelled, generation == operationGeneration else { return }

        guard let prefix = Self.wifiSubnetPrefix() else {
            state = .failed(.notFound)
            progressText = nil
            return
        }
        progressText = String(localized: "正在扫描 \(prefix).1~254…")

        let found = await prober.scanSubnet(prefix: prefix)
        guard !Task.isCancelled, generation == operationGeneration else { return }

        knownDevices = found.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        state = knownDevices.isEmpty ? .failed(.notFound) : .found(knownDevices)
        progressText = nil
    }

    /// 本机 Wi-Fi（en0）网段前缀，如 "192.168.31"。
    nonisolated static func wifiSubnetPrefix() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard let addr = interface.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name == "en0" else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(
                addr, socklen_t(addr.pointee.sa_len),
                &hostname, socklen_t(hostname.count),
                nil, socklen_t(0), NI_NUMERICHOST
            )
            address = String(cString: hostname)
        }
        guard let ip = address else { return nil }
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return "\(parts[0]).\(parts[1]).\(parts[2])"
    }
}

// MARK: - 单播扫描引擎

actor DLNAUnicastProber {
    /// 扩充 PC 接收端（Macast / MiniCast / Kodi / Windows 媒体流）与常见电视端口兜底
    private let fallbackTargets: [(port: Int, path: String)] = [
        (1068, "/description.xml"), // Macast 默认
        (8895, "/description.xml"), // MiniCast 常见
        (8895, "/desc.xml"),
        (6060, "/description.xml"),
        (1400, "/description.xml"), // Kodi
        (49152, "/description.xml"),
        (49153, "/description.xml"),
        (49154, "/description.xml"),
        (49152, "/upnp/dev/render/desc.xml"),
        (8200, "/rootDesc.xml"),
        (9080, "/description.xml"),
        (8060, "/dial/dd.xml"),
    ]

    /// 常见描述文件后缀路径（用于用户输入 IP:端口 时遍历）
    private let commonPaths = [
        "/description.xml",
        "/desc.xml",
        "/rootDesc.xml",
        "/upnp/dev/render/desc.xml",
        "/dmr.xml",
        "/"
    ]

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        config.timeoutIntervalForResource = 2.5
        return URLSession(configuration: config)
    }()

    /// 支持 3 种手动输入格式：完整 http URL、"IP:端口"、纯 "IP"
    func probeSingleInput(_ rawInput: String) async -> DLNADevice? {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercaseInput = input.lowercased()

        // 1. 完整 http://... 链接（如直接从 Macast 复制出来的链接）
        if (lowercaseInput.hasPrefix("http://") || lowercaseInput.hasPrefix("https://")),
           let url = URL(string: input),
           let host = url.host {
            if let device = await fetchDescription(from: url, ip: host) {
                return device
            }
        }

        // 2. "IP:端口" 格式（如 "192.168.31.88:54321"）
        let clean: String
        if lowercaseInput.hasPrefix("http://") {
            clean = String(input.dropFirst("http://".count))
        } else if lowercaseInput.hasPrefix("https://") {
            clean = String(input.dropFirst("https://".count))
        } else {
            clean = input
        }
        let hostPort = clean.split(separator: "/", maxSplits: 1).first.map(String.init) ?? clean
        let parts = hostPort.split(separator: ":", omittingEmptySubsequences: false)

        if parts.count == 2 {
            guard !parts[0].isEmpty,
                  let port = Int(parts[1]),
                  (1...65_535).contains(port) else { return nil }
            let ip = String(parts[0])
            return await withTaskGroup(of: DLNADevice?.self) { group in
                for path in commonPaths {
                    group.addTask {
                        guard !Task.isCancelled,
                              let url = URL(string: "http://\(ip):\(port)\(path)") else {
                            return nil
                        }
                        return await self.fetchDescription(from: url, ip: ip)
                    }
                }
                for await device in group {
                    if let device {
                        group.cancelAll()
                        return device
                    }
                }
                return nil
            }
        }

        // 3. 纯 IP 格式：先发多 ST 头的 UDP 1900 单播探测，再扫常见端口兜底
        guard parts.count == 1, let first = parts.first, !first.isEmpty else { return nil }
        let ip = String(first)
        let locations = await unicastMSearch(to: ip, timeout: 1.2)
        if let device = await firstRenderer(in: locations, ip: ip) {
            return device
        }
        return await probeFallbackPorts(ip: ip)
    }

    /// 扫整个 /24，分批并发
    func scanSubnet(prefix: String) async -> [DLNADevice] {
        let ips = (1...254).map { "\(prefix).\($0)" }
        let batchSize = 50
        var found: [String: DLNADevice] = [:]

        for start in stride(from: 0, to: ips.count, by: batchSize) {
            guard !Task.isCancelled else { break }
            let batch = Array(ips[start..<min(start + batchSize, ips.count)])
            await withTaskGroup(of: DLNADevice?.self) { group in
                for ip in batch {
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        return await self.unicastOnly(ip: ip)
                    }
                }
                for await device in group {
                    if Task.isCancelled {
                        group.cancelAll()
                        break
                    }
                    if let device { found[device.id] = device }
                }
            }
        }
        return Array(found.values)
    }

    private func unicastOnly(ip: String) async -> DLNADevice? {
        guard !Task.isCancelled else { return nil }
        let locations = await unicastMSearch(to: ip, timeout: 1.05)
        guard !locations.isEmpty else { return nil }
        if let device = await firstRenderer(in: locations, ip: ip) {
            return device
        }
        guard !Task.isCancelled else { return nil }
        return await probeFallbackPorts(ip: ip)
    }

    private func firstRenderer(in locations: [URL], ip: String) async -> DLNADevice? {
        for location in locations {
            guard !Task.isCancelled else { return nil }
            if let device = await fetchDescription(from: location, ip: ip) {
                return device
            }
        }
        return nil
    }

    private func probeFallbackPorts(ip: String) async -> DLNADevice? {
        await withTaskGroup(of: DLNADevice?.self) { group in
            for target in fallbackTargets {
                group.addTask {
                    guard let url = URL(string: "http://\(ip):\(target.port)\(target.path)") else {
                        return nil
                    }
                    return await self.fetchDescription(from: url, ip: ip)
                }
            }
            for await result in group {
                if let device = result {
                    group.cancelAll()
                    return device
                }
            }
            return nil
        }
    }

    // MARK: 单播 M-SEARCH（多 ST 头连发 + 持续收包过滤）

    private func unicastMSearch(to ip: String, timeout: TimeInterval) async -> [URL] {
        let host = NWEndpoint.Host(ip)
        let port = NWEndpoint.Port(integerLiteral: 1900)
        let connection = NWConnection(host: host, port: port, using: .udp)
        let locations = LocationAccumulator()

        // 同时兼容只认 AVTransport、MediaRenderer 或 ssdp:all 的不同接收端。
        let searchTargets = [
            "urn:schemas-upnp-org:service:AVTransport:1",
            "urn:schemas-upnp-org:device:MediaRenderer:1",
            "ssdp:all"
        ]

        nonisolated(unsafe) let conn = connection
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let finish = Once<[URL]> { value in
                    conn.cancel()
                    continuation.resume(returning: value)
                }

                @Sendable func receiveNext() {
                    conn.receiveMessage { data, _, _, error in
                        if let data,
                           let text = String(data: data, encoding: .utf8),
                           let location = Self.extractLocation(from: text) {
                            // ssdp:all 可能先回媒体服务器或网关；先收齐，再逐一验证描述文件。
                            locations.insert(location)
                        }
                        if error == nil {
                            receiveNext()
                        } else {
                            finish(locations.snapshot())
                        }
                    }
                }

                conn.stateUpdateHandler = { newState in
                    switch newState {
                    case .ready:
                        receiveNext()
                        for st in searchTargets {
                            let payload = "M-SEARCH * HTTP/1.1\r\n"
                                + "HOST: 239.255.255.250:1900\r\n"
                                + "MAN: \"ssdp:discover\"\r\n"
                                + "MX: 1\r\n"
                                + "ST: \(st)\r\n"
                                + "\r\n"
                            conn.send(content: payload.data(using: .utf8), completion: .idempotent)
                        }
                    case .failed, .cancelled:
                        finish(locations.snapshot())
                    default:
                        break
                    }
                }
                conn.start(queue: .global(qos: .userInitiated))

                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    finish(locations.snapshot())
                }
            }
        } onCancel: {
            conn.cancel()
        }
    }

    private static func extractLocation(from response: String) -> URL? {
        // 兼容 "\r\n" 与 "\n" 换行
        for line in response.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.uppercased().hasPrefix("LOCATION:") {
                let value = trimmed.dropFirst("LOCATION:".count)
                    .trimmingCharacters(in: .whitespaces)
                return URL(string: value)
            }
        }
        return nil
    }

    // MARK: 设备描述（强制覆写虚拟网卡 Host）

    private func fetchDescription(from rawLocationURL: URL, ip: String) async -> DLNADevice? {
        // 【关键修复】：如果电脑开了 Tailscale/Clash，SSDP 返回的 LOCATION 可能是 100.x.x.x 或 198.18.x.x，
        // 强制将 URL 的 host 替换为我们实际打通的局域网 IP。
        let locationURL: URL
        if var comp = URLComponents(url: rawLocationURL, resolvingAgainstBaseURL: false) {
            comp.host = ip
            locationURL = comp.url ?? rawLocationURL
        } else {
            locationURL = rawLocationURL
        }

        do {
            let (data, response) = try await session.data(from: locationURL)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let xml = String(data: data, encoding: .utf8),
                  xml.contains("AVTransport") else { return nil }

            let name = Self.xmlTag("friendlyName", in: xml)
                ?? Self.xmlTag("modelName", in: xml)
                ?? String(localized: "DLNA 设备")

            guard let serviceRange = xml.range(of: "urn:schemas-upnp-org:service:AVTransport:1"),
                  let serviceEnd = xml.range(
                    of: "</service>",
                    range: serviceRange.upperBound..<xml.endIndex
                  ) else { return nil }
            let service = String(xml[serviceRange.lowerBound..<serviceEnd.upperBound])
            guard let rawPath = Self.xmlTag("controlURL", in: service) else { return nil }

            let controlURL: URL
            if rawPath.lowercased().hasPrefix("http") {
                guard var comp = URLComponents(string: rawPath) else { return nil }
                comp.host = ip // 同样防止 controlURL 写死虚拟网卡 IP
                guard let url = comp.url else { return nil }
                controlURL = url
            } else {
                // 相对 controlURL 必须按描述文件（或 URLBase）解析，不能一律塞到域名根目录；
                // 例如 /upnp/desc.xml 里的 "ctl/AVTransport" 应落在 /upnp/ctl/AVTransport。
                let declaredBase = Self.xmlTag("URLBase", in: xml).flatMap { URL(string: $0) }
                let baseURL = declaredBase ?? locationURL
                guard let resolved = URL(string: rawPath, relativeTo: baseURL)?.absoluteURL,
                      var components = URLComponents(
                        url: resolved,
                        resolvingAgainstBaseURL: false
                      ) else { return nil }
                components.host = ip
                guard let url = components.url else { return nil }
                controlURL = url
            }
            return DLNADevice(name: name, ip: ip, location: locationURL, controlURL: controlURL)
        } catch {
            return nil
        }
    }

    private static func xmlTag(_ tag: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(tag)>"),
              let end = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex) else {
            return nil
        }
        return String(xml[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class LocationAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: Set<String> = []
    private var values: [URL] = []

    func insert(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard seen.insert(url.absoluteString).inserted else { return }
        values.append(url)
    }

    func snapshot() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class Once<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let body: @Sendable (Value) -> Void
    private var done = false

    init(_ body: @Sendable @escaping (Value) -> Void) { self.body = body }

    func callAsFunction(_ value: Value) {
        lock.lock()
        guard !done else {
            lock.unlock()
            return
        }
        done = true
        lock.unlock()
        body(value)
    }
}

// MARK: - 本地网络权限检查（防误杀优化）

private enum LocalNetworkPermission {
    /// 只有当系统明确返回 PolicyDenied / NotPermitted 时才判定为无权限；
    /// 避免因 Info.plist 未声明 _dlna._tcp 导致误报无权限。
    static func isExplicitlyDenied() async -> Bool {
        await withCheckedContinuation { continuation in
            let state = ProbeState()
            let descriptor = NWBrowser.Descriptor.bonjour(type: "_airplay._tcp", domain: nil)
            let browser = NWBrowser(for: descriptor, using: NWParameters())
            browser.stateUpdateHandler = { browserState in
                switch browserState {
                case .ready:
                    guard state.claim() else { return }
                    browser.cancel()
                    continuation.resume(returning: false)
                case .waiting(let error), .failed(let error):
                    guard state.claim() else { return }
                    browser.cancel()
                    continuation.resume(returning: error.isLocalNetworkDenied)
                default:
                    break
                }
            }
            browser.start(queue: .global(qos: .userInitiated))
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                guard state.claim() else { return }
                browser.cancel()
                continuation.resume(returning: false)
            }
        }
    }

    private final class ProbeState: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: false)
        func claim() -> Bool {
            lock.withLock { claimed in
                guard !claimed else { return false }
                claimed = true
                return true
            }
        }
    }
}

private extension NWError {
    var isLocalNetworkDenied: Bool {
        if case .dns(let code) = self {
            // dns_sd.h：PolicyDenied = -65570，NotPermitted = -65571。
            return code == -65570 || code == -65571
        }
        return false
    }
}
