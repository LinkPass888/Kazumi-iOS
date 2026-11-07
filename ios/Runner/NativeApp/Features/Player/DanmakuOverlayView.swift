//
//  DanmakuOverlayView.swift
//  Kazumi
//
//  弹幕渲染层：叠在播放内核的画面之上，自己用 CADisplayLink 按播放时间
//  排布弹幕，不经过 SwiftUI 的每帧刷新。ProMotion 设备按 120Hz 请求刷新，
//  时钟经过 PLL 平滑，文字光栅化后只移动 layer transform。
//
//  行为对齐原版 canvas_danmaku 的默认观感：
//   * 滚动弹幕 8 秒横穿屏幕，固定弹幕停留 4.5 秒；
//   * 同一轨道上一条还没完全进屏时不放下一条（不重叠）；
//   * 字色取自 DanDanPlay 的 RGB，统一加深色描边保证亮画面上可读；
//   * 透明度 / 字号 / 显示区域（屏幕高度占比）来自弹幕设置。
//

import CoreText
import QuartzCore
import UIKit

@MainActor
final class DanmakuOverlayView: UIView {
    private final class ItemLabel: UILabel {
        var startTime: Double = 0
        var duration: Double = 8
        var lane: Int = 0
        var mode: Int = 1
        var baseY: CGFloat = .nan
        /// 描边宽度（pt）。0 表示不描边。
        var outlineWidth: CGFloat = 0

        override func drawText(in rect: CGRect) {
            guard outlineWidth > 0,
                  let attributedText,
                  let context = UIGraphicsGetCurrentContext() else {
                super.drawText(in: rect)
                return
            }

            // 只生成一条 CTLine，让描边与填充复用完全相同的字形和位置。
            // 必须先移除 run 自带的 `.foregroundColor`，否则它会覆盖 CGContext
            // 的黑色 stroke；实际颜色改由 context 在两次绘制前分别提供。
            let fillColor = attributedText.attribute(
                .foregroundColor,
                at: 0,
                effectiveRange: nil
            ) as? UIColor ?? .white
            let drawString = NSMutableAttributedString(attributedString: attributedText)
            let fullRange = NSRange(location: 0, length: drawString.length)
            drawString.removeAttribute(.foregroundColor, range: fullRange)
            drawString.addAttribute(
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String),
                value: true,
                range: fullRange
            )
            let line = CTLineCreateWithAttributedString(drawString as CFAttributedString)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let lineWidth = CGFloat(
                CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            )
            let lineHeight = ascent + descent + leading
            // 仿 canvas_danmaku 的两次 drawParagraph：相同排版、相同基线，
            // 先用 CGContext 的 .stroke 模式画黑边，再用 .fill 盖原色实心字。
            let x = (rect.width - lineWidth) / 2
            let baseline = (rect.height - lineHeight) / 2 + descent + leading / 2

            context.saveGState()
            context.textMatrix = .identity
            // UIView 的上下文是左上原点、y 向下；CoreText 要左下原点、y 向上。
            context.translateBy(x: rect.origin.x, y: rect.origin.y + rect.height)
            context.scaleBy(x: 1, y: -1)
            let textOrigin = CGPoint(x: x, y: baseline)
            context.setLineWidth(outlineWidth)
            // 与 canvas_danmaku 的默认 Paint 一致：miter join、butt cap、miterLimit 4。
            context.setLineJoin(.miter)
            context.setLineCap(.butt)
            context.setMiterLimit(4)

            // CTLineDraw 允许改动 CGContext 状态。每一遍都用独立 graphics state，
            // 并显式重置 textMatrix / textPosition，保证 fill 与 stroke 严格同位。
            context.saveGState()
            context.textMatrix = .identity
            context.setTextDrawingMode(.stroke)
            context.setStrokeColor(UIColor.black.cgColor)
            context.textPosition = textOrigin
            CTLineDraw(line, context)
            context.restoreGState()

            context.saveGState()
            context.textMatrix = .identity
            context.setTextDrawingMode(.fill)
            context.setFillColor(fillColor.cgColor)
            context.textPosition = textOrigin
            CTLineDraw(line, context)
            context.restoreGState()
            context.restoreGState()
        }
    }

    private var comments: [DanmakuComment] = []
    private var signature = 0
    private var labels: [ItemLabel] = []
    private var nextIndex = 0

    /// 一整套弹幕观感。字段与「弹幕设置」页一一对应，页面改哪一项这里就跟着变。
    struct Style: Equatable {
        var enabled = true
        var opacity: Double = 1
        var fontSize: Double = 20
        var area: Double = 0.5
        /// 滚动弹幕横穿屏幕的秒数（main 的 danmakuDuration）。
        var duration: Double = 8
        /// 行高倍数（main 的 danmakuLineHeight，默认 1.6）。
        var lineHeight: Double = 1.6
        /// 弹幕速度跟随视频倍速（main 的 danmakuFollowSpeed）。
        var followSpeed = true
        var showTop = true
        var showBottom = false
        var showScroll = true
        /// 海量弹幕：轨道满了也照画（叠着来），关掉就宁可丢。
        var massive = false
        /// 5 秒内内容相同的合并成一条。
        var deduplication = false
        /// 三路来源开关（main: _isDanmakuSourceEnabled）。关掉的那一路不画。
        var showBiliBili = true
        var showGamer = true
        var showDanDan = true

        var border = true
        var borderSize: Double = 1.5
        var useColor = true
        /// 1~9 对应 w100~w900（main 的 danmakuFontWeight）。
        var fontWeight = 4

        /// 这条来路的弹幕要不要画。判断与 main 的 _isDanmakuSourceEnabled 一致：
        /// 弹弹play 自己的弹幕，只在弹弹play 这颗关掉时才被筛掉。
        func allows(_ source: String) -> Bool {
            if !showBiliBili && source.contains("BiliBili") { return false }
            if !showGamer && source.contains("Gamer") { return false }
            if !showDanDan && !(source.contains("BiliBili") || source.contains("Gamer")) {
                return false
            }
            return true
        }

        /// 只挑「同一批弹幕该怎么画」相关的项：这几项一变，已经画出来的要清掉重来。
        var filterSignature: Int {
            var hasher = Hasher()
            hasher.combine(showTop)
            hasher.combine(showBottom)
            hasher.combine(showScroll)
            hasher.combine(massive)
            hasher.combine(deduplication)
            hasher.combine(showBiliBili)
            hasher.combine(showGamer)
            hasher.combine(showDanDan)
            return hasher.finalize()
        }
    }

    private var style = Style()
    /// 上一次的过滤类设置，用来判断要不要把已经画出来的清掉重来。
    private var lastFilterSignature: Int?

    private var enabled: Bool { style.enabled }

    /// 播放时钟（换内核后由 `PlayerSurfaceModel` 提供）；每帧直接读，比等回调插值更跟手。
    weak var clock: PlayerClockProvider?

    /// 当前倍速。「弹幕跟随视频倍速」开着时，用它把停留时间缩短。
    private var playbackRate: Double = 1

    private var lastNow: Double = 0
    /// PLL 平滑时钟。内核每 250ms 才送来一个播放时间采样；新采样只更新锚点，
    /// 输出时间用本机时钟推进并小幅收敛，避免每次采样到达时回跳 1~2px。
    private var sampleTime: Double = 0
    private var sampleStamp: CFTimeInterval = 0
    private var smoothTime: Double = 0
    private var lastFrameStamp: CFTimeInterval = 0
    private var sampleFilled = false


    private var displayLink: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 外部更新

    func apply(
        comments newComments: [DanmakuComment],
        style newStyle: Style,
        playbackRate rate: Double
    ) {
        let newSignature = newComments.count &* 31 &+ Int((newComments.last?.time ?? 0) * 10)
        let filtersChanged = lastFilterSignature != nil
            && lastFilterSignature != newStyle.filterSignature
        if newSignature != signature || filtersChanged {
            signature = newSignature
            let allowed = newComments.filter { newStyle.allows($0.source) }
            let ordered = allowed.sorted { $0.time < $1.time }
            comments = newStyle.deduplication ? Self.merged(ordered) : ordered
            clearLabels()
            // 过滤类设置改了：从现在这一刻接着放，不把已经过去的那段重播一遍。
            nextIndex = filtersChanged ? lowerBound(clockNow()) : 0
        }
        style = newStyle
        lastFilterSignature = newStyle.filterSignature
        let newRate = max(0.1, rate)
        if abs(newRate - playbackRate) > 0.0001 {
            sampleFilled = false
        }
        playbackRate = newRate
        if !newStyle.enabled {
            clearLabels()
        }
    }

    /// 自己发的弹幕：不排队等时钟，立刻从右边飞出去。
    ///
    /// 对应原版 `_sendDanmaku` —— 它也只是把这条塞进画布（`selfSend: true`），
    /// 不往任何接口发，所以这边同样只在本地显示。
    func sendLocal(text rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let now = clockNow()
        let comment = DanmakuComment(
            id: Int(Date().timeIntervalSince1970 * 1000),
            time: now,
            mode: 1,
            colorValue: 0xFFFFFF,
            text: text,
            source: "self"
        )
        spawn(comment, now: now)
    }

    /// 5 秒内内容完全相同的合并成一条（main: mergeDuplicateDanmakus，窗口 5 秒）。
    private static func merged(_ comments: [DanmakuComment]) -> [DanmakuComment] {
        guard !comments.isEmpty else { return comments }
        var result: [DanmakuComment] = []
        result.reserveCapacity(comments.count)
        // 按时间顺序扫，记住每条文本最近一次出现的时间。
        let ordered = comments.sorted { $0.time < $1.time }
        var lastSeen: [String: Double] = [:]
        for comment in ordered {
            if let seen = lastSeen[comment.text], comment.time - seen < 5 {
                continue
            }
            lastSeen[comment.text] = comment.time
            result.append(comment)
        }
        return result
    }

    // MARK: - 时钟

    /// PLL 锁相：把内核的低频绝对时间作为锚点，逐帧用本机时钟推进平滑时间。
    private func clockNow() -> Double {
        guard let clock else { return lastNow }
        let sample = max(0, clock.currentPlaybackTime)
        let stamp = CACurrentMediaTime()
        // 首次采样、暂停、缓冲或换内核：直接对齐绝对时间。
        // 缓冲时内核仍可能报 isPlaying；必须单独看 isStalled，否则弹幕会继续走、
        // 数据恢复后再被绝对时间拽回去，看起来就是左右晃动。
        if !sampleFilled || !clock.isPlayingNow || clock.isStalledNow {
            sampleTime = sample
            sampleStamp = stamp
            smoothTime = sample
            lastFrameStamp = stamp
            sampleFilled = true
            return sample
        }

        if abs(sample - sampleTime) > 0.0001 {
            sampleTime = sample
            sampleStamp = stamp
        }

        let delta = min(max(0, stamp - lastFrameStamp), 0.1)
        lastFrameStamp = stamp
        let elapsed = min(max(0, stamp - sampleStamp), 0.5)
        let target = sampleTime + elapsed * playbackRate
        let drift = target - smoothTime
        if abs(drift) > 0.25 {
            smoothTime = target
        } else {
            let correction = max(-0.15, min(0.15, drift * 2.5))
            smoothTime += delta * playbackRate * (1 + correction)
        }
        return smoothTime
    }

    private func lowerBound(_ time: Double) -> Int {
        var low = 0
        var high = comments.count
        while low < high {
            let mid = (low + high) / 2
            if comments[mid].time < time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    // MARK: - 帧循环

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopDisplayLink()
        } else {
            startDisplayLink()
        }
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 80,
            maximum: 120,
            preferred: 120
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private var loggedFirstStep = false

    @objc private func step() {
        guard enabled, !comments.isEmpty, bounds.width > 1, bounds.height > 1 else { return }
        if !loggedFirstStep {
            loggedFirstStep = true
            KazumiLogBuffer.player(
                String(localized: "起播打点：弹幕层第一帧 \(String(describing: comments.count)) 条，画面 \(String(describing: Int(bounds.width)))x\(String(describing: Int(bounds.height)))")
            )
        }
        let now = clockNow()
        if now < lastNow - 1.5 || now > lastNow + 3 {
            clearLabels()
            nextIndex = lowerBound(now)
        }
        lastNow = now
        // 没在播就不出新弹幕：暂停停在 0 秒时，0 秒附近那些照样会被发出来，
        // 看上去就是「还没播弹幕先飘了」（LP 3626）。已经在飞的照旧停着不动，
        // 因为位置是按播放时间算的。
        //
        // 再加一道「真起播」门（LP 5033）：只判 `isPlayingNow` 不够——它只表示内核没暂停，
        // 播放页刚打开、片源还在加载时它就是 true，而进度还是 0，于是 0 秒那批弹幕先飘出来，
        // 看着就是「还没开始播、进度都没出来就冒 0:00 的弹幕」。
        // 所以改用 `hasStartedPlayback`（首帧到了且进度过 0.15，见 `MPVPlayerContainer`），
        // 换集/停止时它自己复位，这里不用再管。
        guard let clock, clock.hasStartedPlayback else {
            layoutLabels(at: now)
            return
        }
        emit(upTo: now)
        layoutLabels(at: now)
    }

    private func emit(upTo now: Double) {
        while nextIndex < comments.count && comments[nextIndex].time <= now {
            let comment = comments[nextIndex]
            nextIndex += 1
            // 追上进度时不要一次性把几十条旧弹幕糊上去。
            guard now - comment.time < 1.0 else { continue }
            spawn(comment, now: now)
            if labels.count >= 90 { break }
        }
    }

    private func spawn(_ comment: DanmakuComment, now: Double) {
        // 哪一种不显示就直接不画（main 的顶部/底部/滚动弹幕三颗开关）。
        let mode = (comment.mode == 4 || comment.mode == 5) ? comment.mode : 1
        switch mode {
        case 1: if !style.showScroll { return }
        case 4: if !style.showBottom { return }
        case 5: if !style.showTop { return }
        default: return
        }

        let label = ItemLabel()
        let size = max(10, min(48, style.fontSize))
        let font = UIFont.systemFont(ofSize: size, weight: Self.weight(style.fontWeight))
        // 关掉「弹幕颜色」就一律白字（main 的 danmakuColor）。
        let textColor = style.useColor ? Self.color(comment.colorValue) : UIColor.white
        let border = style.border ? max(0, min(3, style.borderSize)) : 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byClipping
        // 填充字和描边用同一套排版，`drawText` 里再用同一个 CTLine 画两遍。
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph
        ]
        label.attributedText = NSAttributedString(string: comment.text, attributes: attributes)
        // 直接用 pt，跟 canvas_danmaku 的 `Paint.strokeWidth` 一样；不再折算成
        // NSStrokeWidth 的字体百分比，避免两套排版把描边挤成斜向偏移。
        label.outlineWidth = CGFloat(border)
        label.textAlignment = .center
        label.numberOfLines = 1
        label.lineBreakMode = .byClipping
        label.backgroundColor = .clear
        label.isOpaque = false
        label.alpha = CGFloat(max(0.1, min(1, style.opacity)))
        label.mode = mode
        label.startTime = now
        label.duration = duration(for: mode)

        let fitted = label.sizeThatFits(
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        )
        // 描边会向字形轮廓外扩，sizeThatFits 不算这笔；按粗细留边，免得笔画被裁掉。
        let edgePadding = max(4, ceil(CGFloat(border) * 2) + 2)
        let width = ceil(fitted.width) + edgePadding
        let height = ceil(fitted.height) + edgePadding
        label.bounds = CGRect(origin: .zero, size: CGSize(width: width, height: height))
        label.layer.shouldRasterize = true
        label.layer.rasterizationScale = currentScreenScale
        label.layer.allowsEdgeAntialiasing = true

        // 轨道满了：海量弹幕叠着画，否则这条就不画了。
        guard let lane = laneIndex(mode: mode, width: width, now: now) else { return }
        label.lane = lane
        addSubview(label)
        labels.append(label)
        position(label, at: now)
    }

    /// 滚动弹幕按设置里的秒数走；固定弹幕（顶/底）按 main 的比例停 4.5/8。
    private func duration(for mode: Int) -> Double {
        let base = max(2, min(16, style.duration))
        let scaled = style.followSpeed ? base : base * playbackRate
        return mode == 1 ? scaled : scaled * (4.5 / 8)
    }

    /// 1~9 映射到 w100~w900，与 main 的字体字重滑杆一致。
    private static func weight(_ value: Int) -> UIFont.Weight {
        switch max(1, min(9, value)) {
        case 1: .ultraLight
        case 2: .thin
        case 3: .light
        case 4: .regular
        case 5: .medium
        case 6: .semibold
        case 7: .bold
        case 8: .heavy
        default: .black
        }
    }

    private func layoutLabels(at now: Double) {
        var alive: [ItemLabel] = []
        alive.reserveCapacity(labels.count)
        for label in labels {
            let elapsed = now - label.startTime
            if elapsed > label.duration + 0.6 || elapsed < -1.5 {
                label.removeFromSuperview()
                continue
            }
            position(label, at: now)
            alive.append(label)
        }
        labels = alive
    }

    private func position(_ label: ItemLabel, at now: Double) {
        let width = label.bounds.width
        let height = label.bounds.height
        let laneHeight = self.laneHeight
        let topInset: CGFloat = 6
        let scale = currentScreenScale
        let x: CGFloat
        let y: CGFloat

        if label.mode == 1 {
            let progress = max(0, min(1, (now - label.startTime) / label.duration))
            x = bounds.width - CGFloat(progress) * (bounds.width + width)
            y = topInset + CGFloat(label.lane) * laneHeight
        } else if label.mode == 5 {
            x = (bounds.width - width) / 2
            y = topInset + CGFloat(label.lane) * laneHeight
        } else {
            x = (bounds.width - width) / 2
            y = bounds.height - CGFloat(label.lane + 1) * laneHeight
        }

        let snappedY = snapToPixel(y, scale: scale)
        if label.baseY.isNaN || label.baseY != snappedY {
            // 改 frame 前先清掉 transform；否则 frame 是 transform 后的包围盒。
            label.transform = .identity
            label.frame = CGRect(x: 0, y: snappedY, width: width, height: height)
            label.baseY = snappedY
        }
        let snappedX = snapToPixel(x, scale: scale)
        label.transform = CGAffineTransform(translationX: snappedX, y: 0)
    }

    // MARK: - 轨道

    /// 行高 =（字号 + 6）× 行高倍数（main 的 danmakuLineHeight，默认 1.6）。
    private var laneHeight: CGFloat {
        max(1, (CGFloat(max(10, min(48, style.fontSize))) + 6) * CGFloat(max(0, min(3, style.lineHeight))))
    }

    /// 显示区域为 0 时一条都不放（main 的滑杆下限就是 0）。
    private var maxLanes: Int {
        max(0, Int((bounds.height * CGFloat(max(0, min(1, style.area))) - 12) / laneHeight))
    }

    /// 找不到空轨道时返回 nil：海量弹幕关着就丢这条，开着才叠。
    private func laneIndex(mode: Int, width: CGFloat, now: Double) -> Int? {
        let limit = maxLanes
        guard limit > 0 else { return nil }
        for lane in 0..<limit where isLaneFree(lane: lane, mode: mode, width: width, now: now) {
            return lane
        }
        guard style.massive else { return nil }
        return Int.random(in: 0..<limit)
    }

    private func isLaneFree(lane: Int, mode: Int, width: CGFloat, now: Double) -> Bool {
        for item in labels where item.lane == lane && item.mode == mode {
            if mode == 1 {
                let progress = (now - item.startTime) / item.duration
                let x = bounds.width - CGFloat(progress) * (bounds.width + item.bounds.width)
                if x + item.bounds.width > bounds.width - 16 {
                    return false
                }
            } else if now - item.startTime < item.duration {
                return false
            }
        }
        return true
    }

    private func clearLabels() {
        for label in labels {
            label.removeFromSuperview()
        }
        labels.removeAll()
        sampleFilled = false
    }

    // MARK: - 颜色

    private var currentScreenScale: CGFloat {
        let scale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
        return scale > 0 ? scale : 1
    }

    @inline(__always)
    private func snapToPixel(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }

    private static func color(_ value: Int) -> UIColor {
        let rgb = max(0, min(0xFFFFFF, value))
        let red = CGFloat((rgb >> 16) & 0xFF) / 255
        let green = CGFloat((rgb >> 8) & 0xFF) / 255
        let blue = CGFloat(rgb & 0xFF) / 255
        return UIColor(red: red, green: green, blue: blue, alpha: 1)
    }
}
