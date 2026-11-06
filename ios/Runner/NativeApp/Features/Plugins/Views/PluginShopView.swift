//
//  PluginShopView.swift
//  Kazumi
//
//  规则仓库（对应 lib/pages/plugin_editor/plugin_shop_page.dart）：
//  安装 / 更新 / 已安装三种状态，按仓库更新时间倒序，支持搜索与下拉刷新。
//

import SwiftUI

struct PluginShopView: View {
    @Environment(PluginsController.self) private var plugins
    @Environment(\.colorScheme) private var colorScheme

    @State private var isLoading = false
    @State private var busyItems: Set<String> = []
    @State private var errorMessage: String?
    @State private var toast: String?

    /// 仓库列表：按仓库里的更新时间倒序，新的在上；同一时间按名字排，免得每次进来顺序飘。
    private var sortedItems: [PluginHTTPItem] {
        plugins.pluginHTTPList.sorted { lhs, rhs in
            if lhs.lastUpdate != rhs.lastUpdate { return lhs.lastUpdate > rhs.lastUpdate }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }

    /// 目录里的全部规则（LP 2519：规则不多，不做搜索框）。
    private var filteredItems: [PluginHTTPItem] { sortedItems }

    var body: some View {
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
                    ContentUnavailableView(
                        "规则目录为空",
                        systemImage: "shippingbox",
                        description: Text("下拉刷新重试。")
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
        // 顶部滚动边缘：列表顶部用渐进模糊（.soft）。
        .scrollEdgeEffectStyle(.soft, for: .top)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(KazumiPalette.heroBackground(for: colorScheme).ignoresSafeArea())
        .navigationTitle("规则仓库")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refresh(force: true) }
                } label: {
                    if isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isLoading)
                .accessibilityLabel("刷新")
            }
        }
        .refreshable { await refresh(force: true) }
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

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    if item.antiCrawlerEnabled {
                        Label("验证", systemImage: "checkmark.shield")
                            .labelStyle(.iconOnly)
                            .font(.caption)
                            .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                    }
                }
                let metaLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                    : AnyLayout(HStackLayout(spacing: 10))
                metaLayout {
                    Text(item.author)
                    Label(item.version, systemImage: "tag")
                    if let updated = item.updatedDateText {
                        Label(updated, systemImage: "clock")
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
