//
//  SettingsDetailScreens.swift
//  Kazumi
//
//  设置首页下挂的二级设置页。每一张对应主分支里同名的一个分类：
//    * 播放设置   —— lib/pages/settings/player_settings.dart
//    * 弹幕设置   —— lib/pages/settings/danmaku/danmaku_settings.dart
//    * 下载设置   —— lib/pages/settings/download_settings.dart
//    * 通知设置   —— lib/pages/settings/notification_settings.dart
//    * 外观设置   —— lib/pages/settings/theme_settings_page.dart
//    * 界面设置   —— lib/pages/settings/interface_settings.dart
//    * 网络设置   —— lib/pages/settings/proxy/proxy_settings_page.dart
//    * 更新设置   —— lib/pages/settings/update_settings.dart
//

import SwiftUI
import UIKit
import UserNotifications

/// 二级设置页的统一外壳（对应原版 SettingsDetailScaffold + SettingsList）。
private struct KazumiSettingsDetailStyle: ViewModifier {
    /// 收 LocalizedStringKey：`navigationTitle` 只有拿到 key 才会查目录
    /// （Ato 6442 第一步）。
    let title: LocalizedStringKey

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .scrollEdgeEffectStyle(.soft, for: .top)
            // 二级页内容限宽 700 居中（§6.4），跟设置首页同一套数（Ato 7028）：
            // 限宽 700、居中、行内缩 16（行宽 668）。maxWidth 只封顶不撑宽，
            // 窄屏自然满宽，所以不必等探针量到宽。
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
            .scrollContentBackground(.hidden)
            // LP 3524：二级页也要跟首页一个底色。原来铺的是 `background(for:)`
            // （浅色白、深色 #121212），条目本身也是白的，浅色下整页糊成一片白。
            // 这里换成分组页底 #F2F2F7／深色 #121212（OLED 开时纯黑）；
            // 条目色原本不另外给——Form 的分组行本来就是白／#1C1C1E，跟规格同值。
            // Colo 3532：改为各 Section 显式给 groupedRow，不再依赖系统动态行色。
            .background(KazumiPalette.groupedBackground(for: colorScheme).ignoresSafeArea())
    }
}

extension View {
    func kazumiSettingsDetail(_ title: LocalizedStringKey) -> some View {
        modifier(KazumiSettingsDetailStyle(title: title))
    }
}

// MARK: - 播放设置

struct PlayerSettingsScreen: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @State private var isConfirmingRestore = false
    /// 恢复默认后顶上那句提示；两秒后自己收起来。
    @State private var showRestoredToast = false

    var body: some View {
        Form {
            // 硬件解码、超分辨率与低内存模式放在同一组。
            Section {
                Group {
                    Toggle("硬件解码", isOn: hardwareDecodeBinding)
                    Picker("硬件解码模式", selection: hardwareDecodeModeBinding) {
                        ForEach(HardwareDecodeMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .disabled(!settings.hardwareDecodeEnabled)
                    // 跟播放器里「更多 → 超分辨率」是同一个值，两处改哪边都算。
                    Picker("超分辨率", selection: superResolutionBinding) {
                        ForEach(SuperResolutionMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    // main 的「低内存模式」三档（LP 5547）。开着就把解复用缓存从
                    // 1500 MiB 降到 2 MiB，省内存和流量，代价是慢速源更容易缓冲。
                    Picker("低内存模式", selection: lowMemoryModeBinding) {
                        ForEach(LowMemoryMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                }
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            } header: {
                Text("解码与渲染")
            } footer: {
                Text("解码设置重新打开播放器后生效。直通为零拷贝；非直通会多一次内存拷贝。")
            }
            // `Section("标题") { } footer: { }` 这个重载不存在，带页脚就得改成 header 写法。
            Section {
                Group {
                    // 顺序照 main 的「播放行为」一段（Ato 2026-10-24：这三颗提到第一批）。
                    // LP 2026-10-29：这一项改名说清楚它只是「继续出声」，画面不会跟着走；
                    // 下面两颗就是切后台/回前台的两条路。
                    Toggle("切后台继续播放音频", isOn: backgroundPlaybackBinding)
                    Toggle("后台自动画中画", isOn: backgroundAutoPiPBinding)
                    Toggle("回到前台自动播放", isOn: resumeOnForegroundBinding)
                    Toggle("自动连播", isOn: autoPlayNextBinding)
                    Toggle("自动跳转到上次播放位置", isOn: playResumeBinding)
                    Toggle("竖向滑动调音量和亮度", isOn: brightnessVolumeGestureBinding)
                    Toggle("隐身模式", isOn: privateModeBinding)
                }
                // Colo 3532：灰底页面的行底色显式取 groupedRow，不跟系统动态色走。
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            } header: {
                Text("播放行为")
            } footer: {
                // LP 3530：隐身模式那句加回来，但挂在组的页脚——「隐身模式」四个字
                // 本身讲不出它管的是观看记录，写上名字才知道说的是哪一行。
                Text("开启隐身模式后不保留观看记录")
            }
            Section("播放参数") {
                Group {
                    Picker("默认倍速", selection: playSpeedBinding) {
                        // 与原版播放器菜单同一份档位，避免两处再次走偏。
                        ForEach(PlaybackSpeed.all, id: \.self) { speed in
                            Text(PlaybackSpeed.label(speed)).tag(speed)
                        }
                    }
                    row {
                        // LP 2026-10-25：一次加 1 秒，上限 90 秒（默认 80）。
                        // 跳过时长跟符号无关（那颗长按还能自己填秒数），保持一次加 1 秒。
                        Stepper(value: buttonSkipTimeBinding, in: 5...90, step: 1) {
                            LabeledContent("跳过时长", value: String(localized: "\(String(describing: settings.buttonSkipTime)) 秒"))
                        }
                    }
                    row {
                        // 画面两侧快退/快进那两颗的秒数（LP 3643）。键名沿用原版
                        // `doubleTapSkipTime`——两边双击早已改成播放/暂停，这档现在
                        // 就是两侧按钮的时长，改名会让老用户的设置丢掉。
                        Picker("快进快退时长", selection: doubleTapSkipTimeBinding) {
                            ForEach(Self.doubleTapSkipOptions, id: \.self) { seconds in
                                Text(String(localized: "\(String(describing: seconds)) 秒")).tag(seconds)
                            }
                        }
                    }
                    row {
                        Picker("长按倍速", selection: longPressSpeedBinding) {
                            ForEach(PlaybackSpeed.all, id: \.self) { speed in
                                Text(PlaybackSpeed.label(speed)).tag(speed)
                            }
                        }
                    }
                    row {
                        HStack {
                            Text("控制栏消失时间")
                            Spacer(minLength: 8)
                            Text(controlBarHideLabel)
                                .foregroundStyle(.secondary)
                        }
                        // 原版滑杆范围 1–10 秒、0.5 秒一档（divisions 18），默认 4 秒。
                        Slider(value: controlBarHideBinding, in: 1...10, step: 0.5)
                    }
                    row {
                        Picker("默认视频比例", selection: aspectRatioBinding) {
                            ForEach(PlayerAspectRatioMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                    }
                }
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            }
            // `Section("标题") { } footer: { }` 这个重载不存在，带页脚就得改成 header 写法。
            Section {
                Group {
                    // 键名与默认值跟 main 的 `SettingsKeys.aniSkipLookup` 一致
                    // （默认开），两边的设置备份因此能互认。
                    Toggle(
                        "AniSkip 片头片尾",
                        isOn: Binding(
                            get: { settings.aniSkipLookup },
                            set: { settings.aniSkipLookup = $0 }
                        )
                    )
                }
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            } header: {
                Text("片头片尾")
            } footer: {
                Text("在线查询 AniSkip 社区时间轴，进入片头/片尾时提示跳过")
            }
            Section {
                Group {
                    // 不带 role: .destructive——恢复默认本来就不删用户数据，
                    // 染成红色会读成「要丢东西」（main 那颗也是普通按钮）。
                    Button {
                        isConfirmingRestore = true
                    } label: {
                        Text("恢复默认设置")
                    }
                }
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            }
            // 页脚那句「将相关设置恢复为默认值」删了（Camo 3510）：点下去弹的确认框里就是这句，
            // 行里再说一遍是重复。
        }
        .kazumiSettingsDetail("播放设置")
        .confirmationDialog(
            "恢复默认播放设置",
            isPresented: $isConfirmingRestore,
            titleVisibility: .visible
        ) {
            Button("恢复", role: .destructive) {
                settings.resetPlayerSettings()
                withAnimation { showRestoredToast = true }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation { showRestoredToast = false }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("播放设置将恢复为默认值。")
        }
        .overlay(alignment: .top) {
            if showRestoredToast {
                Text("已恢复默认播放设置")
                    .font(.footnote)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
    }

    /// 一行只放控件本身，不带说明小字。
    /// LP 3507：内页的小字基本都能删——看大字就知道意思，省下来的一行还给列表。
    /// 名字不够明确的，Colo 定的办法是改名，不是留着第二行灰字。
    private func row<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        // 留这层 VStack：像「控制栏消失时间」那样的行是标题＋滑杆两截，得竖着叠。
        VStack(alignment: .leading, spacing: 4) {
            content()
        }
    }

    private var autoPlayNextBinding: Binding<Bool> {
        Binding(get: { settings.autoPlayNext }, set: { settings.autoPlayNext = $0 })
    }

    private var playResumeBinding: Binding<Bool> {
        Binding(get: { settings.playResume }, set: { settings.playResume = $0 })
    }

    private var backgroundPlaybackBinding: Binding<Bool> {
        Binding(get: { settings.backgroundPlayback }, set: { settings.backgroundPlayback = $0 })
    }

    private var backgroundAutoPiPBinding: Binding<Bool> {
        Binding(get: { settings.backgroundAutoPiP }, set: { settings.backgroundAutoPiP = $0 })
    }

    private var resumeOnForegroundBinding: Binding<Bool> {
        Binding(get: { settings.resumeOnForeground }, set: { settings.resumeOnForeground = $0 })
    }

    private var brightnessVolumeGestureBinding: Binding<Bool> {
        Binding(
            get: { settings.brightnessVolumeGesture },
            set: { settings.brightnessVolumeGesture = $0 }
        )
    }

    private var hardwareDecodeBinding: Binding<Bool> {
        Binding(
            get: { settings.hardwareDecodeEnabled },
            set: { settings.hardwareDecodeEnabled = $0 }
        )
    }

    private var hardwareDecodeModeBinding: Binding<HardwareDecodeMode> {
        Binding(
            get: { settings.hardwareDecodeMode },
            set: { settings.hardwareDecodeMode = $0 }
        )
    }

    private var lowMemoryModeBinding: Binding<LowMemoryMode> {
        Binding(
            get: { settings.lowMemoryMode },
            set: { settings.lowMemoryMode = $0 }
        )
    }

    private var privateModeBinding: Binding<Bool> {
        Binding(get: { settings.privateMode }, set: { settings.privateMode = $0 })
    }

    private var playSpeedBinding: Binding<Double> {
        Binding(get: { settings.playSpeed }, set: { settings.playSpeed = $0 })
    }

    /// 快进快退的秒数档位：只给系统符号自带数字的那七档
    /// （`goforward.15` 这种），按钮上的数字不用自己画（LP 2026-10-28）。
    private static let doubleTapSkipOptions = SettingsStore.skipSecondTiers

    private var doubleTapSkipTimeBinding: Binding<Int> {
        Binding(
            get: { SettingsStore.nearestSkipSecond(settings.doubleTapSkipTime) },
            set: { settings.doubleTapSkipTime = SettingsStore.nearestSkipSecond($0) }
        )
    }

    /// 长按画面时的临时倍速，松手回到原来的倍速。
    private var longPressSpeedBinding: Binding<Double> {
        Binding(get: { settings.longPressSpeed }, set: { settings.longPressSpeed = $0 })
    }

    private var buttonSkipTimeBinding: Binding<Int> {
        Binding(
            get: { settings.buttonSkipTime },
            set: { settings.buttonSkipTime = min(90, max(1, $0)) }
        )
    }

    /// 设置页用秒展示，存储沿用原版的毫秒（`playerControllerLayerDisappearTime`）。
    private var controlBarHideBinding: Binding<Double> {
        Binding(
            get: { Double(settings.playerControllerLayerDisappearTime) / 1000 },
            set: { settings.playerControllerLayerDisappearTime = Int(($0 * 1000).rounded()) }
        )
    }

    private var controlBarHideLabel: String {
        let seconds = Double(settings.playerControllerLayerDisappearTime) / 1000
        return seconds == seconds.rounded()
            ? String(localized: "\(String(describing: Int(seconds))) 秒")
            : String(format: String(localized: "%.1f 秒"), seconds)
    }

    private var superResolutionBinding: Binding<SuperResolutionMode> {
        Binding(
            get: { settings.superResolutionMode },
            set: { settings.superResolutionMode = $0 }
        )
    }

    private var aspectRatioBinding: Binding<PlayerAspectRatioMode> {
        Binding(
            get: { settings.defaultAspectRatio },
            set: { settings.defaultAspectRatio = $0 }
        )
    }
}

// MARK: - 弹幕设置

private struct DanmakuRequestHeaderRow: Identifiable {
    let id = UUID()
    var name = ""
    var value = ""
}

struct DanmakuSettingsScreen: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme
    @State private var isConfirmingRestore = false
    /// 恢复默认后顶上那句提示；两秒后自己收起来。
    @State private var showRestoredToast = false
    @State private var isDanmakuAPIConfigExpanded = false
    @State private var danmakuAPIURLText = ""
    @State private var danmakuAPIRequestHeaderRows: [DanmakuRequestHeaderRow] = []
    @State private var danmakuAPIConfigError: String?
    @State private var danmakuAPIToast: LocalizedStringKey?
    @State private var danmakuAPIBanner: KazumiBannerState?
    @State private var isDanmakuAPITesting = false
    @State private var didPrefillDanmakuAPIConfig = false

    var body: some View {
        Form {
            // 三路来源都只是内容筛选开关。DanDanPlay 返回的每条弹幕自带来路标记，
            // 这三颗就是按标记筛——关掉的那一路不画。接口凭据在页面底部单独配置。
            Section("弹幕来源") {
                Group {
                    Toggle(isOn: biliBiliSourceBinding) {
                        Label("BiliBili", systemImage: "tv")
                    }
                    Toggle(isOn: gamerSourceBinding) {
                        Label("Gamer", systemImage: "gamecontroller")
                    }
                    Toggle(isOn: danDanSourceBinding) {
                        Label("弹弹play", systemImage: "bubble.left.and.bubble.right")
                    }
                }
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            }
            Section {
                Group {
                    Button {
                        router.push(.danmakuShield)
                    } label: {
                        Label("关键词屏蔽", systemImage: "eye.slash")
                    }
                }
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            } footer: {
                Text("按关键词过滤掉不想看的弹幕，规则可同步到 WebDAV。")
            }
            Section("弹幕显示") {
                Group {
                    Toggle("显示弹幕", isOn: enabledBinding)
                    sliderRow(
                        title: "弹幕区域",
                        value: "\(Int((settings.danmakuArea * 100).rounded()))%",
                        binding: areaBinding,
                        range: 0...1,
                        step: 0.125
                    )
                    sliderRow(
                        title: "弹幕持续时间",
                        value: String(localized: "\(String(describing: Int(settings.danmakuDuration.rounded()))) 秒"),
                        binding: durationBinding,
                        range: 2...16,
                        step: 1
                    )
                    sliderRow(
                        title: "弹幕行高",
                        value: String(format: "%.1f", settings.danmakuLineHeight),
                        binding: lineHeightBinding,
                        range: 0...3,
                        step: 0.1
                    )
                    Toggle("弹幕跟随视频倍速", isOn: followSpeedBinding)
                    Toggle("顶部弹幕", isOn: topBinding)
                    Toggle("底部弹幕", isOn: bottomBinding)
                    Toggle("滚动弹幕", isOn: scrollBinding)
                    Toggle("弹幕叠加绘制", isOn: massiveBinding)
                    Toggle("弹幕去重", isOn: dedupBinding)
                }
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            }
            Section("弹幕样式") {
                Group {
                    Toggle("弹幕描边", isOn: borderBinding)
                    sliderRow(
                        title: "弹幕描边粗细",
                        value: String(format: "%.1f", settings.danmakuBorderSize),
                        binding: borderSizeBinding,
                        range: 0.1...3,
                        step: 0.1
                    )
                    Toggle("弹幕颜色", isOn: colorBinding)
                    sliderRow(
                        title: "字体大小",
                        value: "\(Int(settings.danmakuFontSize.rounded()))",
                        binding: fontSizeBinding,
                        range: 10...48,
                        step: 1
                    )
                    sliderRow(
                        title: "字体字重",
                        value: "\(settings.danmakuFontWeight)",
                        binding: fontWeightBinding,
                        range: 1...9,
                        step: 1
                    )
                    sliderRow(
                        title: "弹幕不透明度",
                        value: "\(Int((settings.danmakuOpacity * 100).rounded()))%",
                        binding: opacityBinding,
                        range: 0.1...1,
                        step: 0.05
                    )
                }
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            }
            Section {
                Group {
                    // LP 7041：API 地址常驻，右侧一颗回退符号把自定义 API 清回安装包内置。
                    HStack(alignment: .center, spacing: 8) {
                        Text("API 地址")
                            .frame(width: 80, alignment: .leading)

                        TextField("内置", text: $danmakuAPIURLText)
                            .multilineTextAlignment(.leading)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: danmakuAPIURLText) {
                                danmakuAPIConfigError = nil
                            }
                            .padding(.trailing, settings.hasCustomDanmakuAPI ? 52 : 0)
                    }
                    // LP 7076 / Colo 7077：回退箭头用 overlay 叠在行尾，不撑高整行——
                    // 行高与相邻行一致，箭头 17pt 视觉、44×44 热区，在行内垂直居中。
                    .overlay(alignment: .trailing) {
                        if settings.hasCustomDanmakuAPI {
                            Button {
                                restorePackagedDanmakuAPIConfig()
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 17))
                            }
                            .buttonStyle(.borderless)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .accessibilityLabel(String(localized: "恢复安装包内置配置"))
                            .disabled(isDanmakuAPITesting)
                        }
                    }

                    // LP 7037：只有请求头这一段折叠，API 地址不折叠。
                    danmakuAPIConfigRow

                    if isDanmakuAPIConfigExpanded {
                        // LP 7113：换系统原生上下拖动。ForEach 必须是 List 的直接子级
                        // （每行一个 List row），onMove/editActions 才生效——之前套在 VStack
                        // 里整个是一行，原生 reorder 不工作；自制手势会闪，弃用。
                        // LP 7134/Colo 7135：分隔线不再自画（Divider 在 Form 行内被压成不可见，
                        // 自画线疑似闪烁源），删掉，用 List 原生行分隔线，颜色/粗细/位置全按系统默认，
                        // 原规格「左端对齐52」作废。
                        ForEach($danmakuAPIRequestHeaderRows) { $row in
                            VStack(spacing: 0) {
                                HStack(spacing: 8) {
                                    Button(role: .destructive) {
                                        danmakuAPIRequestHeaderRows.removeAll {
                                            $0.id == row.id
                                        }
                                    } label: {
                                        Image(systemName: "minus.circle")
                                            .font(.system(size: 17))
                                            .frame(width: 44, height: 44)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel(String(localized: "删除请求头"))

                                    GeometryReader { proxy in
                                        let nameWidth = max(0, (proxy.size.width - 8) * 0.3)
                                        HStack(spacing: 8) {
                                            TextField("键", text: $row.name)
                                                .frame(width: nameWidth, height: 40)
                                                .textInputAutocapitalization(.never)
                                                .autocorrectionDisabled()
                                                .onChange(of: row.name) {
                                                    danmakuAPIConfigError = nil
                                                }

                                            TextField("值", text: $row.value)
                                                .frame(maxWidth: .infinity, minHeight: 40)
                                                .textInputAutocapitalization(.never)
                                                .autocorrectionDisabled()
                                                .onChange(of: row.value) {
                                                    danmakuAPIConfigError = nil
                                                }
                                        }
                                    }
                                    .frame(height: 40)
                                }
                                // Colo 7094：行高 44→40；删除热区仍 44（上下各溢 2 点）。
                                .frame(height: 40)
                            }
                            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                            .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
                        }
                        // LP 7113：系统原生上下拖动。这个 SDK 的 ForEach 上没有 .editActions
                        // （绑定版/非绑定版都报 no member，两轮构建证实），常驻 editMode 方案
                        // 被 LP 7150 划掉（根本不许有编辑模式）。先用 onMove 实测不进编辑模式
                        // 能否按住直接拖，不行再换别的能编过的路子。
                        .onMove { from, to in
                            danmakuAPIRequestHeaderRows.move(fromOffsets: from, toOffset: to)
                        }

                        Button {
                            danmakuAPIRequestHeaderRows.append(DanmakuRequestHeaderRow())
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle")
                                    .font(.system(size: 17))
                                Text("添加请求头")
                                    .font(.system(size: 17))
                            }
                            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                        }
                        .buttonStyle(.borderless)
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 0, trailing: 20))
                        .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))

                        if let danmakuAPIConfigError {
                            Text(danmakuAPIConfigError)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    // 保存并测试常驻：API 地址不折叠，保存就不该藏在折叠里。
                    Button {
                        saveAndTestDanmakuAPIConfig()
                    } label: {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                                .opacity(isDanmakuAPITesting ? 1 : 0)
                            Text(isDanmakuAPITesting ? "正在测试…" : "保存并测试")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isDanmakuAPITesting)
                }
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            } header: {
                Text("自定义弹幕接口")
            } footer: {
                Text("仅兼容 DanDanPlay v2 接口协议；其他格式的第三方接口暂不支持。")
            }
            .animation(nil, value: isDanmakuAPIConfigExpanded)
            Section {
                Group {
                    Button {
                        isConfirmingRestore = true
                    } label: {
                        Text("恢复默认设置")
                    }
                }
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            }
            // 页脚那句「将相关设置恢复为默认值」删了（Camo 3510）：点下去弹的确认框里就是这句，
            // 行里再说一遍是重复。
        }
        .kazumiSettingsDetail("弹幕设置")
        .onAppear { prefillDanmakuAPIConfig() }
        .confirmationDialog(
            "恢复默认弹幕设置",
            isPresented: $isConfirmingRestore,
            titleVisibility: .visible
        ) {
            Button("恢复默认", role: .destructive) {
                settings.resetDanmakuSettings()
                withAnimation { showRestoredToast = true }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation { showRestoredToast = false }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            // 逐字照 main（danmaku_settings.dart:82）：让用户知道屏蔽词不会被清。
            Text("弹幕来源、显示和样式设置将恢复为默认值，关键词屏蔽列表不会被清空。")
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if let danmakuAPIBanner {
                    KazumiBanner(
                        title: danmakuAPIBanner.title,
                        detail: danmakuAPIBanner.detail,
                        variant: danmakuAPIBanner.variant,
                        mode: danmakuAPIBanner.mode,
                        onDismiss: {
                            withAnimation(.snappy) { self.danmakuAPIBanner = nil }
                        }
                    )
                }
                if showRestoredToast {
                    toastLabel("已恢复默认弹幕设置")
                }
                if let danmakuAPIToast {
                    toastLabel(danmakuAPIToast)
                }
            }
            .padding(.top, 8)
        }
        .animation(.snappy, value: danmakuAPIBanner != nil)
    }

    private func toastLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.footnote)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .transition(.opacity)
    }

    private var danmakuAPIConfigRow: some View {
        Button {
            isDanmakuAPIConfigExpanded.toggle()
        } label: {
            HStack(spacing: 8) {
                Text("自定义请求头")
                    .foregroundStyle(Color.primary)
                Spacer(minLength: 8)
                // Camo 7080：请求头条数走整数格式键（%lld 项），屏上文字与读屏值解析同一份译文。
                Text(danmakuAPIRequestHeaderCountText)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .rotationEffect(.degrees(isDanmakuAPIConfigExpanded ? 180 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "自定义请求头"))
        .accessibilityValue(danmakuAPIRequestHeaderCountText)
        .accessibilityHint(isDanmakuAPIConfigExpanded ? String(localized: "收起配置") : String(localized: "展开配置"))
    }

    /// 请求头行数：整数插值 → 目录键「%lld 项」，繁中「%lld 項」。
    private var danmakuAPIRequestHeaderCountText: String {
        String(localized: "\(danmakuAPIRequestHeaderRows.count) 项")
    }

    private var danmakuAPIConfigSummary: String {
        guard settings.hasCustomDanmakuAPI else {
            return String(localized: "安装包内置")
        }
        let customURL = settings.danmakuAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !customURL.isEmpty {
            return URL(string: customURL)?.host ?? customURL
        }
        return String(localized: "自定义请求头")
    }

    private func prefillDanmakuAPIConfig() {
        guard !didPrefillDanmakuAPIConfig else { return }
        didPrefillDanmakuAPIConfig = true
        danmakuAPIURLText = settings.danmakuAPIURL
        let parsed = (try? DanDanRequestHeaders.parse(settings.danmakuAPIRequestHeaders)) ?? [:]
        danmakuAPIRequestHeaderRows = parsed
            .sorted { $0.key < $1.key }
            .map { DanmakuRequestHeaderRow(name: $0.key, value: $0.value) }
    }

    private func saveAndTestDanmakuAPIConfig() {
        let baseURL = danmakuAPIURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestHeaders = danmakuAPIRequestHeaderRows.compactMap { row in
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = row.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty || !value.isEmpty else { return nil }
            return "\(name): \(value)"
        }.joined(separator: "\n")

        if !baseURL.isEmpty {
            guard let components = URLComponents(string: baseURL),
                  let scheme = components.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  components.host != nil
            else {
                danmakuAPIConfigError = String(localized: "API 地址格式错误，请使用 http:// 或 https:// 地址")
                return
            }
        }
        do {
            _ = try DanDanRequestHeaders.parse(requestHeaders)
        } catch {
            danmakuAPIConfigError = error.localizedDescription
            return
        }

        isDanmakuAPITesting = true
        Task { @MainActor in
            do {
                try await DanmakuAPI.testConnection(
                    baseURL: baseURL,
                    requestHeaders: requestHeaders
                )
                settings.danmakuAPIURL = baseURL
                settings.danmakuAPIRequestHeaders = requestHeaders
                danmakuAPIConfigError = nil
                withAnimation(.snappy) {
                    danmakuAPIBanner = KazumiBannerState(
                        title: "连接正常",
                        variant: .success
                    )
                }
            } catch {
                withAnimation(.snappy) {
                    danmakuAPIBanner = KazumiBannerState(
                        title: "连接失败",
                        detail: error.localizedDescription
                    )
                }
            }
            isDanmakuAPITesting = false
        }
    }

    private func restorePackagedDanmakuAPIConfig() {
        danmakuAPIURLText = ""
        danmakuAPIRequestHeaderRows = []
        danmakuAPIConfigError = nil
        settings.danmakuAPIURL = ""
        settings.danmakuAPIRequestHeaders = ""
        flashDanmakuAPI("已恢复安装包内置配置")
    }

    private func flashDanmakuAPI(_ text: LocalizedStringKey) {
        withAnimation { danmakuAPIToast = text }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { danmakuAPIToast = nil }
        }
    }

    /// 「标题 + 当前值 + 滑杆」一行。
    private func sliderRow(
        title: LocalizedStringKey,
        value: String,
        binding: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text(value)
                    .foregroundStyle(.secondary)
            }
            Slider(value: binding, in: range, step: step)
        }
    }

    private func bool(_ keyPath: ReferenceWritableKeyPath<SettingsStore, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 })
    }

    private func double(_ keyPath: ReferenceWritableKeyPath<SettingsStore, Double>) -> Binding<Double> {
        Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 })
    }

    private var enabledBinding: Binding<Bool> { bool(\.danmakuEnabled) }
    private var followSpeedBinding: Binding<Bool> { bool(\.danmakuFollowSpeed) }
    private var topBinding: Binding<Bool> { bool(\.danmakuTop) }
    private var bottomBinding: Binding<Bool> { bool(\.danmakuBottom) }
    private var scrollBinding: Binding<Bool> { bool(\.danmakuScroll) }
    private var massiveBinding: Binding<Bool> { bool(\.danmakuMassive) }
    private var dedupBinding: Binding<Bool> { bool(\.danmakuDeduplication) }
    private var borderBinding: Binding<Bool> { bool(\.danmakuBorder) }
    private var colorBinding: Binding<Bool> { bool(\.danmakuColor) }
    private var biliBiliSourceBinding: Binding<Bool> { bool(\.danmakuBiliBiliSource) }
    private var gamerSourceBinding: Binding<Bool> { bool(\.danmakuGamerSource) }
    private var danDanSourceBinding: Binding<Bool> { bool(\.danmakuDanDanSource) }

    private var fontSizeBinding: Binding<Double> { double(\.danmakuFontSize) }
    private var opacityBinding: Binding<Double> { double(\.danmakuOpacity) }
    private var areaBinding: Binding<Double> { double(\.danmakuArea) }
    private var durationBinding: Binding<Double> { double(\.danmakuDuration) }
    private var lineHeightBinding: Binding<Double> { double(\.danmakuLineHeight) }
    private var borderSizeBinding: Binding<Double> { double(\.danmakuBorderSize) }

    private var fontWeightBinding: Binding<Double> {
        Binding(
            get: { Double(settings.danmakuFontWeight) },
            set: { settings.danmakuFontWeight = Int($0.rounded()) }
        )
    }
}

// MARK: - 下载设置

struct DownloadSettingsScreen: View {
    @Environment(AppRouter.self) private var router
    @Environment(DownloadDirectoryStore.self) private var downloadDirectory
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Group {
                    Button {
                        router.push(.download)
                    } label: {
                        Label("下载管理", systemImage: "arrow.down.circle")
                    }
                }
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            } footer: {
                Text("下载管理里可以查看已下载的剧集。")
            }
            Section {
                Group {
                    Button {
                        chooseDirectory()
                    } label: {
                        // 大字号下「下载位置」和路径并排装不下，路径被截成
                        // 「我的 iPhone >…」——路径截了等于没写（Camo 5304）。
                        // 装不下就上下排（Colo 6540）。
                        ViewThatFits(in: .horizontal) {
                            HStack {
                                Text("下载位置")
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 8)
                                Text(downloadDirectory.displayName)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                                    // 路径折两行、右对齐；不用中间省略号——路径截了中间等于没写（Camo 5304）。
                                    .lineLimit(2)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("下载位置")
                                    .foregroundStyle(.primary)
                                Text(downloadDirectory.displayName)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if downloadDirectory.hasCustomSelection {
                        Button("恢复默认") {
                            downloadDirectory.reset()
                            message = nil
                        }
                    }
                }
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            } footer: {
                if let message {
                    Text(message)
                } else if downloadDirectory.customUnavailable {
                    // 以前这里是静默回退：右边写着选的文件夹名，实际却写去默认位置。
                    Text("这个文件夹现在打不开，下载仍存在文件 App 内。把 App 完全关掉重开一次，或重新选一次文件夹。")
                } else {
                    // 第一句留给侧载装的用户：那种安装方式下选择器可能整个不响应，
                    // 别让他以为是自己点错了（LP 5301）。
                    // 第二句照 main（download_settings.dart:148）：换目录的人最容易以为
                    // 旧文件会跟着搬过去，这句不能省。
                    Text("侧载安装可能无法正常更改，这是已知问题。换位置只对之后下载的剧集生效，之前的不会跟着搬。")
                }
            }

            // 并发两项（LP 5163）：键一直在 SettingsStore 里、默认就是 2 和 3，
            // 缺的是这一页的控件。改完当场生效：下载中心和引擎每次都现读。
            Section {
                Group {
                    row {
                        Stepper(value: parallelEpisodesBinding, in: 1...5, step: 1) {
                            LabeledContent("同时下载", value: String(localized: "\(String(describing: settings.downloadParallelEpisodes)) 集"))
                        }
                    }
                    row {
                        Stepper(value: parallelSegmentsBinding, in: 1...10, step: 1) {
                            LabeledContent("每集同时下载", value: String(localized: "\(String(describing: settings.downloadParallelSegments)) 个分片"))
                        }
                    }
                }
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            } header: {
                Text("并发")
            } footer: {
                Text("同时下载几集，和每一集内部同时拉几个分片。改完立刻对之后开始的部分生效，已经在下的一集不会重新排。")
            }
        }
        .kazumiSettingsDetail("下载设置")
    }

    private func chooseDirectory() {
        downloadDirectory.choose { result in
            // 面板退场这一拍再改状态，免得提示压在还在退的页面上。
            switch result {
            case .success:
                message = nil
            case .failure(let error):
                if let pickerError = error as? DocumentPickerBridge.PickerError,
                   case .cancelled = pickerError { return }
                message = error.localizedDescription
            }
        }
    }

    /// 与播放设置页同一层 VStack：Stepper 里的标题与数值一行，不需要额外拆分。
    private func row<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content()
        }
    }

    /// 1–5 集，默认 2（原版 downloadParallelEpisodes）。
    private var parallelEpisodesBinding: Binding<Int> {
        Binding(
            get: { settings.downloadParallelEpisodes },
            set: { settings.downloadParallelEpisodes = min(5, max(1, $0)) }
        )
    }

    /// 1–10 个分片，默认 3（原版 downloadParallelSegments）。
    private var parallelSegmentsBinding: Binding<Int> {
        Binding(
            get: { settings.downloadParallelSegments },
            set: { settings.downloadParallelSegments = min(10, max(1, $0)) }
        )
    }
}

// MARK: - 通知设置

struct NotificationSettingsScreen: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.colorScheme) private var colorScheme
    /// 系统通知权限（进页面时查一次，申请/跳设置回来再查）。
    @State private var permission: UNAuthorizationStatus = .notDetermined
    @State private var isBusy = false
    /// 「查看排程」那一次读出来的已排定提醒。
    @State private var isShowingSchedule = false
    @State private var scheduled: [ScheduledUpdateNotification] = []

    var body: some View {
        Form {
            Section {
                Group {
                    Button {
                        Task { await handlePermissionTap() }
                    } label: {
                        HStack {
                            Text("通知权限")
                                .foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            Text(permissionLabel)
                                .foregroundStyle(permission == .authorized ? Color.secondary : Color.orange)
                        }
                    }
                    .disabled(isBusy)
                }
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            } header: {
                Text("通知权限")
            } footer: {
                Text(permissionCaption)
            }

            // 一行一个菜单（LP 2532）：左边写「提醒范围」，右边的值点开选，跟深色模式那行一致。
            Section {
                Group {
                    Picker("提醒范围", selection: scopeBinding) {
                        Text("关闭").tag(false)
                        Text("我在追的动画").tag(true)
                    }
                    .pickerStyle(.menu)
                    .disabled(isBusy)
                }
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            } footer: {
                Text("「我在追的动画」包含所有标记「在看」的番剧。")
            }

            Section {
                Group {
                    Button {
                        Task { await showSchedule() }
                    } label: {
                        HStack {
                            Text("查看排程")
                                .foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            Text(scheduledSummary)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            } header: {
                Text("通知排程")
            } footer: {
                Text("按追番列表里每部番的放送时刻排定，最多排未来 7 天。")
            }
        }
        .kazumiSettingsDetail("通知设置")
        .task { await refreshPermission() }
        .sheet(isPresented: $isShowingSchedule) {
            UpdateScheduleSheet(items: scheduled)
        }
        .onChange(of: settings.updateNotificationEnabled) { _, _ in
            Task { await environment.refreshUpdateNotifications() }
        }
    }

    private var scopeBinding: Binding<Bool> {
        Binding(
            get: { settings.updateNotificationEnabled },
            // 打开「我在追的动画」时顺手把通知权限要下来（LP 2530）：没问过就弹系统弹窗，
            // 之前拒过的只能引导去系统设置。没拿到权限就不打开这个范围，
            // 免得留下一个开着却永远不响的开关。
            set: { newValue in
                if newValue {
                    Task { await enableScope() }
                } else {
                    settings.updateNotificationEnabled = false
                }
            }
        )
    }

    private func enableScope() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let outcome = await UpdateNotificationScheduler.shared.ensurePermission()
        await refreshPermission()
        switch outcome {
        case .granted:
            settings.updateNotificationEnabled = true
            await environment.refreshUpdateNotifications()
        case .asked:
            // 弹窗里没允许：范围保持关闭。
            settings.updateNotificationEnabled = false
        case .needsSettings:
            settings.updateNotificationEnabled = false
            if let url = URL(string: UIApplication.openSettingsURLString) {
                await UIApplication.shared.open(url)
            }
        }
    }

    private var permissionLabel: LocalizedStringKey {
        switch permission {
        case .authorized, .provisional, .ephemeral: "已允许"
        case .denied: "已关闭"
        case .notDetermined: "未询问"
        @unknown default: "未知"
        }
    }

    private var permissionCaption: LocalizedStringKey {
        switch permission {
        case .authorized, .provisional, .ephemeral:
            "更新提醒会以系统通知送达。"
        case .denied:
            "系统里已经关掉了这个 App 的通知，点这一行去系统设置里打开。"
        case .notDetermined:
            "点这一行申请通知权限。"
        @unknown default:
            "点这一行申请通知权限。"
        }
    }

    private var scheduledSummary: LocalizedStringKey {
        if !settings.updateNotificationEnabled { return "提醒已关闭" }
        return "查看已排定的更新提醒"
    }

    private func refreshPermission() async {
        permission = await UpdateNotificationScheduler.shared.authorizationStatus()
    }

    /// 点「通知权限」：没问过就申请；拒绝过的只能跳系统设置。
    private func handlePermissionTap() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let outcome = await UpdateNotificationScheduler.shared.ensurePermission()
        await refreshPermission()
        switch outcome {
        case .granted:
            // 拿到权限了就把提醒排上（之前没权限时排不进去）。
            await environment.refreshUpdateNotifications()
        case .asked:
            break
        case .needsSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                await UIApplication.shared.open(url)
            }
        }
    }

    private func showSchedule() async {
        scheduled = await UpdateNotificationScheduler.shared.scheduledNotifications()
        isShowingSchedule = true
    }
}

/// 「通知排程」弹窗：列出已排定的提醒，按时间先后。
private struct UpdateScheduleSheet: View {
    let items: [ScheduledUpdateNotification]

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty {
                    Text(String(localized: "当前没有已排定的提醒。\n标记「在看」的番剧有更新时间数据时，会自动排定。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.body)
                            .font(.subheadline)
                        Text(Self.format(item.fireAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("通知排程")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private static func format(_ date: Date) -> String {
        // 星期和日期一起交给系统（Ato 6122），顺序由系统定；时刻写死 24 小时。
        let day = date.formatted(Date.FormatStyle(date: .complete, time: .omitted))
        return "\(day) \(KazumiTimeText.clock(date))"
    }
}

// MARK: - 外观设置

struct ThemeSettingsScreen: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme

    /// 与原版 interface_settings.dart 的 defaultPageMap 一致。
    private static let startupPages: [(value: String, title: String)] = [
        ("/tab/popular/", "推荐"),
        ("/tab/timeline/", "时间表"),
        ("/tab/collect/", "追番"),
        ("/tab/my/", "我的"),
    ]

    var body: some View {
        Form {
            Section("主题") {
                Group {
                    row {
                        // LP 3513／Colo 3514：叫「应用主题」更准——这一行本来就是跟随系统／浅色／深色三档。
                        Picker("应用主题", selection: themeBinding) {
                            ForEach(KazumiThemeMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                    }
                    row {
                        Button {
                            router.isShowingThemeColorSheet = true
                        } label: {
                            HStack {
                                // LP 3513：配色改名「强调色」。
                                Label("强调色", systemImage: "paintpalette")
                                Spacer()
                                Text(settings.themeColor.title)
                                    .foregroundStyle(.secondary)
                                KazumiThemeColorSwatch(color: settings.themeColor, size: 18)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            }
            // Colo 2595：显示效果一段装「屏幕上多显示点什么」的那几项。
            Section("显示效果") {
                Group {
                    // 「OLED优化」中间没有空格，照 main 的写法。
                    Toggle("OLED优化", isOn: oledBinding)
                    Toggle("触感反馈", isOn: hapticBinding)
                    Toggle("上滑时缩小底部标签栏", isOn: tabBarBinding)
                    // LP 3517：这一行挪到本组最后，说明也改准——
                    // 原来写「概览和番剧列表」，可我们的列表根本不显示评分，认这个开关的是时间表。
                    // 这是整页唯一留着说明小字的一行：名字讲不出它管哪些地方。
                    Toggle(isOn: showRatingBinding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("显示评分")
                            Text("关闭后隐藏概览和时间表里的评分信息")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    // LP 5039：时间表星期条上的番剧计数。默认关。
                    // 关掉时星期条换成规则编辑页顶部那种分段 tab（见 `TimelineScreen`）。
                    Toggle(isOn: timelineShowCountBinding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("时间表番剧计数")
                            Text("关闭后时间表的星期换成普通标签栏")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            }
            // Camo 2599：段已经叫「启动」，行里不再说一遍启动。
            Section("启动") {
                Group {
                    Picker("打开时进入", selection: startupBinding) {
                        ForEach(Self.startupPages, id: \.value) { page in
                            Text(page.title).tag(page.value)
                        }
                    }
                }
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            }
        }
        .kazumiSettingsDetail("外观与界面")
    }

    private var themeBinding: Binding<KazumiThemeMode> {
        Binding(get: { settings.themeMode }, set: { settings.themeMode = $0 })
    }

    private var oledBinding: Binding<Bool> {
        Binding(get: { settings.oledEnhance }, set: { settings.oledEnhance = $0 })
    }

    private var hapticBinding: Binding<Bool> {
        Binding(
            get: { settings.hapticFeedbackEnabled },
            set: { settings.hapticFeedbackEnabled = $0 }
        )
    }

    private var showRatingBinding: Binding<Bool> {
        Binding(get: { settings.showRating }, set: { settings.showRating = $0 })
    }

    private var timelineShowCountBinding: Binding<Bool> {
        Binding(
            get: { settings.timelineShowCount },
            set: { settings.timelineShowCount = $0 }
        )
    }

    private var tabBarBinding: Binding<Bool> {
        Binding(
            get: { settings.tabBarShrinkOnScroll },
            set: { settings.tabBarShrinkOnScroll = $0 }
        )
    }

    private var startupBinding: Binding<String> {
        Binding(
            get: { settings.defaultStartupPage },
            set: { settings.defaultStartupPage = $0 }
        )
    }

    /// 一行只放控件本身，不带说明小字（LP 3507）。
    private func row<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        // 留这层 VStack：像「控制栏消失时间」那样的行是标题＋滑杆两截，得竖着叠。
        VStack(alignment: .leading, spacing: 4) {
            content()
        }
    }
}

// MARK: - 界面设置

// MARK: - 网络设置

struct NetworkSettingsScreen: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    /// 开关被拦下来时顶上那句提示（`.automatic` 3.5 秒收），
    /// 测试失败走同一条 banner 的 `.manual`（Ato 6406 §十二）。
    @State private var banner: KazumiBannerState?
    /// 代理配置那一块展开没有。LP 5354：跟 Bangumi 同步里 Access Token 一样
    /// 折在原地，默认折着。
    @State private var isProxyConfigExpanded = false
    /// 两个输入框用本地状态，点「保存并测试」才落盘——中途退出不该改设置
    /// （main 也是点按钮才存）。
    @State private var proxyAddressText = ""
    @State private var proxyTestText = ""
    /// 地址那框的错话（格式不对、没填），落在框下面挂着，不自己收（Ato 6398 四）。
    @State private var proxyAddressError: String?
    /// 上次测试的结果，走顶部提示条（Ato 6432 §十一），不落按钮那一行。
    @FocusState private var proxyAddressFocused: Bool
    @State private var isProxyTesting = false

    var body: some View {
        Form {
            // 一段三行照原版 NetworkMirrorSettings：番剧条目、图片、规则仓库镜像
            // （镜像放最后，Colo 规格 2026-11-02；LP 6225）。
            Section {
                Group {
                    Picker("番剧条目加速", selection: bangumiAccelerationBinding) {
                        Text("直连").tag(false)
                        Text("镜像").tag(true)
                    }
                    .pickerStyle(.menu)

                    Picker("图片加速", selection: imageAccelerationBinding) {
                        Text("直连").tag(ImageAcceleration.direct.rawValue)
                        Text("镜像").tag(ImageAcceleration.mirror.rawValue)
                    }
                    .pickerStyle(.menu)

                    RulesMirrorMenu(asListRows: true)
                }
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            } header: {
                Text("访问加速")
            }

            // 代理这一段照 main（LP 5342）：开关一行，地址一整串。
            // 不单开一页（LP 5354）。折叠照 WebDAV 那个 credentialsRow：
            // 折叠行只装按钮，展开的字段是同一组的兄弟行——拿 VStack 把
            // 「按钮 + 展开内容」包在一起，在 Form 里就是同一个行，又高又窄又抖（Colo 5365）。
            Section {
                Group {
                    Toggle("启用代理", isOn: proxyEnabledBinding)

                    proxyConfigRow

                    if isProxyConfigExpanded {
                        // LP 5372 / 5384：左边标题，值靠左。
                        HStack(alignment: .top, spacing: 8) {
                            Text("代理地址")
                                .frame(width: 72, alignment: .leading)

                            // `http://` 就摆在框里（LP 5355），靠左。
                            // 错话落在框下面（Ato 6390）：框占满宽度、不被挤；错话挂着
                            // 不自己收（Colo 6389），改了地址或再按按钮才清。
                            VStack(alignment: .leading, spacing: 4) {
                                TextField("请填入代理地址", text: $proxyAddressText)
                                    .multilineTextAlignment(.leading)
                                    .keyboardType(.URL)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .focused($proxyAddressFocused)
                                    .onChange(of: proxyAddressText) {
                                        proxyAddressError = nil
                                    }

                                if let proxyAddressError {
                                    Text(proxyAddressError)
                                        .foregroundStyle(.red)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }

                        HStack(spacing: 8) {
                            Text("测试地址")
                                .frame(width: 72, alignment: .leading)

                            TextField("https://www.google.com", text: $proxyTestText)
                                .multilineTextAlignment(.leading)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }

                        // 按钮回原版：满宽居中，行里什么都不放（Ato 6432 §十一）。
                        // 进行中在按钮里转圈＋「正在测试…」＋禁用（Ato 6398 二）。
                        Button {
                            saveAndTestProxy()
                        } label: {
                            HStack(spacing: 6) {
                                // 圈一直占着位，只换透明——三种状态下按钮宽度一格不动。
                                ProgressView()
                                    .controlSize(.small)
                                    .opacity(isProxyTesting ? 1 : 0)
                                Text(isProxyTesting ? "正在测试…" : "保存并测试")
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isProxyTesting)
                    }
                }
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            } header: {
                Text("代理")
            } footer: {
                // LP 5083：把「到底用上没有」直接写出来，不然用户只能猜。
                if let proxyState {
                    Text(proxyState)
                        .foregroundStyle(.secondary)
                }
            }
            // 折起来、摊开只换高度，别给高度加隐式动画——那一行位置没动，
            // 抖是动画抖的（WebDAV 那段同款）。
            .animation(nil, value: isProxyConfigExpanded)
        }
        .kazumiSettingsDetail("网络设置")
        .onAppear { prefillProxyFields() }
        // 失焦时校验（Colo 6391 §十）：HIG 说的就是这个时机，不在打字途中报红。
        .onChange(of: proxyAddressFocused) { _, focused in
            if !focused { proxyAddressError = proxyAddressProblem }
        }
        // 错话是插进来的文字，焦点不会跟过去，得主动报一次（Colo 6391 §十）。
        .onChange(of: proxyAddressError) { _, text in
            if let text { AccessibilityNotification.Announcement(text).post() }
        }
        .overlay(alignment: .top) {
            if let banner {
                KazumiBanner(
                    title: banner.title,
                    detail: banner.detail,
                    mode: banner.mode,
                    onDismiss: { withAnimation(.snappy) { self.banner = nil } }
                )
            }
        }
        .animation(.snappy, value: banner != nil)
    }

    private var bangumiAccelerationBinding: Binding<Bool> {
        Binding(
            get: { settings.enableBangumiProxy },
            set: { settings.enableBangumiProxy = $0 }
        )
    }

    private var imageAccelerationBinding: Binding<String> {
        Binding(
            get: { settings.imageAcceleration },
            set: { settings.imageAcceleration = $0 }
        )
    }

    /// 开关：还没测通过的代理不让打开（照 main 的 `_setProxyEnabled`）。
    private var proxyEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.proxyEnabled },
            set: { enabled in
                if enabled, !settings.proxyConfigured {
                    flash("请先在「代理配置」里完成测试")
                    return
                }
                settings.proxyEnabled = enabled
            }
        )
    }

    /// 开关被拦下来那种瞬时确认：走同一条 banner 的 `.automatic`，3.5 秒自收。
    /// 收法、播报、叉都由 KazumiBanner 自己管（Ato 6406 §十二）。
    private func flash(_ text: String) {
        withAnimation(.snappy) {
            banner = KazumiBannerState(title: text, variant: .info, mode: .automatic)
        }
    }

    /// 开关旁边那一句：现在到底走不走。开关关着时不显示（LP 6367）。
    private var proxyState: LocalizedStringKey? {
        guard settings.proxyEnabled else {
            return nil
        }
        guard settings.proxyConfigured else {
            return "还没测试通过，先展开「代理配置」填地址并测试"
        }
        guard let url = settings.playerProxyURL else {
            return "地址格式不对，展开「代理配置」改一下"
        }
        return "播放内核和 App 内请求都走 \(url)"
    }

    /// 折叠行本身：左边「代理配置」，右边当前地址，一颗会转的箭头。
    /// 这个 VStack 里只装按钮——展开的字段是外面的兄弟行（照 WebDAV 的 credentialsRow）。
    private var proxyConfigRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isProxyConfigExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text("代理配置")
                        .foregroundStyle(Color.primary)
                    Spacer(minLength: 8)
                    // 展开时也显示摘要（LP「展开时也显示」）。
                    Text(proxyConfigSummary)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        // 大字号或窄屏时让摘要先拿到要的宽度，别第一个被截。
                        .layoutPriority(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                        .rotationEffect(.degrees(isProxyConfigExpanded ? 180 : 0))
                }
                // 44 要留着：Form 一行本来就 44，这是给整行做的点击区（Colo 5365）。
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("代理配置")
            .accessibilityValue(proxyConfigSummary)
            .accessibilityHint(isProxyConfigExpanded ? "收起代理地址" : "展开代理地址")
        }
    }

    /// 折着时右边那一句：存过就写 `host:port`，没存过写「未填写」（LP 5395）。
    /// 不带 `http://`——这个代理只支持 http，scheme 是常数（Colo 5368）。
    private var proxyConfigSummary: String {
        settings.proxyUrl.isEmpty
            ? String(localized: "未填写")
            : (ProxyURL.hostPort(settings.proxyUrl) ?? settings.proxyUrl)
    }

    /// 输入框默认值（LP 5355 / 5358）：代理地址先摆上 `http://`，测试地址先摆上
    /// Google 那个。存过的就用存过的。只在空的时候填，不覆盖用户正在改的内容
    /// ——这个页每次进来都会 onAppear，不挡一下会把改了一半的输光换掉。
    private func prefillProxyFields() {
        if proxyAddressText.isEmpty {
            proxyAddressText = settings.proxyUrl.isEmpty
                ? "http://"
                : (ProxyURL.formatted(settings.proxyUrl) ?? settings.proxyUrl)
        }
        if proxyTestText.isEmpty {
            proxyTestText = settings.proxyTestUrl.isEmpty
                ? "https://www.google.com"
                : settings.proxyTestUrl
        }
    }

    /// 地址那框的错话：没填、或格式不对。失焦和按按钮都算这一份（Colo 6391 §十）。
    private var proxyAddressProblem: String? {
        let typed = proxyAddressText.trimmingCharacters(in: .whitespacesAndNewlines)
        // 框里默认摆着 `http://`（LP 5355），只留着这个壳时不该报「格式错误」
        // ——那会让人以为自己填错了，实际是还没填。
        var bare = typed
        for prefix in ["http://", "https://"] where bare.lowercased().hasPrefix(prefix) {
            bare.removeFirst(prefix.count)
        }
        if bare.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请填入代理地址"
        }
        return ProxyURL.formatted(typed) == nil ? "格式错误，请使用 http://host:port 格式" : nil
    }

    /// 照 main 的 `saveAndTest`：校验 → 存地址与测试地址 → 清「已配置」→
    /// 开开关 → 真发一次请求；通了才把「已配置」置回去，不通就把开关关回去。
    private func saveAndTestProxy() {
        let typed = proxyAddressText.trimmingCharacters(in: .whitespacesAndNewlines)
        proxyAddressError = proxyAddressProblem
        guard let url = ProxyURL.formatted(typed), proxyAddressError == nil else { return }

        let target = proxyTestText.trimmingCharacters(in: .whitespacesAndNewlines)
        let testURL = target.isEmpty ? "https://www.google.com" : target

        // 进行中那一行只有按钮（Ato 6398 二）：结果走顶部提示条，测出来才弹。
        isProxyTesting = true
        Task { @MainActor in
            let ok = await ProxyURL.test(proxy: url, target: testURL)
            isProxyTesting = false
            // Ato 6376：进行中只出现在按钮上，设置值等测出结果再落，
            // 测试期间下面那行小字保持不变。
            settings.proxyUrl = url
            settings.proxyTestUrl = testURL
            settings.proxyEnabled = true
            if ok {
                settings.proxyConfigured = true
                withAnimation(.snappy) {
                    banner = KazumiBannerState(
                        title: "连接正常",
                        variant: .success
                    )
                }
                KazumiLogBuffer.network("代理测试通过 \(ProxyURL.formatted(url) ?? url)")
            } else {
                settings.proxyConfigured = false
                settings.proxyEnabled = false
                withAnimation(.snappy) {
                    banner = KazumiBannerState(
                        title: "连接失败",
                        detail: "检查地址和端口，或确认代理软件已启动"
                    )
                }
                KazumiLogBuffer.network("代理测试失败 \(ProxyURL.formatted(url) ?? url) -> \(testURL)")
            }
        }
    }
}

// MARK: - 更新设置

struct UpdateSettingsScreen: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            Section {
                Group {
                    Toggle("应用更新", isOn: autoUpdateBinding)
                    Toggle("规则更新", isOn: pluginUpdateBinding)
                }
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            } header: {
                Text("启动时检查更新")
            } footer: {
                Text("应用更新会在启动时比对最新版本并提示更新日志；规则更新会检查已安装规则的版本。")
            }
            Section("应用") {
                Group {
                    LabeledContent("当前版本", value: KazumiAppInfo.fullVersion)
                    LabeledContent("规则 API 级别", value: "\(KazumiAppInfo.ruleAPILevel)")
                }
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            }
        }
        .kazumiSettingsDetail("更新设置")
    }

    private var autoUpdateBinding: Binding<Bool> {
        Binding(get: { settings.autoUpdateCheck }, set: { settings.autoUpdateCheck = $0 })
    }

    private var pluginUpdateBinding: Binding<Bool> {
        Binding(
            get: { settings.checkPluginUpdateOnStartup },
            set: { settings.checkPluginUpdateOnStartup = $0 }
        )
    }
}
