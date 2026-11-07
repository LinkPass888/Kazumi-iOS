//
//  PluginListView.swift
//  Kazumi
//
//  规则管理主界面（对应 lib/pages/plugin_editor/plugin_view_page.dart）。
//  列表、排序、批量删除、导入导出、检查更新与规则商店入口。
//

import SwiftUI
import UniformTypeIdentifiers

struct PluginListView: View {
    @Environment(PluginsController.self) private var plugins
    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var isShowingImportSheet = false
    @State private var isShowingShop = false
    /// 新建规则：推入编辑器并带上模板。
    @State private var isShowingNewRule = false
    @State private var selectedRule: Plugin?
    /// 正在登录站点的规则（LP 5427）。
    @State private var loginRule: Plugin?
    @State private var pendingDeletion: Plugin?
    /// 批量删除的二次确认：确认前一条都不删，底下的计数也不跟着跳。
    @State private var pendingBatchDeletion = false
    @State private var isEditingSelection = false
    @State private var selection: Set<String> = []
    @State private var isUpdating = false
    @State private var updateSummary: String?
    @State private var errorMessage: String?
    /// 搜索关键词：按规则名 / 站点地址 / 作者过滤。
    /// 「全部／可更新」筛选，作用于已安装的规则列表。
    @State private var ruleFilter: RuleFilter = .all

    /// 胶囊筛选后的列表：全部是装了的所有规则，可更新只留仓库里有新版本的。
    private var statusFilteredPlugins: [Plugin] {
        switch ruleFilter {
        case .all:
            plugins.pluginList
        case .updatable:
            plugins.pluginList.filter { plugins.pluginUpdateStatus($0) == .updatable }
        }
    }

    /// 删除确认弹窗的标题：批量与单条共用，按当前待删状态取值。
    private var deletionDialogTitle: String {
        if pendingBatchDeletion {
            return String(localized: "删除选中的 \(selection.count) 条规则？")
        }
        if let pendingDeletion {
            return String(localized: "删除规则「\(pendingDeletion.name)」？")
        }
        return String(localized: "删除规则？")
    }

    private var deletionDialogPresented: Binding<Bool> {
        Binding(
            get: { pendingBatchDeletion || pendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingBatchDeletion = false
                    pendingDeletion = nil
                }
            }
        )
    }

    /// 删除确认弹窗锚在哪一行：单条就是那一行，批量是待删里最上面那条。
    private var deletionAnchorID: String? {
        if let pendingDeletion { return pendingDeletion.id }
        if pendingBatchDeletion {
            return visiblePlugins.first { selection.contains($0.name) }?.id
        }
        return nil
    }

    private func performPendingDeletion() {
        let single = pendingDeletion
        let isBatch = pendingBatchDeletion
        pendingDeletion = nil
        pendingBatchDeletion = false
        if isBatch {
            let targets = plugins.pluginList.filter { selection.contains($0.name) }
            Task { await remove(targets) }
        } else if let single {
            Task { await remove([single]) }
        }
    }

    private func cancelPendingDeletion() {
        pendingDeletion = nil
        pendingBatchDeletion = false
    }

    /// 页面上列的规则（LP 2519：规则不多，不做搜索框，直接按状态筛选后的全量）。
    private var visiblePlugins: [Plugin] { statusFilteredPlugins }

    var body: some View {
        List {
            // 操作组：规则仓库在上（真推一页，给箭头），添加规则在下（弹菜单，不给箭头）。
            // 两行同一个 Section：只一条 0.5 分隔线，看成一件事的两种做法。
            // 行高按 48 定在行本身——内容高度和 rowInsets 都试过，List 会自己撑到 52。
            Section {
                Group {
                    Button {
                        isShowingShop = true
                    } label: {
                        HStack(spacing: 0) {
                            // 这两行是页面里的动作入口，字跟图标都用正文色，不跟主题色走。
                            // 必须写 Color.primary：光写 .primary 是「当前前景色的主档」，
                            // 而 List 里 Button 的前景就是主题色，等于没改。
                            Label("规则仓库", systemImage: "shippingbox")
                                .foregroundStyle(Color.primary)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .frame(minHeight: 48)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))

                    Menu {
                        addRuleMenuItems
                    } label: {
                        Label("添加规则", systemImage: "plus")
                            .foregroundStyle(Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .frame(minHeight: 48)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                }
                // Colo 3532：hero 底上的 List 行统一用 groupedRow 实面，不靠系统动态色。
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
            }

            // 添加规则下面一排三个胶囊：前两个筛列表，第三个是动作。
            Section {
                // Colo 6547：三颗一起放不进辅助功能字号（110+151+192+间距=469 > 370），
                // 把「更新全部」这颗动作挪到筛选下面单独占一整行，整宽描边；
                // 筛选两颗留在原行、不折行。默认字号三颗照旧并排。
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(RuleFilter.allCases) { filter in
                            filterCapsule(filter)
                        }
                        if !dynamicTypeSize.isAccessibilitySize {
                            Spacer(minLength: 8)
                            updateAllCapsule(fullWidth: false)
                        }
                    }
                    if dynamicTypeSize.isAccessibilitySize {
                        updateAllCapsule(fullWidth: true)
                    }
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16))
                // Colo 3532：原来清成透明让 hero 底透出来，现改为 groupedRow 白面（深色 #1C1C1E）。
                .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
                .listRowSeparator(.hidden)
            }

            if plugins.pluginList.isEmpty {
                Section {
                    ContentUnavailableView(
                        "还没有安装规则",
                        systemImage: "puzzlepiece.extension"
                    )
                    .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
                    .listRowSeparator(.hidden)
                }
            } else if visiblePlugins.isEmpty {
                Section {
                    ContentUnavailableView(
                        "没有可更新的规则",
                        systemImage: "checkmark.circle"
                    )
                    .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
                }
            } else {
                Section {
                    ForEach(visiblePlugins) { plugin in
                        row(plugin)
                            .listRowBackground(KazumiPalette.groupedRow(for: colorScheme))
                    }
                    .onMove(perform: move)
                } footer: {
                    Text(footerText)
                }
            }
        }
        // 胶囊行上下不空：默认的 section 间距（约 35）压到 12，三行读成一组。
        .listSectionSpacing(.custom(12))
        // 行高 48：List 自己有个最小行高，把内容改成多少都压不下来，只能改那个下限。
        .environment(\.defaultMinListRowHeight, 48)
        .scrollContentBackground(.hidden)
        .background(KazumiPalette.heroBackground(for: colorScheme).ignoresSafeArea())
        .navigationTitle("规则管理")
        .navigationBarTitleDisplayMode(.large)
        // Colo 7611：这一屏原来只有一层自绘实色，没有 .soft。撤掉实色要补上 .soft，
        // 否则滚起来「規則倉庫」「新增規則」又从大标题底下透上来。
        .scrollEdgeEffectStyle(.soft, for: .top)
        .toolbar { toolbarContent }
        .navigationDestination(isPresented: Binding(
            get: { selectedRule != nil },
            set: { if !$0 { selectedRule = nil } }
        )) {
            if let selectedRule {
                PluginEditorView(original: selectedRule)
            }
        }
        .navigationDestination(isPresented: $isShowingShop) {
            PluginShopView()
        }
        .navigationDestination(isPresented: $isShowingNewRule) {
            PluginEditorView(original: Plugin.template(apiLevel: KazumiAppInfo.ruleAPILevel))
        }
        .sheet(item: $loginRule) { plugin in
            RuleLoginScreen(plugin: plugin)
        }
        .sheet(isPresented: $isShowingImportSheet) {
            PluginImportSheet { summary in
                await applyImport(summary)
            }
        }
        // 规则导入不再用 .fileImporter：LP 5216 报的「备份能选文件、规则不行」
        // 就是这两条路不一样——.fileImporter 在侧载包上点文件不响应，
        // 只有直接呈现 UIDocumentPickerViewController 才点得动。
        .alert("提示", isPresented: Binding(
            get: { updateSummary != nil },
            set: { if !$0 { updateSummary = nil } }
        )) {
            Button("好", role: .cancel) { updateSummary = nil }
        } message: {
            Text(updateSummary ?? "")
        }
        .alert("操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        // 删除先问一句：两条删除路径（批量、单条左滑/菜单）共用一个弹窗，
        // 弹窗锚到“待删里最上面那条规则”上（见 row(_:)），所以位置在那一行旁边，
        // 而不是吸在屏幕顶部。问完之前列表、行高和下面那行计数都不动。
        .onAppear {
            if plugins.pluginList.isEmpty { plugins.load() }
        }
    }
    // MARK: - 行

    /// 单行规则：点击进编辑，右侧溢出菜单（原版 KazumiMenuButton）。
    @ViewBuilder
    private func row(_ plugin: Plugin) -> some View {
        HStack(spacing: 8) {
            Button {
                if isEditingSelection {
                    toggle(plugin)
                } else {
                    selectedRule = plugin
                }
            } label: {
                PluginRowView(
                    plugin: plugin,
                    status: plugins.pluginUpdateStatus(plugin),
                    isSearchValid: plugins.validityTracker.isSearchValid(plugin.name),
                    isSelecting: isEditingSelection,
                    isSelected: selection.contains(plugin.name)
                )
            }
            .buttonStyle(.plain)

            if !isEditingSelection {
                rowMenu(plugin)
            }
        }
        .swipeActions(edge: .trailing) {
            // 左滑只记录待删除规则，确认前不删行、不预播删除动画。
            // 这里不能用 role: .destructive：那样一点按钮 iOS 就先播删除动画，
            // 这一行被收掉、下面的规则整片往上跑，二次确认还没问就先动了。
            // 只染红、不带走删除语义，点了只收左滑并把弹窗叫出来。
            Button {
                pendingDeletion = plugin
            } label: {
                Label("删除", systemImage: "trash")
            }
            .tint(.red)
        }
        // 弹窗只挂在待删里最上面那一行，位置就落在那一行旁边；批量也走这一个。
        // 只挂一份：每一行都挂同一个 confirmationDialog 时弹窗会弹不出来（试过五条规则，三次全不弹）。
        .modifier(DeletionDialogAnchor(
            isAnchor: plugin.id == deletionAnchorID,
            title: deletionDialogTitle,
            isPresented: deletionDialogPresented,
            onDelete: performPendingDeletion,
            onCancel: cancelPendingDeletion
        ))
    }

    /// 行内溢出菜单，条目与原版 plugin_view_page 的 _menu 一一对应。
    private func rowMenu(_ plugin: Plugin) -> some View {
        Menu {
            Button {
                selectedRule = plugin
            } label: {
                Label("编辑规则", systemImage: "square.and.pencil")
            }
            // 原版 _menu 的第二项就是「测试规则」，跳独立的测试页。
            Button {
                router.push(.pluginTest(ruleID: plugin.name))
            } label: {
                Label("测试规则", systemImage: "testtube.2")
            }
            Button {
                Task { await checkUpdate(plugin) }
            } label: {
                Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(isUpdating)
            Button {
                UIPasteboard.general.string = PluginImportExport.ruleLink(for: plugin)
                updateSummary = String(localized: "已复制「\(plugin.name)」的分享链接")
            } label: {
                Label("分享规则", systemImage: "square.and.arrow.up")
            }
            // 上移/下移去掉了（LP 5427）：规则顺序在列表里直接拖动就有，菜单里重复。
            Divider()
            // 需要登录才能播的规则：在 App 里打开站点登录，Cookie 留给规则用（LP 5427）。
            if !plugin.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    loginRule = plugin
                } label: {
                    Label("登录", systemImage: "person.crop.circle")
                }
                Divider()
            }
            Button(role: .destructive) {
                pendingDeletion = plugin
            } label: {
                Label("删除规则", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 34, height: 34)
                .hitTarget44()
        }
        .accessibilityLabel(String(localized: "\(plugin.name) 的更多操作"))
    }

    private var footerText: String {
        let updatable = plugins.updatablePluginCount
        if updatable > 0 {
            return String(localized: "共 \(String(describing: plugins.pluginList.count)) 条规则，\(String(describing: updatable)) 条可更新。")
        }
        return String(localized: "共 \(String(describing: plugins.pluginList.count)) 条规则。")
    }

    /// 单条规则检查更新。
    private func checkUpdate(_ plugin: Plugin) async {
        isUpdating = true
        defer { isUpdating = false }
        let result = await plugins.tryUpdatePlugin(named: plugin.name)
        switch result {
        case .updated:
            updateSummary = String(localized: "已更新「\(plugin.name)」")
        case .notNewer:
            updateSummary = String(localized: "「\(plugin.name)」已是最新版本")
        case .requiresNewerClient:
            updateSummary = String(localized: "「\(plugin.name)」需要更高版本的客户端")
        case .failed:
            errorMessage = String(localized: "检查「\(plugin.name)」更新失败，请稍后重试")
        }
    }

    // MARK: - 工具栏

    /// 「添加规则」弹出的三项（唯一出处）。仓库已经在屏上那行了，同一件事不给两个入口。
    @ViewBuilder
    private var addRuleMenuItems: some View {
        Button {
            isShowingImportSheet = true
        } label: {
            Label("从剪贴板导入", systemImage: "doc.on.clipboard")
        }
        Button {
            pickRuleFileFromDisk()
        } label: {
            Label("从文件导入", systemImage: "folder.badge.plus")
        }
        Divider()
        Button {
            isShowingNewRule = true
        } label: {
            Label("新建规则", systemImage: "square.and.pencil")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if isEditingSelection {
                // 编辑态三颗的顺序（LP 定）：最左全选、中间删除、最右完成。
                let allSelected = selection.count == plugins.pluginList.count
                Button {
                    if allSelected {
                        selection.removeAll()
                    } else {
                        selection = Set(plugins.pluginList.map(\.name))
                    }
                } label: {
                    Text(allSelected ? String(localized: "取消全选") : String(localized: "全选"))
                        .foregroundStyle(Color.primary)
                }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if isEditingSelection {
                let count = selection.count
                Button(count == 0 ? "删除" : String(localized: "删除 \(count)"), role: .destructive) {
                    // 只挂上确认框，确认之前不去动列表。
                    pendingBatchDeletion = true
                }
                .disabled(selection.isEmpty)
                Button {
                    isEditingSelection = false
                    selection.removeAll()
                } label: {
                    Text("完成")
                        .foregroundStyle(Color.primary)
                }
            } else {
                // 菜单去掉：批量编辑单独一颗圆按钮；更新规则的动作在下面那排胶囊里。
                Button {
                    isEditingSelection = true
                } label: {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(
                            plugins.pluginList.isEmpty
                                ? KazumiPalette.tertiaryText(for: colorScheme)
                                : Color.primary
                        )
                }
                .disabled(plugins.pluginList.isEmpty)
                .accessibilityLabel("批量编辑")
            }
        }
    }

    // MARK: - 胶囊

    /// 「全部／可更新」两片筛选。
    private enum RuleFilter: String, CaseIterable, Identifiable {
        case all
        case updatable

        var id: String { rawValue }
        var title: String { self == .all ? "全部" : "可更新" }
    }

    private func filterCapsule(_ filter: RuleFilter) -> some View {
        let isOn = ruleFilter == filter
        return Button {
            withAnimation(.snappy) { ruleFilter = filter }
        } label: {
            Text(filter.title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .foregroundStyle(isOn ? Color.white : KazumiPalette.secondaryText(for: colorScheme))
                .background(
                    isOn ? KazumiPalette.accent(for: colorScheme) : Color.primary.opacity(0.06),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// 「更新全部」没有可更新的规则时是灰的、点不动（LP 2026-10-24）。
    /// fullWidth：辅助功能字号下单独占一整行、整宽描边（Colo 6547）。
    private var hasUpdatableRules: Bool { plugins.updatablePluginCount > 0 }

    private func updateAllCapsule(fullWidth: Bool) -> some View {
        let isDisabled = isUpdating || !hasUpdatableRules
        let tint = isDisabled
            ? KazumiPalette.secondaryText(for: colorScheme)
            : KazumiPalette.accent(for: colorScheme)
        return Button {
            Task { await checkForUpdates() }
        } label: {
            Text(isUpdating ? "正在更新…" : "更新全部")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .foregroundStyle(isDisabled ? tint.opacity(0.55) : tint)
                .background {
                    // 描边画在同一个胶囊上：外面再套一圈会变成两圈。
                    // 只有整宽那颗（辅助功能字号）描边，默认字号三颗并排时维持原样。
                    Capsule()
                        .fill(tint.opacity(isDisabled ? 0.06 : 0.12))
                        .overlay {
                            if fullWidth {
                                Capsule().stroke(
                                    tint.opacity(isDisabled ? 0.25 : 0.5),
                                    lineWidth: 1
                                )
                            }
                        }
                }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityHint(isDisabled ? "没有可更新的规则" : "")
    }

    // MARK: - 操作

    private func toggle(_ plugin: Plugin) {
        if selection.contains(plugin.name) {
            selection.remove(plugin.name)
        } else {
            selection.insert(plugin.name)
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        Task {
            do {
                try await plugins.move(fromOffsets: source, toOffset: destination)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func remove(_ targets: [Plugin]) async {
        do {
            try await plugins.removePlugins(named: Set(targets.map(\.name)))
            selection.subtract(targets.map(\.name))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func checkForUpdates() async {
        isUpdating = true
        defer { isUpdating = false }
        do {
            let result = try await plugins.tryUpdateAllPlugins()
            if result.hasNoCandidates {
                updateSummary = String(localized: "所有规则都是最新版本。")
            } else {
                var parts = [String(localized: "可更新 \(result.candidates) 条")]
                if result.updated > 0 { parts.append(String(localized: "已更新 \(result.updated) 条")) }
                if result.notNewer > 0 { parts.append(String(localized: "已是最新 \(result.notNewer) 条")) }
                if result.requiresNewerClient > 0 { parts.append(String(localized: "\(result.requiresNewerClient) 条需要更高版本客户端")) }
                if result.failed > 0 { parts.append(String(localized: "失败 \(result.failed) 条")) }
                updateSummary = parts.joined(separator: "，") + "。"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyImport(_ summary: PluginImportSummary) async {
        guard !summary.isEmpty else {
            if !summary.failures.isEmpty { errorMessage = summary.failures.prefix(3).joined(separator: "\n") }
            return
        }
        do {
            try await plugins.updatePlugins(summary.plugins)
            isShowingImportSheet = false
            var message = String(localized: "已导入 \(summary.plugins.count) 条规则")
            if summary.duplicateCount > 0 { message += String(localized: "（合并重复 \(summary.duplicateCount) 条）") }
            if !summary.replacedNames.isEmpty { message += String(localized: "，覆盖了 \(summary.replacedNames.count) 条同名规则") }
            if !summary.failures.isEmpty { message += String(localized: "；\(summary.failures.count) 条失败") }
            updateSummary = message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 从文件面板选规则文件。走 DocumentPickerBridge（跟设置备份导入同一条路），
    /// 不用 .fileImporter——侧载包上后者点文件不响应（LP 5216）。
    private func pickRuleFileFromDisk() {
        // 规则是从外部文件来的，扩展名不可控：只认 JSON 与文本，
        // 否则侧载环境里那一份会被直接筛掉、在面板里根本看不见。
        DocumentPickerBridge.open(types: [.json, .plainText, .data]) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                // 面板还在退场，这一刻读文件会读到一半被杀；等它退干净。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    handleFileImport(.success(url))
                }
            case .failure(let error):
                guard !Self.isCancelled(error) else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private static func isCancelled(_ error: Error) -> Bool {
        if let picker = error as? DocumentPickerBridge.PickerError {
            if case .cancelled = picker { return true }
        }
        return (error as NSError).code == NSUserCancelledError
    }

    private func handleFileImport(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            let data = try Foundation.Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                errorMessage = String(localized: "文件不是 UTF-8 文本")
                return
            }
            let summary = PluginImportExport.importResult(for: text, existing: plugins.pluginList)
            Task { await applyImport(summary) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 行视图

private struct PluginRowView: View {
    let plugin: Plugin
    let status: PluginUpdateAvailability
    let isSearchValid: Bool
    let isSelecting: Bool
    let isSelected: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 12) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? KazumiPalette.accent(for: colorScheme) : KazumiPalette.tertiaryText(for: colorScheme))
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(plugin.name.isEmpty ? "未命名规则" : plugin.name)
                        .font(.headline)
                        // Ato 6546：名字不许省略号。默认仍是一行，大字号下换行。
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    badge
                }
                // 版本号、搜索方式、验证三颗在最大字号下一排装不下，
                // 版本号被挤成「.6」。辅助功能字号下改成竖排，每颗一行。
                let metaLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                    : AnyLayout(HStackLayout(spacing: 12))
                metaLayout {
                    RuleMetadataLabel(
                        text: plugin.version.isEmpty ? "-" : plugin.version,
                        systemImage: "tag"
                    )
                    RuleMetadataLabel(
                        text: plugin.searchMode == .api ? "API" : "XPath",
                        systemImage: plugin.searchMode == .api ? "curlybraces" : "chevron.left.forwardslash.chevron.right"
                    )
                    if plugin.antiCrawlerConfig.enabled {
                        RuleMetadataLabel(
                            text: String(localized: "验证"),
                            systemImage: "checkmark.shield"
                        )
                    }
                }
                .font(.caption)
                .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                Text(plugin.baseUrl)
                    .font(.caption2)
                    .foregroundStyle(KazumiPalette.tertiaryText(for: colorScheme))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var badge: some View {
        switch status {
        case .updatable:
            Text("可更新")
                .font(.caption2.bold())
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(KazumiPalette.accent(for: colorScheme).opacity(0.16), in: Capsule())
                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
        case .latest:
            if isSearchValid {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        case .notInCatalog, .unknown:
            EmptyView()
        }
    }
}

/// 把删除二次确认弹窗挂到锚点那一行上，位置就落在那一行旁边；其它行原样。
private struct DeletionDialogAnchor: ViewModifier {
    let isAnchor: Bool
    let title: String
    let isPresented: Binding<Bool>
    let onDelete: () -> Void
    let onCancel: () -> Void

    func body(content: Content) -> some View {
        if isAnchor {
            content.confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible) {
                Button("删除", role: .destructive, action: onDelete)
                Button("取消", role: .cancel, action: onCancel)
            }
        } else {
            content
        }
    }
}
