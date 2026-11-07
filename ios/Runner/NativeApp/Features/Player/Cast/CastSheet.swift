//
//  CastSheet.swift
//  Kazumi
//
//  投屏弹窗（design-cast.md 定稿版式）。
//
//  一颗 sheet 里两颗并列的方式选择卡（AirPlay / DLNA），选中态靠 2 pt 强调色描边
//  ＋勾选符号区分；卡片下方是随选中方式切换的设备区；再往下两条常驻限制说明和完成键。
//  搜索中／设备列表／投屏中／四类失败全在同一块设备区里换内容，不新增导航层级。
//
//  字位：本文件用 Camo 7719 的简中占位字（design-cast.md §3.3 的字位表），
//  繁中本地化随 Localizable.xcstrings 走。
//

import SwiftUI
import UIKit
import AVKit

// MARK: - 方式

/// 投屏方式：AirPlay 走系统 AVRoutePickerView，DLNA 走 app 自己的 SSDP 发现。
enum CastMethod: String, CaseIterable, Identifiable {
    case airPlay
    case dlna

    var id: String { rawValue }

    /// 方式卡标题（字位 B1 / B2）。
    var title: String {
        switch self {
        case .airPlay: String(localized: "AirPlay")
        case .dlna: String(localized: "DLNA")
        }
    }

    /// 方式卡的一句用途（字位 S1 / S2）。
    ///
    /// AirPlay 卡不放 AirPlay 图标（HIG：不要在自定义按钮里用 AirPlay 图标／名字），
    /// 所以符号用 `tv`；真正发起 AirPlay 的是设备区里那个系统控件。
    var summary: String {
        switch self {
        case .airPlay: String(localized: "转到 Apple TV 或支持隔空播放的电视")
        case .dlna: String(localized: "转到同一网络里的电视或盒子")
        }
    }

    /// 方式卡符号。两张卡都用「设备」语义的符号，不用 AirPlay 图标
    /// （HIG：不要在自定义按钮里用 AirPlay 图标或名字）。
    /// 两卡靠文字与边界辨识，不靠技术图标。
    var symbol: String {
        switch self {
        case .airPlay: "tv"
        case .dlna: "rectangle.connected.to.line.below"
        }
    }
}

// MARK: - 弹窗

struct CastSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(SettingsStore.self) private var settings

    /// 这一集的媒体地址；nil 就是还没解析出来。
    let mediaURL: String?
    /// 本机播放控制：投屏期间手机当遥控器，本机不再出声。
    let onPlay: () -> Void
    let onPause: () -> Void
    let onSeek: (Double) -> Void
    let position: Double
    let duration: Double

    @State private var method: CastMethod = .airPlay
    @State private var browser = DLNABrowser()
    @State private var session = DLNACastSession()
    @State private var banner: KazumiBannerState?
    /// 手动输入电视 IP：网段扫不到时给一条明路。
    @State private var manualIP = ""

    private var spacing: CGFloat { 16 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: spacing) {
                    methodPicker

                    deviceArea

                    limitationRow(
                        String(localized: "电视自己取流，本机的 UA、Referer、Cookie 带不过去；要这些头的片源会投不上。")
                    )
                    limitationRow(
                        String(localized: "弹幕、超分、片头片尾跳过、本地字幕只在本机生效。")
                    )
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .background(KazumiPalette.groupedBackground(for: colorScheme).ignoresSafeArea())
            // Banner 放在导航栏下面，别盖住居中的标题和右上角关闭按钮。
            .overlay(alignment: .top) {
                if let banner {
                    KazumiBanner(
                        title: banner.title,
                        detail: banner.detail,
                        variant: banner.variant,
                        onDismiss: { withAnimation(.snappy) { self.banner = nil } }
                    )
                }
            }
            .navigationTitle("远程投屏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(Color.primary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("关闭")
                }
            }
        }
        .presentationDetents([.height(420), .medium, .large])
        .presentationBackground(KazumiPalette.groupedBackground(for: colorScheme))
        .onAppear {
            if manualIP.isEmpty {
                manualIP = settings.lastDLNAAddress
            }
            // DLNA 一进来就开搜，切过去就有列表；AirPlay 不用搜。
            if method == .dlna { browser.start() }
        }
        .onDisappear {
            browser.stop()
        }
        .onChange(of: method) { _, newValue in
            if newValue == .dlna {
                browser.start()
            } else {
                browser.stop()
            }
        }
    }

    // MARK: 方式卡

    private var methodPicker: some View {
        HStack(spacing: 12) {
            ForEach(CastMethod.allCases) { item in
                methodCard(item)
            }
        }
    }

    private func methodCard(_ item: CastMethod) -> some View {
        let isSelected = method == item
        let accent = KazumiPalette.accent(for: colorScheme)
        return Button {
            guard !session.isCasting else { return }
            animate { method = item }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: item.symbol)
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(accent)
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Text(item.summary)
                    .font(.footnote)
                    .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 96)
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: KazumiPalette.cardCornerRadius, style: .continuous)
                    .fill(KazumiPalette.groupedRow(for: colorScheme))
            }
            .overlay {
                RoundedRectangle(cornerRadius: KazumiPalette.cardCornerRadius, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.12) : .clear)
            }
            .overlay {
                // 选中：2 pt 强调色；未选：0.5 pt 发丝描边。
                RoundedRectangle(cornerRadius: KazumiPalette.cardCornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected ? accent : KazumiPalette.cardStroke(for: colorScheme),
                        lineWidth: isSelected ? 2 : 0.5
                    )
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(accent)
                        .padding(8)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: KazumiPalette.cardCornerRadius))
        }
        .buttonStyle(.plain)
        .disabled(session.isCasting)
        .opacity(session.isCasting ? 0.5 : 1)
        .accessibilityLabel(item.title)
        .accessibilityHint(item.summary)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: 设备区

    @ViewBuilder
    private var deviceArea: some View {
        if session.isCasting {
            remoteArea
        } else {
            switch method {
            case .airPlay: airPlayArea
            case .dlna: dlnaArea
            }
        }
    }

    // MARK: AirPlay

    private var airPlayArea: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("在系统列表里选设备")
                    .font(.footnote)
                    .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                Text("当前选中 AirPlay")
                    .font(.footnote)
                    .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
            }
            Spacer(minLength: 0)
            // 系统控件本身只是图标，外面这层实底＋描边是「这是一颗按钮」的形状线索。
            AirPlayRoutePicker(tint: KazumiPalette.accent(for: colorScheme))
                .frame(width: 44, height: 44)
                .frame(width: 56, height: 56)
                .background {
                    RoundedRectangle(cornerRadius: KazumiPalette.posterCornerRadius, style: .continuous)
                        .fill(KazumiPalette.groupedRow(for: colorScheme))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: KazumiPalette.posterCornerRadius, style: .continuous)
                        .strokeBorder(KazumiPalette.cardStroke(for: colorScheme), lineWidth: 1)
                }
        }
        .padding(16)
        .frame(minHeight: 88)
        .background(deviceBackground)
    }

    // MARK: DLNA

    /// 设备区始终带一条「手填 IP」：侧载拿不到组播权限，网段扫描有可能漏，
    /// 得给用户一条明确的路。
    private var dlnaArea: some View {
        VStack(alignment: .leading, spacing: 12) {
            dlnaState
            manualIPRow
        }
        .padding(16)
        .frame(minHeight: 140, alignment: .top)
        .background(deviceBackground)
    }

    @ViewBuilder
    private var dlnaState: some View {
        switch browser.state {
        case .idle, .searching:
            searchingView
        case .found(let devices):
            if devices.isEmpty { searchingView } else { deviceList(devices) }
        case .failed(let failure):
            failureView(failure)
        }
    }

    private var searchingView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(browser.progressText ?? "正在搜索同一网络里的设备…")
                .font(.footnote)
                .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 96)
    }

    private func deviceList(_ devices: [DLNADevice]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("同网络的设备")
                .font(.footnote)
                .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))

            VStack(spacing: 0) {
                ForEach(Array(devices.prefix(4).enumerated()), id: \.element.id) { index, device in
                    if index > 0 {
                        Divider()
                            .padding(.leading, 50)
                    }
                    Button {
                        castTo(device)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "tv")
                                .font(.system(size: 22, weight: .regular))
                                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                    .font(.body)
                                    .foregroundStyle(Color.primary)
                                    .lineLimit(1)
                                if let detail = device.detail {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            if session.connectingDeviceID == device.id {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                            }
                        }
                        .frame(minHeight: 56)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(session.connectingDeviceID != nil)
                }
            }
        }
        .frame(minHeight: 140, alignment: .top)
    }

    private func failureView(_ failure: DLNABrowser.Failure) -> some View {
        VStack(spacing: 8) {
            Image(systemName: failure.symbol)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
            Text(failure.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.primary)
                .multilineTextAlignment(.center)
            Text(failure.message)
                .font(.footnote)
                .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                .multilineTextAlignment(.center)
                .lineLimit(3)
            HStack(spacing: 12) {
                if failure.allowsRetry {
                    outlinedButton("重试") { browser.restart() }
                }
                if failure.allowsSettings {
                    outlinedButton("打开设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
    }

    /// 手填 IP 那一行：输入框 + 「连接」，命中就并进设备列表。
    private var manualIPRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("扫不到？直接输入电视 IP")
                .font(.footnote)
                .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
            HStack(spacing: 8) {
                TextField("192.168.31.88:8895", text: $manualIP)
                    .font(.footnote)
                    // 端口要连冒号一起打出来，数字键盘上没有冒号。
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 8)
                    .frame(height: 36)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(uiColor: .quaternaryLabel).opacity(0.12))
                    }
                Button("连接") {
                    Task { await browser.probeIP(manualIP) }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                .frame(minHeight: 44)
                .disabled(manualIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: 投屏中（手机是遥控器）

    private var remoteArea: some View {
        VStack(spacing: 12) {
            Text("投屏中 · 手机是遥控器")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.primary)
            Text("本机不再出画面和声音")
                .font(.footnote)
                .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))

            HStack(spacing: 12) {
                // 遥控器按的是电视那头：状态取投屏会话，不是本机 mpv。
                remoteKey(session.isPlaying ? "pause.fill" : "play.fill", highlighted: true) {
                    if session.isPlaying {
                        session.pause()
                        onPause()
                    } else {
                        session.play()
                        onPlay()
                    }
                }
                remoteKey("goforward.15") {
                    let target = min(position + 15, max(duration - 1, 0))
                    session.seek(to: target)
                    // 本机的播放位置也跟着走：退出投屏时能接上（§3.7）。
                    onSeek(target)
                }
                remoteKey("speaker.wave.2") {
                    // 电视的音量归电视自己；这里调手机的系统音量，投屏期间手机上
                    // 听到的提示音跟着走。系统自己会弹那条音量浮条，不再画第二条。
                    PlayerVolumeControl.shared.set(PlayerVolumeControl.shared.current + 0.1)
                }
                remoteKey("xmark.circle.fill") {
                    stopCasting()
                }
            }

            if duration > 0 {
                ProgressView(value: min(max(position / duration, 0), 1))
                    .tint(KazumiPalette.accent(for: colorScheme))
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 168)
        .padding(16)
        .background(deviceBackground)
        .overlay {
            RoundedRectangle(cornerRadius: KazumiPalette.cardCornerRadius, style: .continuous)
                .strokeBorder(KazumiPalette.accent(for: colorScheme), lineWidth: 2)
        }
    }

    private func remoteKey(
        _ symbol: String,
        highlighted: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let accent = KazumiPalette.accent(for: colorScheme)
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(highlighted ? accent : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background {
                    RoundedRectangle(cornerRadius: KazumiPalette.posterCornerRadius, style: .continuous)
                        .fill(highlighted ? accent.opacity(0.12) : KazumiPalette.groupedRow(for: colorScheme))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: KazumiPalette.posterCornerRadius, style: .continuous)
                        .strokeBorder(KazumiPalette.cardStroke(for: colorScheme), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: 零件

    private var deviceBackground: some View {
        RoundedRectangle(cornerRadius: KazumiPalette.cardCornerRadius, style: .continuous)
            .fill(KazumiPalette.groupedRow(for: colorScheme))
            .overlay {
                RoundedRectangle(cornerRadius: KazumiPalette.cardCornerRadius, style: .continuous)
                    .strokeBorder(KazumiPalette.cardStroke(for: colorScheme), lineWidth: 0.5)
            }
    }

    private func limitationRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
            Text(text)
                .font(.footnote)
                .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func outlinedButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .overlay {
                    Capsule()
                        .strokeBorder(KazumiPalette.accent(for: colorScheme), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    private func animate(_ body: () -> Void) {
        if reduceMotion {
            body()
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { body() }
        }
    }

    // MARK: 动作

    private func castTo(_ device: DLNADevice) {
        guard let mediaURL, let url = URL(string: mediaURL) else {
            banner = KazumiBannerState(
                title: "这一集还没解析出地址",
                detail: "等本机起播后再试。",
                variant: .info
            )
            return
        }
        Task {
            do {
                try await session.start(device: device, mediaURL: url)
                settings.lastDLNAAddress = device.reconnectAddress
                manualIP = device.reconnectAddress
                // 电视开始播了，本机就别再出声（design-cast.md §3.7）。
                onPause()
            } catch {
                // 源需要 Referer／Cookie 这类头时电视取不到流：不许给「重试」，
                // 只能说清是片源的问题。
                banner = KazumiBannerState(
                    title: "这个片源投不出去",
                    detail: "换一个片源，或回到本机播放。",
                    variant: .failure
                )
            }
        }
    }

    private func stopCasting() {
        Task {
            await session.stop()
            // 退出投屏回本机播放，位置接上（design-cast.md §3.7）。
            onPlay()
            banner = KazumiBannerState(title: "已回到本机播放", variant: .success)
        }
    }
}

// MARK: - 系统隔空播放按钮

/// 系统那粒隔空播放按钮。容器形状由外面的 `CastSheet` 给。
struct AirPlayRoutePicker: UIViewRepresentable {
    var tint: Color

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.tintColor = UIColor(tint)
        view.activeTintColor = UIColor(tint)
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = UIColor(tint)
        uiView.activeTintColor = UIColor(tint)
    }
}
