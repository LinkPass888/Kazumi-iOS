//
//  ProfileScreen.swift
//  Kazumi
//
//  1:1 复刻 lib/pages/my/my_space_view.dart 的分组结构：
//  * 顶栏「我的」+ 右侧「全部设置」按钮；
//  * 观看足迹（看过番剧 / 观看集数）；
//  * 历史记录、离线下载（并排两块工具卡）；
//  * 规则管理（原版的异形强调卡）；
//  * 内容与偏好：规则管理 / 通知设置 / 播放设置 / 弹幕设置；
//  * 数据与应用：账号与备份 / 存储管理 / 关于 Kazumi。
//

import SwiftUI

struct ProfileScreen: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 量到的页面尺寸（§6.0：列数与限宽都按容器算，不按整屏）。
    @State private var containerSize: CGSize = .zero

    private var isWideTier: Bool {
        containerSize.width >= 700 && containerSize.height >= 600
    }

    /// C 档：宽但矮（§六之二）。
    private var isShortTier: Bool {
        containerSize.width >= 700 && containerSize.height < 600
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                    watchStats
                    // 「规则管理」只保留这一处入口：原先这里还有一张异形强调卡直达同一页，
                    // 同屏两个入口反而让人怀疑是两个不同的功能。
                    // LP 3522：通知设置／播放设置／弹幕设置在「全部设置」里都有，这一页不再重复；
                    // 观看历史和离线下载从原来并排的两张工具卡收进这一组。
                    contentSection
                    section("数据与应用", rows: [
                        Row(symbol: "icloud", title: "同步设置", route: .syncBackup),
                        Row(symbol: "externaldrive", title: "存储与日志", route: .storage),
                        Row(symbol: "info.circle", title: "关于 Kazumi", route: .about),
                    ])
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
                // 宽档内容限宽 700 居中（§6.4）。maxWidth 只封顶不撑宽，窄屏自然满宽。
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            guard size.width > 0 else { return }
            containerSize = size
        }
        // 顶部滚动边缘：渐进模糊（.soft），不额外叠材质或底色。
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(KazumiPalette.groupedBackground(for: colorScheme).ignoresSafeArea())
        // 顶栏换原生（LP 2026-10-24）：标题和设置按钮都归系统。
        // 原来那块自钉顶栏带不透明底色，会把滚动边缘的模糊整块挡住（Colo 1794 提的坑），
        // 所以这次连底色一起删掉，不再自己画任何一条栏。
        // 这一页下面挂的记录也一样：封面空的读到时补一次。
        .task {
            WatchRecordMetaBackfill.fill(recentRecords, in: library)
        }
        .navigationTitle("我的")
        // C 档大标题改 inline（§六之二）。
        .navigationBarTitleDisplayMode(isShortTier ? .inline : .large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    router.push(.settings)
                } label: {
                    // LP 2026-10-25：右上角是设置入口，用齿轮符号。
                    // 跟返回按钮一样走标签色，不用主题色。
                    Image(systemName: "gearshape")
                        .foregroundStyle(Color.primary)
                }
                .accessibilityLabel("全部设置")
            }
        }
    }

    // MARK: - 头部

    // MARK: - 观看足迹

    /// Colo 3529：两张等宽白卡就是两个空盒子，合成一张统计条——
    /// 卡高跟组里一行一样 52，里面左右两块各占一半，一行里「数字 名字」。
    private var watchStats: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("观看足迹")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            let stacked = dynamicTypeSize.isAccessibilitySize
            let layout = stacked
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(spacing: 20))
            layout {
                stat(value: "\(library.entries.count)", title: "看过番剧")
                stat(value: "\(library.history.count)", title: "观看集数")
            }
            // 写死的 52 高在辅助功能字号下会把名字截成「看…」，改成最小高、装不下自己长。
            .frame(minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(KazumiPalette.groupedRow(for: colorScheme))
            )
        }
    }

    /// 一块：数字 24 semibold 主题色，隔 6 点接名字 13 次要色，整块左对齐、左留 14。
    private func stat(value: String, title: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Text(value)
                .font(.system(.title2, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 14)
        // 两块各自念成一件事：「12，看过番剧」。
        // 数字用 verbatim、名字用 Text(title) 各自解析，不能拼进同一个插值里——
        // 那样 LocalizedStringKey 会被当成参数描述念出来。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: value + "，") + Text(title))
    }

    // MARK: - 内容与偏好

    /// 规则管理 / 离线下载 / 观看历史三行，最后一行底下挂最近看过的三张海报。
    /// 组名 Camo 3523 定的「内容管理」：原来那个里的「偏好」跟着通知、播放、弹幕一起删了，
    /// 剩下这三行都是在这台设备上攒下的东西。
    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("内容管理")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                rowButton(symbol: "puzzlepiece.extension", title: "规则管理") {
                    router.push(.pluginList)
                }
                Divider().padding(.leading, 54)
                rowButton(symbol: "arrow.down.circle", title: "离线下载") {
                    router.push(.download)
                }
                Divider().padding(.leading, 54)
                rowButton(symbol: "clock.arrow.circlepath", title: "观看历史") {
                    router.push(.history)
                }
                // LP 3534／Colo 3536：一个番都没有的时候，「暂无观看历史」留在这一行下面，
                // 但左边缘要跟「观看历史」四个字对齐——左起 54（14 卡片内边距 + 28 图标 + 12 间距），
                // 跟上面那条分隔线同一条竖线。上 8 下 12，13 号次要灰。
                if recentRecords.isEmpty {
                    emptyHistoryNote
                } else {
                    Divider().padding(.leading, 54)
                    recentStrip
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(KazumiPalette.groupedRow(for: colorScheme))
            )
        }
    }

    /// 空态那句，左边缘跟「观看历史」四个字对齐（Colo 3536）。
    private var emptyHistoryNote: some View {
        HStack {
            Text("暂无观看历史")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        // 54 = 卡片左右内边距 14 + 图标 28 + 图标与标题间距 12。
        .padding(.leading, 54)
        .padding(.trailing, 14)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// 最近看过的三张：按时间倒序取前三个，同一部番只出现一次。
    private var recentRecords: [WatchRecord] {
        var seen = Set<Int>()
        var picked: [WatchRecord] = []
        for record in library.history.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            guard seen.insert(record.bangumiID).inserted else { continue }
            picked.append(record)
            if picked.count == 3 { break }
        }
        return picked
    }

    /// 观看历史那一行底下最近的几条，竖放（LP 3557、Colo 3559）：
    /// 番名普遍长，横放三张一截断就认不出是哪部，比高一点更糟。
    /// 点一条进那部的详情，「观看历史」那一行才是历史页。
    private var recentStrip: some View {
        VStack(spacing: 0) {
            ForEach(Array(recentRecords.enumerated()), id: \.element.id) { index, record in
                if index > 0 {
                    // Colo 3561：条带里面的分隔线跟文字块对齐（14 + 封面 64 + 12 = 90），
                    // 不跟组里其它分隔线一样左起 54——那样会从封面中间穿过去。
                    Divider().padding(.leading, 90)
                }
                recentRow(record)
            }
        }
    }

    /// 一条：封面 64×98 在左，右边名字 15、集行 12、状态 12，下面一条进度。
    /// 点一条直接播那一集（LP 2026-10-27，跟 main 一样），不进详情页。
    private func recentRow(_ record: WatchRecord) -> some View {
        Button {
            router.push(.player(bangumiID: record.bangumiID, episode: record.episodeNumber))
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Color.clear
                    .frame(width: 64, height: 64 / BangumiPosterCard.coverAspectRatio)
                    .overlay {
                        BangumiRemoteImage(url: record.imageURL)
                    }
                    .clipShape(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )

                // Colo 3567：文字那三行上下居中，不跟封面顶对齐——封面 98 高、
                // 三行字只有 50 上下，顶对齐会在这一条下面空出四十多。
                // 进度条不跟着居中（LP 3580）：它留在这条底部，跟封面下沿齐，
                // 三行字在被它让出来的空间里居中。
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(record.bangumiName)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text(episodeLine(for: record))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.top, 2)

                        Text(statusText(for: record))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

                    // 进度条是这一条的底边，跟状态行之间没有固定间距（Colo 3585）。
                    KazumiGlassProgressBar(
                        progress: record.fraction,
                        tint: KazumiPalette.accent(for: colorScheme)
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // 这一列撑满封面高度：进度条落到封面下沿，三行字在里面居中。
                .frame(height: 64 / BangumiPosterCard.coverAspectRatio)
            }
            // 行高 114 = 封面 98 ＋ 上下各 8。
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text("\(record.bangumiName)，\(episodeLine(for: record))，\(statusText(for: record))")
        )
        .accessibilityAddTraits(.isButton)
    }

    /// 底部状态，跟观看历史页同一份写法：看完的写「已看完」，否则写具体看到哪儿了
    /// （LP 4892：不要百分比），一集都没看下去就说「继续观看」。
    private func statusText(for record: WatchRecord) -> LocalizedStringKey {
        if record.isFinished { return "已看完" }
        // positionText 是算出来的进度（「12:34」这种），查不到译文就原样显示。
        return LocalizedStringKey(record.positionText ?? "继续观看")
    }

    /// 「第 1 集」或「第 1 集 · 标题」，跟观看历史页同一份写法。
    private func episodeLine(for record: WatchRecord) -> String {
        let number = String(localized: "第 \(record.episodeNumber) 集")
        let title = record.episodeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // 老记录里的集标题是「第 N 话」（LP 4824「已经记录的就算了」，不迁移数据），
        // 跟新的「第 N 集」并排比一次，别把同一句话拼成「第 3 集 · 第 3 话」。
        let legacy = String(localized: "第 \(record.episodeNumber) 话")
        return title.isEmpty || title == number || title == legacy ? number : "\(number) · \(title)"
    }

    private func rowButton(
        symbol: String,
        title: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(KazumiPalette.accent(for: colorScheme))
                    .frame(width: 28)
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            // 单行 52：正文那行实测 20.3，上下各 16 补到 52。
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 分组列表

    private struct Row: Identifiable {
        let id = UUID()
        var symbol: String
        var title: LocalizedStringKey
        var route: AppRoute
    }

    private func section(_ title: LocalizedStringKey, rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    rowButton(symbol: row.symbol, title: row.title) {
                        router.push(row.route)
                    }
                    if index < rows.count - 1 {
                        Divider().padding(.leading, 54)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(KazumiPalette.groupedRow(for: colorScheme))
            )
        }
    }
}
