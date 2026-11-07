//
//  PluginShopView.swift
//  Kazumi
//
//  规则仓库（对应 lib/pages/plugin_editor/plugin_shop_page.dart）：
//  安装 / 更新 / 已安装三种状态，按仓库更新时间倒序，支持搜索与下拉刷新。
//

import SwiftUI

/// 规则仓库顶部的三种目录筛选。
enum PluginShopFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case installed
    case update

    var id: Self { self }

    var title: String {
        switch self {
        case .all: String(localized: "全部")
        case .installed: String(localized: "已安装")
        case .update: String(localized: "可更新")
        }
    }

    func includes(_ status: PluginCatalogItemStatus) -> Bool {
        switch self {
        case .all:
            true
        case .installed:
            status == .installed || status == .update
        case .update:
            status == .update
        }
    }
}

extension PluginHTTPItem {
    /// 仓库搜索同时查规则名与作者；空白搜索词保持全部结果。
    func matchesCatalogSearch(_ rawQuery: String) -> Bool {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return name.localizedStandardContains(query) || author.localizedStandardContains(query)
    }
}

struct PluginShopView: View {
    @Environment(PluginsController.self) private var plugins
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var isLoading = false
    @State private var busyItems: Set<String> = []
    @State private var errorMessage: String?
    @State private var toast: String?
    @State private var selectedFilter: PluginShopFilter = .all
    @State private var query = ""
    @State private var isSearching = false
    @FocusState private var searchFocused: Bool

    /// 仓库列表：按仓库里的更新时间倒序，新的在上；同一时间按名字排，免得每次进来顺序飘。
    private var sortedItems: [PluginHTTPItem] {
        plugins.pluginHTTPList.sorted { lhs, rhs in
            if lhs.lastUpdate != rhs.lastUpdate { return lhs.lastUpdate > rhs.lastUpdate }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }

    /// 先按安装状态筛选，再在规则名和作者里搜索。
    private var filteredItems: [PluginHTTPItem] {
        sortedItems.filter { item in
            selectedFilter.includes(plugins.pluginStatus(item)) && item.matchesCatalogSearch(query)
        }
    }

    /// 空状态随当前 tab 变化：搜索无结果、目录为空、未安装、无更新各说各的。
    private var emptyState: EmptyStateContent {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return EmptyStateContent(
                title: "没有找到规则",
                systemImage: "magnifyingglass",
                description: "换个关键词再试试。"
            )
        }
        if plugins.pluginHTTPList.isEmpty {
            return EmptyStateContent(
                title: "规则目录为空",
                systemImage: "shippingbox",
                description: "下拉刷新重试。"
            )
        }
        switch selectedFilter {
        case .all:
            return EmptyStateContent(
                title: "规则目录为空",
                systemImage: "shippingbox",
                description: "下拉刷新重试。"
            )
        case .installed:
            return EmptyStateContent(
                title: "还没有安装规则",
                systemImage: "tray",
                description: "去「全部」里安装一条规则。"
            )
        case .update:
            return EmptyStateContent(
                title: "没有可更新的规则",
                systemImage: "checkmark.circle",
                description: "所有规则都是最新版本。"
            )
        }
    }

    private struct EmptyStateContent {
        let title: LocalizedStringKey
        let systemImage: String
        let description: LocalizedStringKey
    }

    /// 跟大标题同一档左边距：iPhone 16，iPad 20。
    private var pageMargin: CGFloat {
        horizontalSizeClass == .compact ? 16 : 20
    }

    var body: some View {
        VStack(spacing: 0) {
            controlBar
                .padding(.horizontal, pageMargin)
                .padding(.top, 4)
                .padding(.bottom, 8)

            List {
                if isLoading && plugins.pluginHTTPList.isEmpty {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("正在获取规则目录…")
                            Spacer()
                        }
                        .padding(.vertical, 24)
                    }
                } else if filteredItems.isEmpty {
                    Section {
                        let state = emptyState
                        ContentUnavailableView(
                            state.title,
                            systemImage: state.systemImage,
                            description: Text(state.description)
                        )
                    }
                } else {
                    Section {
                        ForEach(filteredItems) { item in
                            PluginCatalogRow(
                                item: item,
                                status: plugins.pluginStatus(item),
                                isBusy: busyItems.contains(item.id)
                            ) {
                                Task { await install(item) }
                            }
                        }
                    } footer: {
                        if KazumiEndpoints.customPluginShop == nil {
                            Text(String(localized: "共 \(String(describing: filteredItems.count)) 条规则，数据来自 KazumiRules 仓库。"))
                        } else {
                            Text(String(localized: "共 \(String(describing: filteredItems.count)) 条规则。"))
                        }
                    }
                }
            }
            .contentMargins(.top, 0, for: .scrollContent)
            .listSectionSpacing(.custom(0))
            // 顶部滚动边缘：列表顶部用渐进模糊（.soft）。
            .scrollEdgeEffectStyle(.soft, for: .top)
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .refreshable { await refresh(force: true) }
        }
        .background(KazumiPalette.heroBackground(for: colorScheme).ignoresSafeArea())
        .navigationTitle("规则仓库")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    RulesRepositoryScreen()
                } label: {
                    Image(systemName: "link.badge.plus")
                        .foregroundStyle(Color.primary)
                }
                .accessibilityLabel("自定义规则仓库")
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.callout)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .kazumiGlassCapsule()
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .alert("操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task { await refresh(force: false) }
        // 搜索框是在 isSearching 切换后才进入布局，等它出现再申请焦点。
        .onChange(of: isSearching) { _, value in
            searchFocused = value
        }
    }

    /// 大标题下面的控制条。宽度够时在分段筛选右侧放搜索；
    /// 窄屏优先保留筛选，和追番页一样用 ViewThatFits 自动让位。
    @ViewBuilder
    private var controlBar: some View {
        if isSearching {
            searchRow
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    filterPicker
                    Spacer(minLength: 0)
                    searchButton
                }
                filterPicker
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
        }
    }

    private var filterPicker: some View {
        Picker("排序与筛选", selection: $selectedFilter) {
            ForEach(PluginShopFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 210)
    }

    private var searchButton: some View {
        Button {
            withAnimation(.smooth(duration: 0.32)) { isSearching = true }
            searchFocused = true
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .regular))
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
                .kazumiGlassCapsule(interactive: true)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("搜索规则")
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Color.secondary)
                TextField("搜索规则", text: $query)
                    .font(.subheadline)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.secondary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空搜索")
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .frame(maxWidth: .infinity)
            .kazumiGlassCapsule()
            .frame(minHeight: 44)

            Button("取消") {
                query = ""
                searchFocused = false
                withAnimation(.smooth(duration: 0.32)) { isSearching = false }
            }
            .font(.subheadline)
            .foregroundStyle(Color.primary)
            .buttonStyle(.plain)
            .frame(minHeight: 44)
        }
        .frame(minHeight: 44)
        .animation(.smooth(duration: 0.32), value: isSearching)
    }

    private func refresh(force: Bool) async {
        isLoading = true
        defer { isLoading = false }
        do {
            if force {
                _ = try await plugins.refreshPluginCatalog()
            } else {
                _ = try await plugins.ensurePluginCatalog()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func install(_ item: PluginHTTPItem) async {
        busyItems.insert(item.id)
        defer { busyItems.remove(item.id) }
        let result = await plugins.tryUpdatePlugin(named: item.name)
        switch result {
        case .updated:
            showToast(String(localized: "已安装 \(String(describing: item.name))"))
        case .notNewer:
            showToast(String(localized: "\(String(describing: item.name)) 已是最新版本"))
        case .requiresNewerClient:
            errorMessage = String(localized: "规则「\(String(describing: item.name))」需要更高版本的客户端")
        case .failed:
            errorMessage = String(localized: "安装「\(String(describing: item.name))」失败，请稍后重试")
        }
    }

    private func showToast(_ message: String) {
        withAnimation(.snappy) { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.snappy) { toast = nil }
        }
    }
}

/// 规则条目元数据的「图标＋文字」原子组：组内 3 点，组间由外层统一留更大的间距。
/// 不用系统 Label 的默认布局，避免版本号或日期视觉上贴到隔壁图标。
struct RuleMetadataLabel: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)
            Text(text)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(text))
    }
}

private struct PluginCatalogRow: View {
    let item: PluginHTTPItem
    let status: PluginCatalogItemStatus
    let isBusy: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // 辅助功能字号下，尾部那颗按钮跟标题抢宽度，把「已安装」挤成一字一行。
        // 改成上下：文字在上，按钮整行在下。默认字号不变。
        let rowLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        return rowLayout {
            Image(systemName: "globe.asia.australia")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                .frame(width: 29, height: 29)
                .background(
                    KazumiPalette.accent(for: colorScheme).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 5) {
                let titleLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3))
                    : AnyLayout(HStackLayout(spacing: 8))
                titleLayout {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .layoutPriority(1)
                    if !item.author.isEmpty {
                        Text(item.author)
                            .font(.caption)
                            .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                            .lineLimit(1)
                    }
                }
                let metaLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                    : AnyLayout(HStackLayout(spacing: 12))
                metaLayout {
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
                .font(.caption)
                .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
            }
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 0)
            }
            if isBusy {
                ProgressView()
            } else {
                Button(action: action) {
                    Text(buttonTitle)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(buttonTint.opacity(0.16), in: Capsule())
                        // LP 2026-10-24：「安装 / 更新」的字不要主题色，跟正文一个颜色；
                        // 只有「已安装」这个不可点的状态留灰。
                        .foregroundStyle(
                            status == .installed
                                ? KazumiPalette.secondaryText(for: colorScheme)
                                : Color.primary
                        )
                }
                .buttonStyle(.plain)
                .disabled(status == .installed)
            }
        }
        .padding(.vertical, 2)
    }

    private var buttonTitle: String {
        switch status {
        case .install: String(localized: "安装")
        case .installed: String(localized: "已安装")
        case .update: String(localized: "更新")
        }
    }

    private var buttonTint: Color {
        switch status {
        case .install, .update: KazumiPalette.accent(for: colorScheme)
        case .installed: KazumiPalette.secondaryText(for: colorScheme)
        }
    }
}
