//
//  DLNABrowser.swift
//  Kazumi
//
//  DLNA 设备发现：**单播**探测，不用 SSDP 组播。
//
//  为什么不上组播：这是不上架的侧载应用，拿不到
//  `com.apple.developer.networking.multicast` 签名能力。组播 M-SEARCH 发到
//  239.255.255.250 需要那个能力，侧载账号批不下来。改成对本机 Wi-Fi 网段
//  逐个发单播 M-SEARCH（UDP 到每个 IP:1900）＋常见端口的描述文件兜底，
//  全是普通单播 HTTP/UDP，`NSAllowsLocalNetworking` 就够。
//
//  另外支持手动输入电视 IP 精准探测，网段扫不到时给一条明路。
//

import Foundation
import Network
import Darwin
import os

/// 一台找到的 DLNA 渲染设备。
struct DLNADevice: Identifiable, Equatable, Sendable {
    var id: String { controlURL.absoluteString }
    let name: String
    let ip: String
    let location: URL
    let controlURL: URL

    /// 设备区那一行的副文：单播方案里 IP 比型号更有用（同一台可能多个端口）。
    var detail: String? { ip }
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
            case .notFound: String(localized: "确认电视和手机连的是同一个 Wi-Fi。也可以直接输入电视的 IP。")
            case .permission: String(localized: "需要在设置里允许 Kazumi 访问本地网络，才能搜到电视。")
            }
        }

        var allowsRetry: Bool { self == .notFound }
        var allowsSettings: Bool { self == .permission }
    }

    enum State {
        case idle
        case searching
        case found([DLNADevice])
        case failed(Failure)
    }

    private(set) var state: State = .idle
    /// 一轮扫描的进度提示（设备区搜索态那行字）。
    private(set) var progressText: String?

    private let prober = DLNAUnicastProber()
    private var searchTask: Task<Void, Never>?

    func start() {
        guard state != .searching else { return }
        state = .searching
        progressText = nil
        searchTask = Task { [weak self] in
            await self?.runSearch()
        }
    }

    func restart() {
        stop()
        start()
    }

    func stop() {
        searchTask?.cancel()
        searchTask = nil
        state = .idle
        progressText = nil
    }

    /// 手动输入电视 IP，精准探测一次。命中就并进列表并置顶。
    func probeIP(_ raw: String) async {
        let ip = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ip.isEmpty else { return }
        state = .searching
        progressText = String(localized: "正在连接 \(ip)…")

        let device = await prober.probeSingleIP(ip)
        guard !Task.isCancelled else { return }

        guard let device else {
            state = .failed(.notFound)
            return
        }
        var devices = currentDevices
        devices.removeAll { $0.id == device.id }
        devices.insert(device, at: 0)
        state = .found(devices)
    }

    private var currentDevices: [DLNADevice] {
        if case .found(let devices) = state { return devices }
        return []
    }

    private func runSearch() async {
        guard await LocalNetworkPermission.probe() else {
            state = .failed(.permission)
            return
        }
        guard !Task.isCancelled else { return }

        guard let prefix = Self.wifiSubnetPrefix() else {
            state = .failed(.notFound)
            return
        }
        progressText = String(localized: "正在扫描 \(prefix).1~254…")

        let found = await prober.scanSubnet(prefix: prefix)
        guard !Task.isCancelled else { return }

        let devices = found.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        state = devices.isEmpty ? .failed(.notFound) : .found(devices)
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

/// 纯网络层，actor 隔离，跑在后台；不碰任何 UI 状态。
actor DLNAUnicastProber {
    /// 单播 M-SEARCH 没回应时，直接试这些常见端口的描述文件。
    /// 国产电视／盒子很多不回单播 M-SEARCH，但描述文件是标准 HTTP，能直接取。
    private let fallbackTargets: [(port: Int, path: String)] = [
        (49152, "/description.xml"),
        (49153, "/description.xml"),
        (49154, "/description.xml"),
        (49152, "/upnp/dev/render/desc.xml"),
        (1400, "/description.xml"),
        (8200, "/rootDesc.xml"),
        (9080, "/description.xml"),
        (8060, "/dial/dd.xml"),
        (1068, "/description.xml"),
    ]

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.2
        config.timeoutIntervalForResource = 2.0
        return URLSession(configuration: config)
    }()

    func probeSingleIP(_ ip: String) async -> DLNADevice? {
        if let location = await unicastMSearch(to: ip, timeout: 1.0),
           let device = await fetchDescription(from: location, ip: ip) {
            return device
        }
        return await probeFallbackPorts(ip: ip)
    }

    /// 扫整个 /24，分批并发，别一次开 254 条连接。
    func scanSubnet(prefix: String) async -> [DLNADevice] {
        let ips = (1...254).map { "\(prefix).\($0)" }
        let batchSize = 50
        var found: [String: DLNADevice] = [:]

        for start in stride(from: 0, to: ips.count, by: batchSize) {
            let batch = Array(ips[start..<min(start + batchSize, ips.count)])
            await withTaskGroup(of: DLNADevice?.self) { group in
                for ip in batch {
                    group.addTask {
                        await self.unicastOnly(ip: ip)
                    }
                }
                for await device in group {
                    if let device { found[device.id] = device }
                }
            }
        }
        return Array(found.values)
    }

    /// 网段扫描只发单播 M-SEARCH，不做端口兜底（254 × 9 太吵）；
    /// 兜底留给手填 IP 那条路。
    private func unicastOnly(ip: String) async -> DLNADevice? {
        guard let location = await unicastMSearch(to: ip, timeout: 0.55) else { return nil }
        return await fetchDescription(from: location, ip: ip)
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

    // MARK: 单播 M-SEARCH

    private func unicastMSearch(to ip: String, timeout: TimeInterval) async -> URL? {
        let host = NWEndpoint.Host(ip)
        let port = NWEndpoint.Port(integerLiteral: 1900)
        let connection = NWConnection(host: host, port: port, using: .udp)

        let payload = "M-SEARCH * HTTP/1.1\r\n"
            + "HOST: 239.255.255.250:1900\r\n"
            + "MAN: \"ssdp:discover\"\r\n"
            + "MX: 1\r\n"
            + "ST: urn:schemas-upnp-org:service:AVTransport:1\r\n"
            + "\r\n"

        // NWConnection 与 continuation 都不是 Sendable，但整段只在本地用、
        // 且由 Once 保证只跑一次；Swift 6 严格并发下需要显式 nonisolated(unsafe)。
        nonisolated(unsafe) let conn = connection
        return await withCheckedContinuation { continuation in
            // 一个 closure 管住所有出口：状态回调、发送失败、收到响应、超时
            // 都可能先到，只让第一个真正 resume，顺手把连接收掉。
            nonisolated(unsafe) let cont = continuation
            let finish = Once<URL?> { value in
                conn.cancel()
                cont.resume(returning: value)
            }
            connection.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    connection.send(content: payload.data(using: .utf8),
                                    completion: .contentProcessed { error in
                        if error != nil { finish(nil) }
                    })
                    connection.receiveMessage { data, _, _, _ in
                        var location: URL?
                        if let data, let text = String(data: data, encoding: .utf8) {
                            location = Self.extractLocation(from: text)
                        }
                        finish(location)
                    }
                case .waiting, .failed:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))

            // 超时必须收口：绝大多数 IP 不会回。
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(nil)
            }
        }
    }

    private static func extractLocation(from response: String) -> URL? {
        for line in response.components(separatedBy: "\r\n") {
            if line.uppercased().hasPrefix("LOCATION:") {
                let value = line.dropFirst("LOCATION:".count)
                    .trimmingCharacters(in: .whitespaces)
                return URL(string: value)
            }
        }
        return nil
    }

    // MARK: 设备描述

    private func fetchDescription(from locationURL: URL, ip: String) async -> DLNADevice? {
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
                guard let url = URL(string: rawPath) else { return nil }
                controlURL = url
            } else {
                guard var components = URLComponents(url: locationURL,
                                                     resolvingAgainstBaseURL: false) else { return nil }
                components.path = rawPath.hasPrefix("/") ? rawPath : "/" + rawPath
                components.query = nil
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

/// 一次性回调：并发来的多个出口只跑第一个。
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

// MARK: - 本地网络权限

/// 本地网络权限探测：起一次极短的 Bonjour 浏览，只为触发系统授权弹窗并判断
/// 是否「被拒」。Bonjour 走普通单播 DNS，**不需要 multicast 签名能力**。
private enum LocalNetworkPermission {
    static func probe() async -> Bool {
        await withCheckedContinuation { continuation in
            let state = ProbeState()
            let descriptor = NWBrowser.Descriptor.bonjour(type: "_dlna._tcp", domain: nil)
            let browser = NWBrowser(for: descriptor, using: NWParameters())
            browser.stateUpdateHandler = { browserState in
                switch browserState {
                case .ready:
                    guard state.claim() else { return }
                    browser.cancel()
                    continuation.resume(returning: true)
                case .waiting(let error), .failed(let error):
                    guard state.claim() else { return }
                    browser.cancel()
                    continuation.resume(returning: !error.isLocalNetworkDenied)
                default:
                    break
                }
            }
            browser.start(queue: .global(qos: .userInitiated))
            Task {
                try? await Task.sleep(for: .seconds(8))
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
            return code == -65554 // kDNSServiceErr_PolicyDenied
        }
        return false
    }
}
