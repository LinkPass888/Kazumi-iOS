//
//  SkipSegmentPill.swift
//  Kazumi
//
//  即将进入片头 / 片尾时浮出的倒计时弹窗，原生实现，对应
//  lib/pages/player/skip_segment_pill.dart（行为照搬，Colo 2026-10-27 定的一套）：
//
//  * 提前 5 秒弹出，圆环倒数 5..0，倒数到 0 自动 seek 到区间结束；
//  * 弹窗上「跳过」立刻跳，「取消」本段不再自动跳；
//  * 跳完给 5 秒「撤销」窗口，撤销跳回区间开头；
//  * 片尾结束到全集结尾 ≤5 秒时（ED 就是本集结尾）换成「下一集 / 取消」，
//    倒数到 0 用户无操作就取消——不自动切集，把决定权留给用户；
//  * 同一段片尾如果没有下一集可切，就整段不提示；只有片尾后还剩
//    >5 秒时才给「即将跳过片尾」。
//
//  时间轴来自 AniSkip，是按在线片源测的，不同压制版本会有偏差，
//  所以默认走「提示 + 倒数」而不是闷头跳。
//
//  状态机自己跑（250ms 一跳，跟 main 一致），PlayerScreen 只负责喂位置 /
//  时长、接 seek 和切集。
//

import SwiftUI

/// 弹窗自己的状态机。抽成可观察的类，PlayerScreen 那边只负责喂位置和接动作。
@MainActor
@Observable
final class SkipSegmentPillModel {
    enum Mode: Equatable {
        case countdown
        case nextEpisode
        case undo
    }

    /// 提前多少秒弹出倒计时（Apple TV 片头弹窗的提前量）。
    static let countdownSeconds: Double = 5
    /// 跳完后的撤销窗口时长。
    static let undoSeconds: Double = 5
    /// 片尾结束到全集结尾的「短」阈值：≤ 该值时认为 ED 就是本集结尾。
    ///
    /// 原来是 3 秒，片尾和正片结尾贴得太近时会误判成「ED 就是本集结尾」
    /// 弹出「下一集」（LP 2026-10-29 4798），放宽到 5 秒。
    static let postCreditsThreshold: Double = 5

    /// 这一集的片头片尾。换集 / 重新查询时由外面推进来。
    var segments: SkipSegments = .empty
    /// 当前播放位置与总时长（秒），外面推进来。
    var position: Double = 0
    var duration: Double = 0
    /// 用户正在拖进度：弹窗收起来、不自动跳，松手再恢复。
    var isScrubbing = false
    /// 起播是否已经稳定（首帧出来、时间轴开始走）。
    ///
    /// 加载阶段 `position` 一直是 0，AniSkip 又可能先一步回来；拿这个 0 去判
    /// 片头，会在起播前就 seek，随后播放头又被拉回 0（「进度还没出来就跳片头，
    /// 然后从头播」）。所以首帧稳定前只记时间轴，不判区间、不自动跳。
    var isPlaybackReady = false
    /// 当前集后面还有没有下一集。末集在片尾贴结尾时不提示；片尾后还剩
    /// >5 秒才提示「跳过片尾」，有下一集才换成「下一集」倒数。
    var hasNextEpisode = false

    private(set) var kind: SkipKind?
    private(set) var range: SkipRange?
    private(set) var mode: Mode = .countdown
    private(set) var countdownRemaining: Double = SkipSegmentPillModel.countdownSeconds

    /// 要 seek 到哪儿（秒）。外面消费掉就清。
    private(set) var seekTarget: Double?
    /// 点了「下一集」：外面按计数消费。
    private(set) var nextEpisodeRequest = 0

    /// 弹窗现在有没有内容。
    var isVisible: Bool { kind != nil }

    /// 符号中间要不要写秒数：片尾贴结尾（`nextEpisode`）不倒数，数字位就空着。
    var showsCountdownNumber: Bool { mode == .countdown }

    /// 圆环进度：0..1，1 是满环。
    var countdownFraction: Double {
        countdownRemaining / SkipSegmentPillModel.countdownSeconds
    }

    private var shownAt = Date()
    private var cancelled: SkipRange?
    private var skipped: SkipRange?
    /// 上一跳看到的时间轴：换了就当作「这是新的一集」，取消 / 跳过记录作废。
    private var lastSegments: SkipSegments?

    /// 取走待执行的 seek 目标，取完就清。
    func consumeSeekTarget() -> Double? {
        defer { seekTarget = nil }
        return seekTarget
    }

    /// 取走「下一集」请求，取完就清。
    func consumeNextEpisodeRequest() -> Bool {
        defer { nextEpisodeRequest = 0 }
        return nextEpisodeRequest > 0
    }

    // MARK: - 动作

    /// 弹窗上的「跳过」：立刻跳。
    func skipNow() {
        guard let kind, let range else { return }
        performSkip(kind: kind, range: range, auto: false)
    }

    /// 取消：本段不再自动跳（用户拖进来就是要看这段的）。
    func cancel() {
        if let range { cancelled = range }
        hide()
    }

    /// 撤销：跳回区间开头。
    func undo() {
        guard let range else { return }
        cancelled = range
        seekTarget = range.start
        hide()
    }

    /// 下一集。
    func nextEpisode() {
        if let range { cancelled = range }
        nextEpisodeRequest += 1
        hide()
    }

    // MARK: - 状态推进

    func update() {
        let segments = self.segments
        if segments != lastSegments {
            lastSegments = segments
            cancelled = nil
            skipped = nil
            hide()
        }
        // 真正无区间：清掉取消 / 跳过状态，让下一次的提示能回来。
        if segments.isEmpty { return }
        // 加载阶段不判区间：这时 position 还是 0，分不清「真的在片头」还是
        // 「还没起播」，提前 seek 会被加载完成后的播放头覆盖回 0。
        guard isPlaybackReady else {
            hide()
            return
        }

        if isScrubbing {
            hide()
            return
        }

        if mode == .undo {
            // 撤销窗口过了、或用户自己跳回了区间之前，就收起来。
            if Date().timeIntervalSince(shownAt) > Self.undoSeconds
                || position < (range?.start ?? .infinity)
            {
                hide()
            }
            return
        }

        // 片尾结束到结尾 ≤5 秒、又没有下一集：这就是本集结尾，不弹任何提示。
        if let kind, let range, suppressesEndingPrompt(kind, range) {
            hide()
            return
        }

        if let kind, let range {
            // 片长 / 下一集信息可能在弹窗已经浮出来之后才补齐：按最新判定
            // 重算一次，别让「下一集」和「跳过片尾」停在旧结论上。
            let expectedMode: Mode = endsEpisode(kind, range) ? .nextEpisode : .countdown
            if mode != expectedMode { mode = expectedMode }

            // 倒数进行中：只在仍盯着同一片段时倒数。
            let active = segments.activeAt(position)
            if active?.range.isSame(range) != true {
                let upcoming = segments.upcomingAt(position, lead: Self.countdownSeconds)
                if upcoming == nil || !upcoming!.range.isSame(range) {
                    hide()
                    return
                }
            }
            // 已经进区间：跳过，不再等倒数。
            if position >= range.start {
                if mode == .nextEpisode {
                    cancel()
                } else if skipped?.isSame(range) != true && cancelled?.isSame(range) != true {
                    performSkip(kind: kind, range: range, auto: true)
                }
                return
            }
            countdownRemaining = min(max(range.start - position, 0), Self.countdownSeconds)
            return
        }

        // 还没到提示时机：先看「即将进入」；否则若已经落在区间里
        // （开播即 OP/ED、倍速或拖进度条直接进来），给它一个倒计时弹窗。
        guard let upcoming = segments.upcomingAt(position, lead: Self.countdownSeconds) else {
            guard let activeNow = segments.activeAt(position) else { return }
            if cancelled?.isSame(activeNow.range) == true || skipped?.isSame(activeNow.range) == true {
                return
            }
            // 开播即落在 OP/ED 起点附近（≤ 倒数时长内）才弹；区间中段进来的不弹。
            guard position - activeNow.range.start <= Self.countdownSeconds else { return }
            show(activeNow.kind, activeNow.range)
            return
        }
        if cancelled?.isSame(upcoming.range) == true || skipped?.isSame(upcoming.range) == true {
            return
        }
        show(upcoming.kind, upcoming.range)
    }

    private func show(_ kind: SkipKind, _ range: SkipRange) {
        // 没有下一集、片尾又贴着本集结尾：这段已经没什么可跳的，别弹窗。
        guard !suppressesEndingPrompt(kind, range) else {
            hide()
            return
        }
        self.kind = kind
        self.range = range
        mode = endsEpisode(kind, range) ? .nextEpisode : .countdown
        shownAt = Date()
        countdownRemaining = Self.countdownSeconds
    }

    private func hide() {
        kind = nil
        range = nil
        mode = .countdown
        countdownRemaining = Self.countdownSeconds
    }

    private func performSkip(kind: SkipKind, range: SkipRange, auto: Bool) {
        skipped = range
        // seek 交给外面执行（这里只记状态）。
        seekTarget = range.end
        if auto {
            // 跳完进撤销窗口；撤销用的就是这一段的开头。
            self.kind = kind
            self.range = range
            mode = .undo
            shownAt = Date()
        } else {
            hide()
        }
    }

    /// 片尾结束到全集结尾 ≤5 秒：这时 ED 就是本集结尾，换成「下一集 / 取消」。
    private func endsEpisode(_ kind: SkipKind, _ range: SkipRange) -> Bool {
        hasNextEpisode
            && kind == .ending
            && duration > 0
            && duration - range.end <= Self.postCreditsThreshold
    }

    /// 片尾结束到结尾 ≤5 秒、却没有下一集：既没有「下一集」可切，也没有
    /// 足够的片尾可跳，按需求整段不提示。>5 秒才走「即将跳过片尾」。
    private func suppressesEndingPrompt(_ kind: SkipKind, _ range: SkipRange) -> Bool {
        guard kind == .ending, duration > 0, !hasNextEpisode else { return false }
        return duration - range.end <= Self.postCreditsThreshold
    }
}

// MARK: - 弹窗

/// 画面右下角那片弹窗。三种形态共用一张玻璃卡，只有内容换。
struct SkipSegmentPillView: View {
    let model: SkipSegmentPillModel

    init(model: SkipSegmentPillModel) {
        self.model = model
    }

    var body: some View {
        Group {
            if let kind = model.kind {
                switch model.mode {
                case .countdown:
                    countdownPill(kind: kind)
                case .nextEpisode:
                    nextEpisodePill()
                case .undo:
                    undoPill(kind: kind)
                }
            }
        }
        .animation(.easeOut(duration: 0.22), value: model.isVisible)
        .animation(.easeOut(duration: 0.22), value: model.mode)
    }

    private var cardPadding: EdgeInsets { EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14) }

    private func countdownPill(kind: SkipKind) -> some View {
        pillCard {
            VStack(spacing: 10) {
                HStack(spacing: 2) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(Self.foreground)
                    Text(String(localized: "即将跳过\(String(describing: kind.label))"))
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Self.foreground)
                    countdownRing
                }
                HStack(spacing: 12) {
                    pillAction(String(localized: "跳过"), prominent: true) { model.skipNow() }
                    pillAction("取消") { model.cancel() }
                }
            }
        }
    }

    private func nextEpisodePill() -> some View {
        pillCard {
            VStack(spacing: 10) {
                HStack(spacing: 2) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(Self.foreground)
                    Text("即将到结尾")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Self.foreground)
                    countdownRing
                }
                HStack(spacing: 12) {
                    pillAction("下一集", prominent: true) { model.nextEpisode() }
                    pillAction("取消") { model.cancel() }
                }
            }
        }
    }

    private func undoPill(kind: SkipKind) -> some View {
        pillCard {
            VStack(spacing: 10) {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(Self.foreground)
                    Text(String(localized: "已跳过\(String(describing: kind.label))"))
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Self.foreground)
                }
                pillAction(String(localized: "撤销"), prominent: true) { model.undo() }
            }
        }
    }

    private func pillCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(cardPadding)
            .kazumiGlassCard()
    }

    private func pillAction(
        _ title: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.bold))
                .foregroundStyle(Self.foreground)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(Self.foreground.opacity(prominent ? 0.22 : 0.12))
                )
        }
        .buttonStyle(PlayerPressStyle())
    }

    /// 圆环，不显示数字（跟 main 的 `_CountdownRing` 一致）。
    /// 倒数：快进那颗符号，秒数写在符号正中（Colo 2026-10-28）。
    /// 以前是旁边一颗圆环，跟栏里的符号对不上；现在整颗就是符号本身。
    /// 片尾贴结尾（`nextEpisode`）不倒数，就把数字位空着。
    private var countdownRing: some View {
        ZStack {
            Image(systemName: "goforward")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Self.foreground)
            if model.showsCountdownNumber {
                Text("\(Int(model.countdownRemaining.rounded(.up)))")
                    .font(.system(size: 12, weight: .regular).monospacedDigit())
                    .foregroundStyle(Self.foreground)
            }
        }
        .frame(width: 26, height: 26)
    }

    /// 弹窗上的白：跟原版 `Color(0xF2FFFFFF)` 同值（白 95%）。
    private static let foreground = Color.white.opacity(0.95)
}
