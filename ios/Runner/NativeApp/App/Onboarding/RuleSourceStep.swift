//
//  RuleSourceStep.swift
//  Kazumi
//
//  引导第三屏：添加番剧来源。规则仓库的简化版，只做搜索、安装和计数。
//

import SwiftUI

struct RuleSourceStep: View {
    let onSkip: () -> Void
    let onContinue: () -> Void

    @Environment(PluginsController.self) private var plugins
    @Environment(\.colorScheme) private var colorScheme

    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var searchText = ""
    @State private var busyNames: Set<String> = []
    @State private var failedNames: Set<String> = []

    /// 已装规则数：本地规则文件里有多少条，就是「已安装 N 条」的 N。
    private var installedCount: Int { plugins.pluginList.count }

    private var catalog: [PluginHTTPItem] {
        plugins.pluginHTTPList.sorted { lhs, rhs in
            if lhs.lastUpdate != rhs.lastUpdate { return lhs.lastUpdate > rhs.lastUpdate }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }

    private var items: [PluginHTTPItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return catalog }
        return catalog.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        OnboardingPage {
            VStack(alignment: .leading, spacing: 0) {
                Text("添加番剧来源")
                    .font(.largeTitle.bold())

                Text("规则决定从哪些站点搜索和播放番剧。至少安装一条规则，才能开始观看。")
                    .font(.subheadline)
                    .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)

                if isLoading {
                    VStack(spacing: 0) {
                        ForEach(0..<3, id: \.self) { index in
                            skeletonRow
                            if index < 2 { Divider().padding(.leading, 61) }
                        }
                    }
                    .background {
                        KazumiPalette.cardShape(
                            cornerRadius: KazumiPalette.cardCornerRadius,
                            scheme: colorScheme,
                            bordered: false
                        )
                    }
                    .padding(.top, 16)

                    Text("正在获取规则…")
                        .font(.footnote)
                        .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                        .padding(.top, 12)
                } else if loadFailed {
                    stateView(
                        symbol: "exclamationmark.triangle",
                        title: "无法连接规则仓库",
                        detail: "检查网络后重试。",
                        actionTitle: "重试"
                    ) {
                        Task { await load(force: true) }
                    }
                } else if catalog.isEmpty {
                    stateView(
                        symbol: "magnifyingglass",
                        title: "规则仓库里暂时没有规则",
                        detail: "稍后再试。",
                        actionTitle: nil,
                        action: nil
                    )
                } else {
                    searchField
                        .padding(.top, 14)

                    if items.isEmpty {
                        stateView(
                            symbol: "magnifyingglass",
                            title: "没有找到规则",
                            detail: "换个关键词再试试。",
                            actionTitle: nil,
                            action: nil
                        )
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                row(for: item)
                                if index < items.count - 1 {
                                    Divider().padding(.leading, 61)
                                }
                            }
                        }
                        .background {
                            KazumiPalette.cardShape(
                                cornerRadius: KazumiPalette.cardCornerRadius,
                                scheme: colorScheme,
                                bordered: false
                            )
                        }
                        .padding(.top, 14)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom) {
            OnboardingBottomBar {
                HStack(spacing: 16) {
                    Text(String(localized: "已安装 \(String(describing: installedCount)) 条"))
                        .font(.footnote)
                        .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                    Spacer(minLength: 0)
                    OnboardingPrimaryButton(
                        title: "继续",
                        isEnabled: installedCount > 0,
                        action: onContinue
                    )
                    .frame(width: 148)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("稍后再说", action: onSkip)
            }
        }
        .task {
            guard plugins.pluginHTTPList.isEmpty else { return }
            await load(force: false)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
            TextField("搜索规则", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(
            Color.secondary.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private func row(for item: PluginHTTPItem) -> some View {
        let status = plugins.pluginStatus(item)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Image(systemName: "globe.asia.australia")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                    .frame(width: 29, height: 29)
                    .background(
                        KazumiPalette.accent(for: colorScheme).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.body)
                        .lineLimit(2)
                    detailRow(item)
                        .font(.footnote)
                        .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                }

                Spacer(minLength: 8)

                if busyNames.contains(item.name) {
                    ProgressView()
                        .frame(minWidth: 64, minHeight: 44)
                } else if status == .install {
                    Button {
                        Task { await install(item) }
                    } label: {
                        Text("安装")
                            .font(.subheadline)
                            .foregroundStyle(Color.primary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous).fill(KazumiPalette.groupedRow(for: colorScheme))
                            )
                            .overlay {
                                Capsule(style: .continuous)
                                    .strokeBorder(
                                        KazumiPalette.cardStroke(for: colorScheme),
                                        lineWidth: 0.5
                                    )
                            }
                            .frame(minHeight: 44)
                            .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                } else {
                    // 跟规则仓库那屏一致：灰底灰字、不带勾。
                    Text("已安装")
                        .font(.subheadline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            KazumiPalette.secondaryText(for: colorScheme).opacity(0.16),
                            in: Capsule(style: .continuous)
                        )
                        .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                        .frame(minHeight: 44)
                        .accessibilityElement(children: .combine)
                }
            }
            if failedNames.contains(item.name) {
                Text("安装失败，请重试")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var skeletonRow: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(KazumiPalette.secondaryText(for: colorScheme).opacity(0.12))
                .frame(width: 29, height: 29)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(KazumiPalette.secondaryText(for: colorScheme).opacity(0.18))
                    .frame(width: 120, height: 14)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(KazumiPalette.secondaryText(for: colorScheme).opacity(0.12))
                    .frame(width: 164, height: 11)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在获取规则…")
    }

    private func stateView(
        symbol: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        actionTitle: LocalizedStringKey?,
        action: (() -> Void)?
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.body.weight(.semibold))
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    /// 跟 App 内规则仓库那屏同一套写法：标签图标＋版本号，时钟图标＋更新时间。
    /// 「验证」跟规则管理页一样把符号和文字放在版本号这一行，颜色同为次要色。
    /// 窄屏放不下时退回纯文字「1.2 · 8月10日」，不截断也不缩字号。
    private func detailRow(_ item: PluginHTTPItem) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                RuleMetadataLabel(text: item.version, systemImage: "tag")
                if let updated = item.updatedDateText {
                    RuleMetadataLabel(text: updated, systemImage: "clock")
                }
                if item.antiCrawlerEnabled {
                    RuleMetadataLabel(
                        text: String(localized: "验证"),
                        systemImage: "checkmark.shield"
                    )
                }
            }
            .fixedSize()

            Text(plainDetail(item))
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func plainDetail(_ item: PluginHTTPItem) -> String {
        var parts = [item.version]
        if let date = item.updatedDateText {
            parts.append(date)
        }
        if item.antiCrawlerEnabled {
            parts.append(String(localized: "验证"))
        }
        return parts.joined(separator: " · ")
    }

    private func load(force: Bool) async {
        isLoading = true
        loadFailed = false
        defer { isLoading = false }
        do {
            if force {
                _ = try await plugins.refreshPluginCatalog()
            } else {
                _ = try await plugins.ensurePluginCatalog()
            }
        } catch {
            loadFailed = true
        }
    }

    private func install(_ item: PluginHTTPItem) async {
        busyNames.insert(item.name)
        failedNames.remove(item.name)
        defer { busyNames.remove(item.name) }
        switch await plugins.tryUpdatePlugin(named: item.name) {
        case .updated, .notNewer:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .requiresNewerClient, .failed:
            failedNames.insert(item.name)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}
