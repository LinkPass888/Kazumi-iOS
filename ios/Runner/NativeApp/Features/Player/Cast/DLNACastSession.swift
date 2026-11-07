//
//  DLNACastSession.swift
//  Kazumi
//
//  DLNA 投屏会话：SetAVTransportURI → Play / Pause / Seek / Stop，走 SOAP。
//
//  重要边界（design-cast.md §1.4）：电视自己取流，本机 mpv 的 UA / Referer / Cookie
//  带不过去；要这些头的片源会投不上。这里不做中转转码。
//

import Foundation
import os

@Observable
@MainActor
final class DLNACastSession {
    private(set) var isCasting = false
    private(set) var isPlaying = false
    private(set) var connectingDeviceID: String?
    private(set) var deviceName: String?

    private var device: DLNADevice?

    /// 连上电视并开始播。抛错就是投不出去（多为片源需要 Referer／Cookie）。
    func start(device: DLNADevice, mediaURL: URL) async throws {
        let control = device.controlURL
        connectingDeviceID = device.id
        defer { connectingDeviceID = nil }

        try await send(
            action: "SetAVTransportURI",
            to: control,
            arguments: [
                ("InstanceID", "0"),
                ("CurrentURI", mediaURL.absoluteString),
                (
                    "CurrentURIMetaData",
                    didlMetadata(url: mediaURL, title: deviceName ?? mediaURL.lastPathComponent)
                ),
            ]
        )
        try await send(action: "Play", to: control, arguments: [
            ("InstanceID", "0"),
            ("Speed", "1"),
        ])

        self.device = device
        deviceName = device.name
        isPlaying = true
        isCasting = true
    }

    func play() {
        guard let control = device?.controlURL else { return }
        isPlaying = true
        Task {
            try? await send(action: "Play", to: control, arguments: [
                ("InstanceID", "0"),
                ("Speed", "1"),
            ])
        }
    }

    func pause() {
        guard let control = device?.controlURL else { return }
        isPlaying = false
        Task {
            try? await send(action: "Pause", to: control, arguments: [("InstanceID", "0")])
        }
    }

    func seek(to seconds: Double) {
        guard let control = device?.controlURL else { return }
        let stamp = Self.timeStamp(seconds)
        Task {
            try? await send(action: "Seek", to: control, arguments: [
                ("InstanceID", "0"),
                ("Unit", "REL_TIME"),
                ("Target", stamp),
            ])
        }
    }

    func stop() async {
        if let control = device?.controlURL {
            try? await send(action: "Stop", to: control, arguments: [("InstanceID", "0")])
        }
        device = nil
        deviceName = nil
        isCasting = false
        isPlaying = false
    }

    // MARK: SOAP

    private func send(
        action: String,
        to controlURL: URL,
        arguments: [(String, String)]
    ) async throws {
        let body = soapBody(action: action, arguments: arguments)
        var request = URLRequest(url: controlURL)
        request.httpMethod = "POST"
        request.httpBody = body.data(using: .utf8)
        request.timeoutInterval = 8
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "\"urn:schemas-upnp-org:service:AVTransport:1#\(action)\"",
            forHTTPHeaderField: "SOAPACTION"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? ""
            KazumiLog.cast.error("DLNA \(action) 失败 \(http.statusCode): \(text, privacy: .public)")
            throw DLNAError.soapFailed(http.statusCode)
        }
    }

    private func soapBody(action: String, arguments: [(String, String)]) -> String {
        let args = arguments
            .map { "<\($0.0)>\(Self.escape($0.1))</\($0.0)>" }
            .joined()
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body>
        <u:\(action) xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">\(args)</u:\(action)>
        </s:Body>
        </s:Envelope>
        """
    }

    /// DIDL-Lite 元数据：很多电视没有它就不认地址。
    private func didlMetadata(url: URL, title: String) -> String {
        let escapedURL = Self.escape(url.absoluteString)
        let escapedTitle = Self.escape(title)
        return """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" \
        xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
        <item id="0" parentID="-1" restricted="1">
        <dc:title>\(escapedTitle)</dc:title>
        <upnp:class>object.item.videoItem</upnp:class>
        <res protocolInfo="http-get:*:video/mp4:*">\(escapedURL)</res>
        </item>
        </DIDL-Lite>
        """
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// AVTransport 的时间格式：H:MM:SS。
    private static func timeStamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

enum DLNAError: LocalizedError {
    case soapFailed(Int)

    var errorDescription: String? {
        switch self {
        case .soapFailed(let status): String(localized: "电视拒绝了这次投屏（\(status)）")
        }
    }
}
