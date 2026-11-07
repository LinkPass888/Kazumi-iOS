//
//  RulesRepositoryScreen.swift
//  Kazumi
//
//  自定义规则仓库面板（design-repo.md 定稿）。
//
//  单页表单：一个 URL 输入框、一颗「添加」、两块分组列表（内置 / 自定义）、
//  一套空态／预览中／失败／成功回执。自定义仓库可删，内置仓库不可删。
//
//  形状照相邻的「规则管理页」v4：白组 r12、无描边、48 行、26×26 强调色图标框、
//  尾随 ⋯、空态一句话。不新增颜色、字体、资产、导航层级。
//
//  字逐字照抄 Camo 7719（design-repo.md §3），不改字、不造同义句。
//

import SwiftUI
import UIKit

struct RulesRepositoryScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(PluginsController.self) private var plugins

    @State private var repositories = RulesRepositoryStore()
    @State private var addressText = ""
    @State private var preview: PreviewState = .empty
    @State private var httpsError: String?
    @State private var pendingRemoval: RulesRepository?
    @State private var banner: KazumiBannerState?
    @State private var previewTask: Task<Void, Never>?
    @FocusState private var addressFocused: Bool

    /// 预览卡四态（design-repo.md §4.3）。
    private enum PreviewState: Equatable {
        case empty
        case loading
        case ready(name: String, ruleCount: Int)
        case failed
    }

    private var trimmedAddress: String {
        addressText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isHTTPS: Bool {
        trimmedAddress.lowercased().hasPrefix("https://")
    }

    /// 「添加」禁用条件：地址为空、非 https、正在预览、预览失败。
    private var canAdd: Bool {
        guard !trimmedAddress.isEmpty, isHTTPS else { return false }
        if case .ready = preview { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                addSection
                builtInSection
                customSection
            }
            .padding(.horizontal, pageMargin)
            .padding(.top, 16)
            .padding(.bottom, 32)
            .frame(maxWidth: contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(KazumiPalette.groupedBackground(for: colorScheme).ignoresSafeArea())
        .navigationTitle("自定义规则仓库")
        .navigationBarTitleDisplayMode(.large)
        .scrollDismissesKeyboard(.interactively)
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
        .confirmationDialog(
            "移除这个自定义规则仓库？",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("移除", role: .destructive) {
                if let target = pendingRemoval { remove(target) }
                pendingRemoval = nil
            }
            Button("取消", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("只移除这个仓库地址，不会删除已缓存的规则")
        }
        .onAppear {
            repositories.activate()
            addressText = repositories.active?.url ?? ""
        }
        .onChange(of: addressText) { _, _ in
            httpsError = nil
            preview = .empty
            previewTask?.cancel()
            // 填完一条 https 地址就自动预览一次；打字途中不反复打网络。
            guard isHTTPS, trimmedAddress.count > 8 else { return }
            previewTask = Task {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                startPreview()
            }
        }
    }

    // MARK: 宽度三档

    /// 窄档页边 16；宽档 / iPad 页边 20，内容收窄到 720 居中。
    private var pageMargin: CGFloat {
        horizontalSizeClass == .compact ? 16 : 20
    }

    private var contentMaxWidth: CGFloat {
        horizontalSizeClass == .compact ? .infinity : 720
    }

    // MARK: ① 添加区

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("添加仓库")

            VStack(alignment: .leading, spacing: 8) {
                TextField("输入仓库地址（https://…）", text: $addressText)
                    .font(.body)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.URL)
                    .submitLabel(.done)
                    .focused($addressFocused)
                    .padding(.horizontal, 8)
                    .frame(height: 36)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(uiColor: .quaternaryLabel).opacity(0.12))
                    }
                    .overlay {
                        // 聚焦环是全屏唯一一道描边。
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                KazumiPalette.accent(for: colorScheme),
                                lineWidth: addressFocused ? 1.5 : 0
                            )
                    }

                if let httpsError {
                    footnoteRow(httpsError, symbol: "exclamationmark.triangle")
                } else {
                    footnoteRow("只支持 HTTPS；添加前会先预览仓库内容", symbol: nil)
                }
            }

            previewCard

            Button {
                addRepository()
            } label: {
                Text("添加")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(KazumiPalette.accent(for: colorScheme))
            .foregroundStyle(KazumiPalette.onAccent(for: colorScheme))
            .disabled(!canAdd)
        }
        .padding(16)
        .background(groupBackground)
    }

    @ViewBuilder
    private var previewCard: some View {
        let accent = KazumiPalette.accent(for: colorScheme)
        let secondary = KazumiPalette.secondaryText(for: colorScheme)

        switch preview {
        case .empty:
            HStack(spacing: 8) {
                Image(systemName: "square.dashed")
                    .font(.system(size: 18))
                    .foregroundStyle(KazumiPalette.tertiaryText(for: colorScheme))
                Text("粘贴地址后就可以预览")
                    .font(.footnote)
                    .foregroundStyle(secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(previewBackground)

        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在预览仓库…")
                    .font(.footnote)
                    .foregroundStyle(secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(previewBackground)

        case .ready(let name, let ruleCount):
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("仓库可添加")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                    // 仓库自己的名称与规则数，来自仓库返回数据，不造固定句。
                    Text("\(name) · \(ruleCount) 条规则")
                        .font(.caption)
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(previewBackground)

        case .failed:
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24))
                    .foregroundStyle(accent)
                Text("预览失败：连不上这个地址，或返回的不是规则仓库")
                    .font(.footnote)
                    .foregroundStyle(secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Button("重试") { startPreview() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .overlay { Capsule().strokeBorder(accent, lineWidth: 1) }
                    .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(previewBackground)
        }
    }

    // MARK: ② 内置仓库

    private var builtInSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("内置仓库")
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    iconTile("shippingbox")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(RulesRepositoryStore.builtInName)
                            .font(.body)
                            .foregroundStyle(Color.primary)
                            .lineLimit(2)
                        Text("随 Kazumi 提供")
                            .font(.caption)
                            .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                }
                .frame(minHeight: 48)
                .padding(.horizontal, 16)
                .accessibilityHint("内置仓库不能删除")
            }
            .background(groupBackground)
        }
    }

    // MARK: ③ 自定义仓库

    private var customSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("自定义仓库")

            if repositories.custom.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "square.dashed")
                        .font(.system(size: 44))
                        .foregroundStyle(KazumiPalette.tertiaryText(for: colorScheme))
                    Text("还没有添加自定义规则仓库")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.primary)
                    Text("把上面的仓库地址粘贴进来就能添加")
                        .font(.footnote)
                        .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, minHeight: 140)
                .padding(16)
                .background(groupBackground)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(repositories.custom.enumerated()), id: \.element.id) { index, repository in
                        if index > 0 {
                            Divider().padding(.leading, 50)
                        }
                        customRow(repository)
                    }
                }
                .background(groupBackground)
            }
        }
    }

    private func customRow(_ repository: RulesRepository) -> some View {
        HStack(spacing: 12) {
            iconTile("shippingbox")
            VStack(alignment: .leading, spacing: 2) {
                Text(repository.displayName)
                    .font(.body)
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                Text(repository.url)
                    .font(.caption)
                    .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                    .lineLimit(1)
                    // 长 URL 中间省略：保留域名与尾部文件名，不截掉协议头。
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Menu {
                Button("移除", role: .destructive) {
                    pendingRemoval = repository
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17))
                    .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("\(repository.displayName) 的更多操作")
        }
        .frame(minHeight: 48)
        .padding(.horizontal, 16)
    }

    // MARK: 零件

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
    }

    private func footnoteRow(_ text: String, symbol: String?) -> some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(KazumiPalette.accent(for: colorScheme))
            }
            Text(text)
                .font(.footnote)
                .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
        }
    }

    private func iconTile(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 18))
            .foregroundStyle(KazumiPalette.accent(for: colorScheme))
            .frame(width: 26, height: 26)
    }

    private var groupBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(KazumiPalette.groupedRow(for: colorScheme))
    }

    private var previewBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(KazumiPalette.groupedBackground(for: colorScheme))
    }

    // MARK: 动作

    private func startPreview() {
        guard isHTTPS else {
            httpsError = "请输入以 https:// 开头的地址"
            preview = .empty
            return
        }
        preview = .loading
        let target = trimmedAddress
        Task {
            do {
                let result = try await RulesRepositoryPreview.fetch(url: target)
                preview = .ready(name: result.name, ruleCount: result.ruleCount)
            } catch {
                preview = .failed
            }
        }
    }

    private func addRepository() {
        guard case .ready(let name, let ruleCount) = preview else { return }
        let target = trimmedAddress
        repositories.add(
            RulesRepository(id: target, url: target, name: name, ruleCount: ruleCount)
        )
        // 仓库列表变了，规则目录要按新地址重拉。
        Task {
            _ = try? await plugins.refreshPluginCatalog()
            banner = KazumiBannerState(title: "已添加自定义规则仓库", variant: .success)
        }
        addressText = ""
        preview = .empty
    }

    private func remove(_ repository: RulesRepository) {
        repositories.remove(repository)
        Task {
            _ = try? await plugins.refreshPluginCatalog()
            banner = KazumiBannerState(title: "已移除自定义规则仓库", variant: .success)
        }
    }
}
