//
//  PictureInPictureController.swift
//  Kazumi
//
//  mpv sample-buffer PiP. This object is the sole owner of the frame feed and
//  the complete PiP/background lifecycle.
//

import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import QuartzCore
import UIKit

@MainActor
final class PictureInPictureController: NSObject {
    enum Settlement: Equatable {
        case active
        case backgroundFallback(String)
        case stoppedInBackground
        case foreground
    }

    private enum Phase: Equatable {
        case inline
        case starting(Int)
        case active(Int)
        case restoring(Int)
        case settled(Int)
    }

    private var hostView = PiPHostView()
    private var pipController: AVPictureInPictureController?
    private var copier: PiPFrameCopier?
    private weak var surface: PlayerSurfaceModel?
    private weak var engine: MPVEngine?
    private weak var playerScene: UIWindowScene?

    private var captureTimer: DispatchSourceTimer?
    private var captureCadence: Double?
    private var startTask: Task<Void, Never>?
    private var startResponseTask: Task<Void, Never>?
    private var foregroundTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var stopObservationTask: Task<Void, Never>?
    private var restoreCompletion: ((Bool) -> Void)?
    private var restoringFromSystem = false
    private var foregroundCloseRequested = false
    private var systemTransitionStarted = false
    private var explicitStartCount = 0
    private var startSource = "none"
    private var cycleHostTime: CFTimeInterval = 0
    private var automaticWaitHostTime: CFTimeInterval = 0
    private var startResponseHostTime: CFTimeInterval = 0
    private var restoreHostTime: CFTimeInterval = 0
    private var pendingControllerStop = false
    private var cycle = 0
    private var phase: Phase = .inline
    private var deliveredSettlement: Settlement?
    private var pipBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// PlayerScreen receives one policy event stream instead of coordinating
    /// separate start/fail/stop callbacks.
    var onSettlement: ((Settlement) -> Void)?
    var onActiveChanged: ((Bool) -> Void)?

    private(set) var isActive = false

    private var contentIsPrimaryAndPlaying = false
    private var automaticStartAllowed = false

    func setAutomaticStartAllowed(_ allowed: Bool) {
        automaticStartAllowed = allowed
        if !allowed {
            setAutomaticStart(false, reason: "自动设置关闭（不拆活动手动小窗）")
            cancelUnsentAutomaticStart(reason: "自动设置关闭")
        } else {
            refreshAutomaticStart(reason: "前台播放资格")
        }
    }

    /// A real pause updates playback state even during AVKit's transition.
    func setPlaying(_ playing: Bool) {
        contentIsPrimaryAndPlaying = playing
        switch phase {
        case .starting, .restoring:
            // Do not synchronously interrupt transition frames. The existing
            // capture/playback delegates still observe the actual pause.
            break
        default:
            copier?.driveSynchronizer(engine: engine)
        }
        if !playing {
            setAutomaticStart(false, reason: "内容不再播放")
            cancelUnsentAutomaticStart(reason: "内容不再播放")
        } else {
            refreshAutomaticStart(reason: "内容正在前台播放")
        }
        pipController?.invalidatePlaybackState()
    }

    // MARK: - Public lifecycle

    func prepare(engine: MPVEngine?, surface: PlayerSurfaceModel) {
        let background = (engine?.playerScene ?? playerScene)?.activationState == .background
        var result = "source未就绪"
        log("prepare attempted background=\(background) engineReady=\(engine?.handle != nil)")
        defer {
            log("prepare result=\(result) background=\(background) sourceReady=\(pipController?.contentSource != nil && copier != nil && hostView.window != nil) copyReady=\(copier != nil) cadence=\(captureCadence.map { String(format: "%.6f", $0) } ?? "off")")
        }
        if hasOngoingPictureInPicture {
            // 活动小窗期间换集：surface/engine 必须跟上，否则代理回调仍按
            // 上一集的时长作答，copier 也还绑在已停止的旧引擎上（小窗冻结）。
            self.surface = surface
            contentIsPrimaryAndPlaying = surface.isPlaying
            let engineChanged = copier.map { $0.engine !== engine } ?? false
            let transitioning: Bool
            switch phase {
            case .starting, .restoring:
                transitioning = true
            default:
                transitioning = false
            }
            if engineChanged, !transitioning, let engine, engine.handle != nil {
                self.engine?.setPictureInPictureFrameFeedActive(false)
                self.engine = engine
                copier?.retarget(engine: engine)
                engine.setPictureInPictureFrameFeedActive(true)
                engine.requestRender()
                // 换集后时长/进度都变了，让系统重读一遍，避免小窗进度条停在上一集。
                pipController?.invalidatePlaybackState()
                result = "活动小窗换引擎改绑"
            } else {
                result = self.engine === engine ? "同引擎沿用活动周期/节拍/资格" : "过渡中保留原内容源"
            }
            return
        }
        self.surface = surface
        guard phase == .inline, let engine, engine.handle != nil else { return }
        if self.engine !== engine {
            self.engine?.setPictureInPictureFrameFeedActive(false)
        }
        self.engine = engine
        contentIsPrimaryAndPlaying = surface.isPlaying
        guard ensureController(), attachHostIfNeeded() else { return }

        let engineChanged = copier.map { $0.engine !== engine } ?? false
        if let copier, engineChanged {
            // AVSampleBufferRenderSynchronizer 不允许把同一个 renderer 再加到
            // 另一个同步器上。换集时驱动器复用同一个 hostView/displayLayer，
            // 因此这里只能把现有 copier 改绑到新引擎，绝不能 teardown 后重建：
            // 重建会在 init 里对同一个 renderer 再 addRenderer，直接抛
            // NSInvalidArgumentException 崩溃（真机 3.0.2 自动连播复现）。
            copier.retarget(engine: engine)
        }
        let alreadyPrepared = copier != nil && captureTimer != nil
        if copier == nil {
            let next = PiPFrameCopier(engine: engine, displayLayer: hostView.displayLayer)
            next.onLog = { [weak self] in self?.log($0) }
            next.onVideoAspectChanged = { [weak self] in self?.syncHostAspect($0) }
            copier = next
        }
        setCaptureCadence(0.5, reason: "内联低频")
        refreshAutomaticStart(reason: "内容源已准备")
        if !alreadyPrepared || engineChanged {
            copier?.driveSynchronizer(engine: engine)
            engine.requestRender()
        }
        result = alreadyPrepared ? (engineChanged ? "inline换引擎复用" : "inline幂等复用") : "内容源已建立"
    }

    /// Forwarded exactly once for a real scene background transition.
    func handleBackground(engine: MPVEngine?, surface: PlayerSurfaceModel) {
        guard (engine?.playerScene ?? playerScene)?.activationState == .background else {
            log("忽略非播放器 s1 后台通知")
            return
        }
        if hasOngoingPictureInPicture {
            log("后台沿用 starting/active/restoring 当前周期；prepare后台未发生，cadence不变")
            return
        }
        if pendingControllerStop {
            log("后台等待当前周期 didStop，不新建周期、不 prepare")
            return
        }
        beginCycle(source: "auto-pending")
        let currentCycle = cycle
        phase = .inline
        contentIsPrimaryAndPlaying = surface.isPlaying
        guard automaticStartAllowed else {
            settle(.backgroundFallback("自动设置关闭"), cycle: currentCycle)
            return
        }
        guard surface.isPlaying else {
            settle(.backgroundFallback("内容未在播放"), cycle: currentCycle)
            return
        }
        guard let engine, engine.handle != nil else {
            settle(.backgroundFallback("mpv 句柄未就绪"), cycle: currentCycle)
            return
        }
        self.engine = engine
        self.surface = surface
        prepare(engine: engine, surface: surface)
        guard ensureController(), attachHostIfNeeded(), copier != nil else {
            settle(.backgroundFallback("画中画内容源不可用"), cycle: currentCycle)
            return
        }

        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            settle(.backgroundFallback("设备或系统不支持画中画"), cycle: currentCycle)
            return
        }
        phase = .starting(currentCycle)
        isActive = false
        setCaptureCadence(1.0 / 30.0, reason: "后台启动")
        copier?.driveSynchronizer(engine: engine)
        beginBackgroundTaskIfNeeded()
        log("BEFORE 后台自动启动：possible=\(pipController?.isPictureInPicturePossible == true) active=否 帧年龄=\(frameAgeText)s；单次启动，不再用新帧门控与三次连发")
        startOnce(cycle: currentCycle, reason: "后台自动启动", manual: false, warmup: 0.15)
    }

    /// Only s1 activation owns ordinary foreground closing. A system restore
    /// retains its cycle and high-rate feed until didStop, not completion(true).
    func handleForeground() {
        if let scene = engine?.playerScene ?? surface?.engine?.playerScene { playerScene = scene }
        guard playerScene?.activationState == .foregroundActive else {
            log("忽略非播放器 s1 foregroundActive 通知")
            return
        }
        engine?.requestRender()
        if phase == .restoring(cycle) {
            log("前台通知沿用 restoring；不重复 stop、不换周期、不降频")
            return
        }
        foregroundCloseRequested = true
        if hasOngoingPictureInPicture {
            guard foregroundTask == nil, !pendingControllerStop else { return }
            let currentCycle = cycle
            foregroundTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled, self.cycle == currentCycle else { return }
                self.foregroundTask = nil
                guard !self.restoringFromSystem, self.hasOngoingPictureInPicture,
                      self.playerScene?.activationState == .foregroundActive else { return }
                if self.pipController?.isPictureInPictureActive == true || self.isActive {
                    self.phase = .restoring(currentCycle)
                    self.setAutomaticStart(false, reason: "普通前台待 didStop")
                    self.log("普通前台100ms宽限未被系统 restore 认领，发唯一 stop")
                    self.stopController(reason: "普通前台")
                } else if self.explicitStartCount == 0 && !self.systemTransitionStarted {
                    self.log("普通前台100ms宽限结束，取消尚未发自动请求；显式start=0")
                    self.settle(.foreground, cycle: currentCycle)
                } else {
                    self.log("普通前台100ms宽限结束，已发/系统过渡仍待有界 didStart；一到即单次 stop")
                }
            }
            return
        }
        if deliveredSettlement != nil, deliveredSettlement != .foreground {
            beginCycle(source: "foreground")
        }
        cancelStartWork()
        settle(.foreground, cycle: cycle)
        if let surface { prepare(engine: surface.engine, surface: surface) }
        refreshAutomaticStart(reason: "普通前台 source ready 资格重算")
    }

    private func closeAfterForegroundGraceIfNeeded() {
        guard foregroundCloseRequested, foregroundTask == nil, !restoringFromSystem,
              playerScene?.activationState == .foregroundActive else { return }
        phase = .restoring(cycle)
        stopController(reason: "普通前台宽限后 didStart")
    }

    func teardown() {
        setAutomaticStart(false, reason: "拆除")
        cancelStartWork()
        foregroundTask?.cancel()
        foregroundTask = nil
        restoreTask?.cancel()
        restoreTask = nil
        let completion = restoreCompletion
        restoreCompletion = nil
        restoringFromSystem = false
        completion?(false)
        endBackgroundTaskIfNeeded()
        if pipController?.isPictureInPictureActive == true {
            stopController(reason: "拆除")
        }
        stopObservationTask?.cancel()
        stopObservationTask = nil
        cycle += 1
        foregroundCloseRequested = false
        systemTransitionStarted = false
        pipController?.delegate = nil
        pipController = nil
        stopCapture(reason: "拆除")
        copier?.teardown()
        copier = nil
        hostView.removeFromSuperview()
        // renderer 无法安全从旧 synchronizer 上摘下来；换一块新宿主视图，
        // 下次 prepare 拿到的是全新的 displayLayer/renderer，避免重复 addRenderer。
        hostView = PiPHostView()
        isActive = false
        phase = .inline
        pendingControllerStop = false
        deliveredSettlement = nil
        surface = nil
        engine = nil
        onActiveChanged?(false)
        onActiveChanged = nil
        onSettlement = nil
        log("AFTER 状态收口：拆除（周期标志已清空，不带进下一轮）")
    }

    var isPictureInPictureActive: Bool {
        pipController?.isPictureInPictureActive == true
    }

    public var hasOngoingPictureInPicture: Bool {
        switch phase {
        case .starting, .active, .restoring: return true
        default: return isActive || pipController?.isPictureInPictureActive == true
        }
    }

    // MARK: - One start driver

    /// PlayerScreen's pip.enter button. One user gesture = one start attempt;
    /// it never goes through handleBackground/driveStart.
    func startFromUserTap(engine: MPVEngine?, surface: PlayerSurfaceModel) {
        guard !hasOngoingPictureInPicture, !pendingControllerStop else {
            log("手动按钮：starting/active/restoring 或待停止，忽略重复点击")
            return
        }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            log("AFTER 手动按钮：这台设备不支持画中画")
            return
        }
        guard let engine, engine.handle != nil else {
            log("AFTER 手动按钮：mpv 句柄未就绪")
            return
        }
        phase = .inline
        prepare(engine: engine, surface: surface)
        guard ensureController(), attachHostIfNeeded(), copier != nil else {
            log("AFTER 手动按钮：画中画内容源不可用")
            return
        }
        beginCycle(source: "manual")
        let currentCycle = cycle
        phase = .starting(currentCycle)
        isActive = false
        contentIsPrimaryAndPlaying = surface.isPlaying
        setAutomaticStart(false, reason: "手动启动")
        setCaptureCadence(1.0 / 30.0, reason: "手动启动")
        copier?.driveSynchronizer(engine: engine)
        pipController?.invalidatePlaybackState()
        log("BEFORE 手动按钮起小窗：possible=\(pipController?.isPictureInPicturePossible == true) active=否 帧年龄=\(frameAgeText)s；用户手势直接起，不等 possible")
        startOnce(cycle: currentCycle, reason: "手动按钮", manual: true, warmup: 0)
    }

    func stopFromUserTap() {
        log("BEFORE 手动按钮关小窗：active=\(isActive)")
        stopController(reason: "手动关闭")
    }

    /// Automatic: 150ms system-first, then bounded possible checks. Manual:
    /// a single immediate user-gesture request, without a possible gate.
    private func startOnce(cycle currentCycle: Int, reason: String, manual: Bool, warmup: Double) {
        guard contentIsPrimaryAndPlaying else {
            finishStartFailure(reason: "内容未在播放", cycle: currentCycle)
            return
        }
        cancelStartWork()
        if manual {
            guard let controller = pipController else { return }
            beginStart(controller: controller, cycle: currentCycle, reason: reason, manual: true)
            return
        }
        let waitBegan = CACurrentMediaTime()
        automaticWaitHostTime = waitBegan
        let firstPossible = pipController?.isPictureInPicturePossible == true
        log("自动 possible 首值=\(firstPossible)，系统先行150ms，总资格等待窗口3s")
        startTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(warmup * 1000)))
            var previousPossible = firstPossible
            while !Task.isCancelled {
                guard let self, self.isCurrentStartingCycle(currentCycle),
                      let controller = self.pipController else { return }
                guard !self.systemTransitionStarted, self.explicitStartCount == 0 else { return }
                let possible = controller.isPictureInPicturePossible
                let elapsed = CACurrentMediaTime() - waitBegan
                if possible != previousPossible {
                    self.log("自动 possible 变化=\(possible) 等待=\(String(format: "%.3f", elapsed))s")
                    previousPossible = possible
                }
                guard self.automaticStartAllowed, self.contentIsPrimaryAndPlaying,
                      self.playerScene?.activationState == .background else {
                    self.log("自动 possible 终值=\(possible) 等待=\(String(format: "%.3f", elapsed))s 资格失效；显式start=0")
                    self.finishStartFailure(reason: "自动启动资格失效", cycle: currentCycle)
                    return
                }
                if controller.isPictureInPictureActive || self.isActive {
                    self.settle(.active, cycle: currentCycle)
                    return
                }
                if elapsed >= 3 {
                    self.log("自动 possible 终值=\(possible) 等待=\(String(format: "%.3f", elapsed))s；显式start=0，不重试")
                    self.finishStartFailure(reason: "possible 有界等待结束", cycle: currentCycle)
                    return
                }
                if possible {
                    self.log("自动 possible 终值=true 等待=\(String(format: "%.3f", elapsed))s，退出等待并发唯一请求")
                    self.startTask = nil
                    self.beginStart(controller: controller, cycle: currentCycle, reason: reason, manual: false)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func beginStart(
        controller: AVPictureInPictureController,
        cycle currentCycle: Int,
        reason: String,
        manual: Bool
    ) {
        guard isCurrentStartingCycle(currentCycle), !systemTransitionStarted,
              explicitStartCount == 0, !controller.isPictureInPictureActive else { return }
        startSource = manual ? "manual" : "auto-explicit"
        explicitStartCount = 1
        setAutomaticStart(false, reason: "唯一显式启动已发")
        log("BEFORE \(reason) startPictureInPicture：possible=\(controller.isPictureInPicturePossible) 帧年龄=\(frameAgeText)s")
        observeStartResponse(cycle: currentCycle, reason: reason)
        controller.startPictureInPicture()
        log("AFTER \(reason) startPictureInPicture 已调用，等系统回执")
    }

    private func observeStartResponse(cycle currentCycle: Int, reason: String) {
        guard startResponseTask == nil else { return }
        startResponseHostTime = CACurrentMediaTime()
        startResponseTask = Task { @MainActor [weak self] in
            let responseDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while ContinuousClock.now < responseDeadline {
                guard let self, !Task.isCancelled, self.isCurrentStartingCycle(currentCycle) else { return }
                if self.pipController?.isPictureInPictureActive == true || self.isActive {
                    self.log("AFTER \(reason)：有界观察确认 active")
                    self.settle(.active, cycle: currentCycle)
                    self.closeAfterForegroundGraceIfNeeded()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self, !Task.isCancelled, self.isCurrentStartingCycle(currentCycle) else { return }
            self.log("AFTER \(reason)：3 秒未获启动回执 possible=\(self.pipController?.isPictureInPicturePossible == true)，不重试")
            self.finishStartFailure(reason: "单次启动/系统过渡未获回执", cycle: currentCycle)
        }
    }

    private func finishStartFailure(reason: String, cycle targetCycle: Int) {
        guard targetCycle == cycle else { return }
        if pipController?.isPictureInPictureActive == true {
            settle(.active, cycle: targetCycle)
            closeAfterForegroundGraceIfNeeded()
        } else if playerScene?.activationState == .foregroundActive {
            if startSource == "manual" { finishManualFailure(reason: reason) }
            else { settle(.foreground, cycle: targetCycle) }
        } else {
            settle(.backgroundFallback(reason), cycle: targetCycle)
        }
    }

    private func cancelUnsentAutomaticStart(reason: String) {
        guard case .starting = phase, startSource != "manual",
              !systemTransitionStarted, explicitStartCount == 0 else { return }
        // The next bounded check consumes lost eligibility; do not cancel the
        // response watchdog or synchronously cut the transition's frame feed.
        log("尚未发自动请求作废（\(reason)）；下次100ms有界检查收口")
    }

    private func beginCycle(source: String) {
        cancelStartWork()
        foregroundTask?.cancel()
        foregroundTask = nil
        cycle += 1
        deliveredSettlement = nil
        explicitStartCount = 0
        systemTransitionStarted = false
        restoringFromSystem = false
        foregroundCloseRequested = false
        startSource = source
        cycleHostTime = CACurrentMediaTime()
        automaticWaitHostTime = 0
        startResponseHostTime = 0
        log("建立周期")
    }

    private func finishManualFailure(reason: String) {
        log("AFTER 手动按钮：启动失败（\(reason)），回到内联，播放不受影响")
        settle(.foreground, cycle: cycle)
    }

    private var frameAgeText: String {
        copier?.lastEnqueuedFrameAge.map { String(format: "%.3f", $0) } ?? "无"
    }

    private func isCurrentStartingCycle(_ candidate: Int) -> Bool {
        phase == .starting(candidate) && cycle == candidate
    }

    private func cancelStartWork() {
        startTask?.cancel()
        startTask = nil
        startResponseTask?.cancel()
        startResponseTask = nil
    }

    private func stopController(reason: String) {
        guard let pipController, pipController.isPictureInPictureActive else { return }
        guard !pendingControllerStop else {
            log("stop 幂等忽略 source=\(reason)，等待本周期 didStop")
            return
        }
        pendingControllerStop = true
        setAutomaticStart(false, reason: reason)
        log("BEFORE stopPictureInPicture source=\(reason)")
        pipController.stopPictureInPicture()
        log("AFTER stopPictureInPicture source=\(reason)，高频保持到 didStop")
        stopObservationTask?.cancel()
        let currentCycle = cycle
        stopObservationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, self.cycle == currentCycle,
                  self.pendingControllerStop else { return }
            self.stopObservationTask = nil
            self.log("stop 2s仍未 didStop；保留当前活动/停止周期，不伪造停止、不强杀窗、不放行新周期")
        }
    }

    // MARK: - Single settlement funnel

    private func settle(_ settlement: Settlement, cycle targetCycle: Int) {
        guard targetCycle == cycle else { return }
        // active is the start acknowledgement, not the terminal close event.
        // Permit one active -> foreground/background-stop event in this cycle.
        if let deliveredSettlement {
            guard deliveredSettlement == .active,
                  settlement == .foreground || settlement == .stoppedInBackground else { return }
        }
        if case .backgroundFallback = settlement,
           pipController?.isPictureInPictureActive == true {
            // A late failure/timeout is not allowed to tear down an active PiP.
            log("收口前确认小窗已 active，按成功处理")
            settle(.active, cycle: targetCycle)
            return
        }

        switch settlement {
        case .active:
            guard phase != .restoring(targetCycle) else { return }
            phase = .active(targetCycle)
            isActive = true
            cancelStartWork()
            setAutomaticStart(false, reason: "小窗已启动")
            setCaptureCadence(1.0 / 30.0, reason: "画中画活动")
            endBackgroundTaskIfNeeded()
        case .foreground:
            foregroundTask?.cancel()
            foregroundTask = nil
            phase = .inline
            isActive = false
            cancelStartWork()
            foregroundCloseRequested = false
            restoringFromSystem = false
            endBackgroundTaskIfNeeded()
            setCaptureCadence(0.5, reason: "前台内联")
        case .backgroundFallback(let reason):
            guard phase != .settled(targetCycle) else { return }
            phase = .settled(targetCycle)
            isActive = false
            cancelStartWork()
            setAutomaticStart(false, reason: "后台失败收口")
            endBackgroundTaskIfNeeded()
            stopCapture(reason: "后台失败")
            log("静默暂停来源：启动失败收尾（\(reason)）")
        case .stoppedInBackground:
            guard phase != .settled(targetCycle) else { return }
            phase = .settled(targetCycle)
            isActive = false
            cancelStartWork()
            setAutomaticStart(false, reason: "后台关闭小窗")
            endBackgroundTaskIfNeeded()
            stopCapture(reason: "后台关闭小窗")
            log("静默暂停来源：onStoppedInBackground")
        }

        deliveredSettlement = settlement
        log("AFTER 状态收口：\(settlement.logDescription)（启动条件、失败、收口均不过 2 秒节流）")
        onActiveChanged?(settlement == .active)
        onSettlement?(settlement)
        if settlement == .foreground {
            contentIsPrimaryAndPlaying = surface?.isPlaying == true
            _ = attachHostIfNeeded()
            refreshAutomaticStart(reason: "前台收口后 source/playing/settings/s1 重算")
        }
    }

    // MARK: - Controller/source setup

    private func ensureController() -> Bool {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            log("这台设备 / 系统不支持画中画")
            return false
        }
        if pipController == nil {
            let source = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: hostView.displayLayer,
                playbackDelegate: self
            )
            let controller = AVPictureInPictureController(contentSource: source)
            controller.delegate = self
            controller.canStartPictureInPictureAutomaticallyFromInline = false
            pipController = controller
            log("自动启动门控初始关闭")
            log("BEFORE 画中画启动路径（旧实现）：driveStart 三次连发 + possible/新帧双门控 + 2 秒节流日志")
            log("AFTER 画中画启动路径：手动立即单次；自动150ms系统先行/possible有界等待；willStart认领，回执有界且不重试")
        }
        return true
    }

    private func setAutomaticStart(_ enabled: Bool, reason: String) {
        guard pipController?.canStartPictureInPictureAutomaticallyFromInline != enabled else { return }
        pipController?.canStartPictureInPictureAutomaticallyFromInline = enabled
        log("自动启动门控=\(enabled ? "开" : "关")（\(reason)）")
    }

    private func refreshAutomaticStart(reason: String) {
        guard automaticStartAllowed, contentIsPrimaryAndPlaying else {
            setAutomaticStart(false, reason: reason)
            return
        }
        // Preserve prebuilt inline eligibility while s1 is leaving foreground;
        // background prepare must not open a new gate or close an existing one
        // before the 150ms system-first window has run.
        guard phase == .inline, playerScene?.activationState == .foregroundActive else { return }
        let ready = !pendingControllerStop && restoreCompletion == nil
            && pipController?.isPictureInPictureActive != true
            && pipController?.contentSource != nil
            && copier != nil && hostView.window?.windowScene === playerScene
        setAutomaticStart(ready, reason: reason)
    }

    @discardableResult
    private func attachHostIfNeeded() -> Bool {
        if let scene = engine?.playerScene { playerScene = scene }
        guard let window = playerWindow else {
            log("找不到播放器所属窗口，画中画图层没地方挂")
            return false
        }
        guard hostView.window !== window else { return true }
        hostView.removeFromSuperview()
        hostView.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        hostView.autoresizingMask = [.flexibleRightMargin, .flexibleBottomMargin]
        window.insertSubview(hostView, at: 0)
        return true
    }

    private var playerWindow: UIWindow? {
        guard let playerScene else { return nil }
        return playerScene.windows.first(where: \.isKeyWindow) ?? playerScene.windows.first
    }

    private func syncHostAspect(_ aspect: CGFloat) {
        guard aspect.isFinite, aspect > 0.1, aspect < 10 else { return }
        let width: CGFloat = 320
        let height = max(2, (width / aspect).rounded())
        guard abs(hostView.frame.height - height) > 0.5 else { return }
        hostView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        log("内联画面形状改成 \(Int(width))×\(Int(height))（片源 \(String(format: "%.3f", aspect)):1）")
    }

    private func restoreAppWindow(cycle currentCycle: Int) {
        guard let target = playerScene, let window = playerWindow else {
            finishRestore(false, cycle: currentCycle, reason: "找不到 s1 播放器窗口")
            return
        }
        _ = attachHostIfNeeded()
        window.makeKeyAndVisible()
        window.setNeedsLayout()
        window.layoutIfNeeded()
        engine?.requestRender()
        if playerWindowReady {
            finishRestore(true, cycle: currentCycle, reason: "s1 已 active/window可见/布局完成")
            return
        }
        restoreTask = Task { @MainActor [weak self, weak target] in
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while ContinuousClock.now < deadline {
                guard let self, !Task.isCancelled, self.cycle == currentCycle,
                      self.restoreCompletion != nil else { return }
                guard let target, self.playerScene === target else {
                    self.finishRestore(false, cycle: currentCycle, reason: "s1 恢复目标已失效")
                    return
                }
                if self.playerWindowReady {
                    self.finishRestore(true, cycle: currentCycle, reason: "等到 s1 active/window可见/布局完成")
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self, !Task.isCancelled, self.cycle == currentCycle else { return }
            self.finishRestore(false, cycle: currentCycle, reason: "s1 激活/可见布局有界等待失败")
        }
        if target.activationState != .foregroundActive {
            UIApplication.shared.requestSceneSessionActivation(
                target.session,
                userActivity: nil,
                options: UIScene.ActivationRequestOptions()
            ) { [weak self] error in
                let description = error.localizedDescription
                Task { @MainActor [weak self] in
                    self?.finishRestore(false, cycle: currentCycle, reason: "s1 激活失败：\(description)")
                }
            }
        }
    }

    private var playerWindowReady: Bool {
        guard playerScene?.activationState == .foregroundActive,
              let window = playerWindow, window.windowScene === playerScene,
              hostView.window === window, !window.isHidden, window.alpha > 0,
              !window.bounds.isEmpty else { return false }
        window.layoutIfNeeded()
        hostView.layoutIfNeeded()
        return !hostView.bounds.isEmpty && hostView.superview != nil
    }

    private func finishRestore(_ restored: Bool, cycle targetCycle: Int, reason: String) {
        guard targetCycle == cycle, let completion = restoreCompletion else { return }
        restoreCompletion = nil
        restoreTask?.cancel()
        restoreTask = nil
        log("restore completion=\(restored) elapsed=\(String(format: "%.3f", CACurrentMediaTime() - restoreHostTime))s reason=\(reason)；true 不等于 didStop")
        if !restored, phase == .restoring(targetCycle), !pendingControllerStop, isActive {
            restoringFromSystem = false
            phase = .active(targetCycle)
            isActive = true
            // Keep the same cycle/active acknowledgement and feed. No stop or
            // window destruction is requested when restoring the UI fails.
            log("恢复失败沿用本周期 active，小窗不强杀")
        }
        completion(restored)
        // didStop may have arrived while s1 activation was still pending. The
        // completion is now consumed; finish the same cycle rather than leaving
        // the former restoring didStop early-return suspended forever.
        if cycle == targetCycle, !isActive, pipController?.isPictureInPictureActive != true,
           phase == .restoring(targetCycle) {
            settle(playerScene?.activationState == .foregroundActive ? .foreground : .stoppedInBackground, cycle: targetCycle)
        }
    }

    // MARK: - Capture cadence/background assertion

    private func setCaptureCadence(_ interval: Double, reason: String) {
        copier?.beginCapture()
        copier?.captureInterval = interval
        engine?.setPictureInPictureFrameFeedActive(interval < 0.1)
        if captureCadence != interval {
            captureCadence = interval
            log("喂帧节拍切换：\(interval < 0.1 ? "约30Hz" : "低频2Hz")（\(reason)）")
        }
        guard captureTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(33_333_333), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.copier?.requestCapture() }
        }
        timer.resume()
        captureTimer = timer
        log("喂帧节拍启动")
    }

    private func stopCapture(reason: String) {
        captureTimer?.cancel()
        captureTimer = nil
        captureCadence = nil
        copier?.endCapture()
        engine?.setPictureInPictureFrameFeedActive(false)
        log("喂帧节拍停止（\(reason)）")
    }

    private func beginBackgroundTaskIfNeeded() {
        guard pipBackgroundTask == .invalid else { return }
        pipBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "picture-in-picture-start") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.log("AFTER 后台任务到期：只记事件，不提前收口启动窗口")
                self.endBackgroundTaskIfNeeded()
            }
        }
    }

    private func endBackgroundTaskIfNeeded() {
        guard pipBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(pipBackgroundTask)
        pipBackgroundTask = .invalid
    }

    private func log(_ message: String) {
        let scene = playerScene?.session.persistentIdentifier ?? "none"
        let state = playerScene.map { String(describing: $0.activationState) } ?? "none"
        let elapsed = cycleHostTime > 0 ? CACurrentMediaTime() - cycleHostTime : 0
        let receiptElapsed = startResponseHostTime > 0 ? String(format: "%.3f", CACurrentMediaTime() - startResponseHostTime) : "none"
        KazumiLogBuffer.player("画中画: cycle=\(cycle) scene=\(scene)/\(state) phase=\(phase) startSource=\(startSource) startCalls=\(explicitStartCount) autoAllowed=\(automaticStartAllowed) playing=\(contentIsPrimaryAndPlaying)/\(surface?.isPlaying == true) gateReadback=\(pipController?.canStartPictureInPictureAutomaticallyFromInline == true) elapsed=\(String(format: "%.3f", elapsed))s receiptElapsed=\(receiptElapsed)s \(message)")
    }
}

private extension PictureInPictureController.Settlement {
    var logDescription: String {
        switch self {
        case .active: "已启动"
        case .backgroundFallback(let reason): "后台回退（\(reason)）"
        case .stoppedInBackground: "后台关闭"
        case .foreground: "回到前台"
        }
    }
}

// MARK: - AVKit callbacks

extension PictureInPictureController: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        guard pictureInPictureController === pipController else { return }
        if phase == .inline, automaticStartAllowed, contentIsPrimaryAndPlaying,
           pipController?.contentSource != nil, copier != nil, playerScene != nil, !pendingControllerStop,
           pictureInPictureController.canStartPictureInPictureAutomaticallyFromInline {
            // A foreground settlement may have rearmed real inline eligibility.
            // The actual gate/source readback authorizes the next system cycle;
            // didStart/fail/didStop alone never reopen a completed cycle.
            beginCycle(source: "system")
            phase = .starting(cycle)
            log("willStart 先于后台通知，系统认领本周期")
        }
        guard isCurrentStartingCycle(cycle) else {
            log("willStart 非当前 starting，保留现有结束/恢复周期")
            return
        }
        systemTransitionStarted = true
        if explicitStartCount == 0 { startSource = "system" }
        // Cancel only unsent warmup/possible checks, never the receipt watchdog.
        startTask?.cancel()
        startTask = nil
        setAutomaticStart(false, reason: "willStart 系统已过渡")
        setCaptureCadence(1.0 / 30.0, reason: "系统将启动")
        beginBackgroundTaskIfNeeded()
        let possibleWait = automaticWaitHostTime > 0 ? String(format: "%.3f", CACurrentMediaTime() - automaticWaitHostTime) : "none"
        log("willStart：系统已过渡 possible终值=\(pictureInPictureController.isPictureInPicturePossible) possible等待=\(possibleWait)s，抑制尚未发自动请求，保留有界回执观察")
        observeStartResponse(cycle: cycle, reason: "willStart")
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        guard pictureInPictureController === pipController else { return }
        log("didStart active=\(pictureInPictureController.isPictureInPictureActive)")
        if phase == .active(cycle) || phase == .restoring(cycle) {
            log("重复/恢复期间 didStart 沿用当前状态，不复活结束周期")
            return
        }
        guard isCurrentStartingCycle(cycle), deliveredSettlement == nil else {
            log("迟到 didStart 不属于当前启动周期，关闭而不重开资格")
            stopController(reason: "迟到 didStart")
            return
        }
        settle(.active, cycle: cycle)
        closeAfterForegroundGraceIfNeeded()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        guard pictureInPictureController === pipController else { return }
        log("fail：\(error.localizedDescription)")
        if isActive || pictureInPictureController.isPictureInPictureActive {
            log("迟到 fail 到达时小窗活动/恢复中，不覆盖本周期")
            if isCurrentStartingCycle(cycle) { settle(.active, cycle: cycle) }
            return
        }
        guard isCurrentStartingCycle(cycle) else {
            log("fail 非当前 starting，忽略迟到回执")
            return
        }
        setAutomaticStart(false, reason: "启动失败")
        if startSource == "manual" && !systemTransitionStarted {
            finishStartFailure(reason: error.localizedDescription, cycle: cycle)
        } else {
            // A willStart or explicit request may still acquire active after a
            // stale failure. Keep its existing deadline, without sending again.
            log("fail 保留本周期有界观察，不取消 watchdog、不重试")
        }
    }

    func pictureInPictureControllerWillStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        guard pictureInPictureController === pipController else { return }
        log("willStop source=\(pendingControllerStop ? "controller" : (restoringFromSystem ? "system-restore" : "system-close"))；高频保持到 didStop")
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        guard pictureInPictureController === pipController else { return }
        log("didStop pendingStop=\(pendingControllerStop) systemRestore=\(restoringFromSystem)")
        guard !pictureInPictureController.isPictureInPictureActive else {
            log("didStop 到达时控制器仍 active，忽略旧回执")
            return
        }
        if deliveredSettlement == .foreground || phase == .settled(cycle) {
            pendingControllerStop = false
            stopObservationTask?.cancel()
            stopObservationTask = nil
            log("didStop 结束已收口，不创建周期、不重新打开小窗")
            return
        }
        guard hasOngoingPictureInPicture || pendingControllerStop else {
            log("didStop 无活动周期，忽略重复回执")
            return
        }
        pendingControllerStop = false
        stopObservationTask?.cancel()
        stopObservationTask = nil
        foregroundTask?.cancel()
        foregroundTask = nil
        isActive = false
        if restoreCompletion != nil {
            if playerWindowReady {
                finishRestore(true, cycle: cycle, reason: "didStop 时 s1 可见布局已完成")
            } else {
                setCaptureCadence(0.5, reason: "didStop 已到，等待 restore 的 s1 真正就绪")
                log("didStop 已到，restore completion 继续有界等待；不遗留悬挂回执")
            }
            return
        }
        if playerScene?.activationState == .foregroundActive {
            settle(.foreground, cycle: cycle)
        } else {
            settle(.stoppedInBackground, cycle: cycle)
        }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
        completionHandler: @escaping (Bool) -> Void
    ) {
        guard pictureInPictureController === pipController,
              hasOngoingPictureInPicture, deliveredSettlement != .foreground else {
            log("restore 无当前活动周期，completion=false")
            completionHandler(false)
            return
        }
        guard restoreCompletion == nil, !restoringFromSystem else {
            log("restore 重复回调，额外 completion=false，不覆盖原回执")
            completionHandler(false)
            return
        }
        // A system restore can take over the ordinary foreground 100ms
        // close before it has sent stop. Never increment the active cycle.
        foregroundTask?.cancel()
        foregroundTask = nil
        cancelStartWork()
        phase = .restoring(cycle)
        isActive = pictureInPictureController.isPictureInPictureActive || isActive
        restoringFromSystem = true
        foregroundCloseRequested = false
        restoreCompletion = completionHandler
        restoreHostTime = CACurrentMediaTime()
        setAutomaticStart(false, reason: "系统恢复界面")
        setCaptureCadence(1.0 / 30.0, reason: "系统恢复过渡")
        log("restore：沿用活动周期，等待真实 s1 active/window可见/布局完成")
        restoreAppWindow(cycle: cycle)
    }
}

extension PictureInPictureController: @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        let range: CMTimeRange
        if let surface, surface.duration.isFinite, surface.duration > 0 {
            range = CMTimeRange(start: .zero, duration: CMTime(seconds: surface.duration, preferredTimescale: 600))
        } else {
            range = CMTimeRange(start: .zero, duration: .positiveInfinity)
        }
        let current = copier?.synchronizerCurrentTime ?? .invalid
        let contains = current.isValid && (range.duration.isPositiveInfinity || CMTimeRangeContainsTime(range, time: current))
        copier?.logPlaybackObservation("delegate timeRange containsCurrent=\(contains ? "是" : "否") current=\(current.seconds.isFinite ? String(format: "%.3f", current.seconds) : "无")")
        return range
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        let paused = surface?.isPlaying != true
        copier?.logPlaybackObservation("delegate isPlaybackPaused=\(paused ? "是" : "否")")
        return paused
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        guard let surface else { return }
        playing ? surface.play() : surface.pause()
        pictureInPictureController.invalidatePlaybackState()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        guard let surface else { completionHandler(); return }
        let seconds = CMTimeGetSeconds(skipInterval)
        guard seconds.isFinite, seconds != 0 else { completionHandler(); return }
        let target = max(0, surface.currentTime + seconds)
        surface.seek(to: target)
        copier?.prepareForSeek(to: target, paused: !surface.isPlaying)
        pictureInPictureController.invalidatePlaybackState()
        completionHandler()
    }
}

// MARK: - Display source

private final class PiPHostView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        alpha = 0.01
        isUserInteractionEnabled = false
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.clear.cgColor
        displayLayer.isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class PiPFrameCopier {
    fileprivate weak var engine: MPVEngine?
    private let renderer: AVSampleBufferVideoRenderer
    private let synchronizer = AVSampleBufferRenderSynchronizer()

    var onLog: ((String) -> Void)?
    var onVideoAspectChanged: ((CGFloat) -> Void)?
    var captureInterval = 0.5 {
        willSet {
            if newValue != captureInterval {
                reportCaptureWindow(reason: "cadence change", force: true)
            }
        }
    }
    private(set) var isCapturing = false

    private var formatDescription: CMVideoFormatDescription?
    private var formatWidth = 0
    private var formatHeight = 0
    private var formatPixelFormat: OSType = 0
    private var lastPTS = Double.nan
    private var lastEnqueuedHostTime: CFTimeInterval?
    private var lastCaptureHostTime: CFTimeInterval = 0
    private var captureTask: Task<Void, Never>?
    private var lastReportedAspect: CGFloat = 0
    private var didLogFirstFrame = false
    private var didLogFailure = false
    private var lastObservationLogTime: CFTimeInterval = 0
    private var lastFeedEventHostTime: CFTimeInterval = 0
    private var lastFeedEventPTS = Double.nan
    private var captureGeneration = 0
    private var captureWindowHostTime: CFTimeInterval = 0
    private var captureCounts: [String: Int] = [:]

    init(engine: MPVEngine, displayLayer: AVSampleBufferDisplayLayer) {
        self.engine = engine
        renderer = displayLayer.sampleBufferRenderer
        synchronizer.addRenderer(renderer)
        // Set after self is initialized: retain the migration line once, with
        // the controller's standard 画中画 log prefix.
        KazumiLogBuffer.player("画中画: 喂帧 API 迁移：displayLayer flush/enqueue/controlTimebase → sampleBufferRenderer + renderSynchronizer")
    }

    var lastEnqueuedFrameAge: Double? {
        lastEnqueuedHostTime.map { CACurrentMediaTime() - $0 }
    }

    /// 换集时复用同一个 renderer/同步器，只把取帧来源改到新引擎。
    /// 不能重建 copier：displayLayer 的 sampleBufferRenderer 已经在当前
    /// synchronizer 上，重复 addRenderer 会抛异常。
    func retarget(engine: MPVEngine) {
        guard self.engine !== engine else { return }
        captureGeneration += 1
        captureTask?.cancel()
        captureTask = nil
        renderer.flush()
        formatDescription = nil
        formatWidth = 0
        formatHeight = 0
        formatPixelFormat = 0
        lastPTS = .nan
        lastEnqueuedHostTime = nil
        didLogFirstFrame = false
        didLogFailure = false
        self.engine = engine
        driveSynchronizer(engine: engine)
    }

    func driveSynchronizer(engine: MPVEngine?) {
        let timing = engine?.pictureInPictureTiming()
        let time = timing?.time ?? synchronizer.currentTime().seconds
        let paused = timing?.paused ?? false
        let anchor = lastPTS.isFinite && lastPTS >= 0 ? lastPTS : time
        synchronizer.setRate(
            paused ? 0 : 1,
            time: CMTime(seconds: max(0, anchor), preferredTimescale: 600)
        )
    }

    func logFeedEvent(_ event: String, frame: MPVRawFrame? = nil) {
        let now = CACurrentMediaTime()
        guard lastFeedEventHostTime == 0 || now - lastFeedEventHostTime >= 5 else { return }
        lastFeedEventHostTime = now
        let size = frame.map { "\($0.width)x\($0.height)" } ?? "无"
        let pts = lastPTS
        let age = lastEnqueuedFrameAge ?? -1
        let syncSeconds = synchronizer.currentTime().seconds
        onLog?("喂帧事件 \(event) 尺寸=\(size) pts=\(String(format: "%.3f", pts.isFinite ? pts : -1)) 距上一帧=\(String(format: "%.2f", age))s 同步器 rate=\(String(format: "%.2f", Double(synchronizer.rate))) time=\(String(format: "%.2f", syncSeconds.isFinite ? syncSeconds : -1)) renderer=\(String(describing: renderer.status))")
        let before = lastFeedEventPTS
        lastFeedEventPTS = pts
        guard before.isFinite, before >= 0, pts.isFinite, pts > before + 90 else { return }
        onLog?("画中画: 实现前／实现后 时基跨度过大 before=\(String(format: "%.1f", before)) after=\(String(format: "%.1f", pts))，已回绕重置")
    }

    var synchronizerCurrentTime: CMTime { synchronizer.currentTime() }

    func beginCapture() {
        guard !isCapturing else { return }
        isCapturing = true
        captureWindowHostTime = CACurrentMediaTime()
        captureCounts.removeAll(keepingCapacity: true)
        lastCaptureHostTime = 0
        driveSynchronizer(engine: engine)
        logFeedEvent("beginCapture 起搏")
    }

    func endCapture() {
        reportCaptureWindow(reason: "endCapture", force: true)
        captureWindowHostTime = 0
        isCapturing = false
        captureGeneration += 1
        captureTask?.cancel()
        captureTask = nil
    }

    func prepareForSeek(to seconds: Double, paused: Bool) {
        renderer.flush()
        lastPTS = .nan
        syncTime(to: seconds, paused: paused)
        logSynchronizerObservation("seek 后时基重置")
    }

    func teardown() {
        reportCaptureWindow(reason: "teardown", force: true)
        captureWindowHostTime = 0
        isCapturing = false
        captureGeneration += 1
        captureTask?.cancel()
        captureTask = nil
        renderer.flush()
        // The synchronizer owns this renderer for the copier's lifetime. Do not
        // detach on iOS 26: removeRenderer requires an asynchronous completion.
        formatDescription = nil
        formatWidth = 0
        formatHeight = 0
        formatPixelFormat = 0
        lastEnqueuedHostTime = nil
    }

    func requestCapture() {
        guard isCapturing, let engine else { return }
        let now = CACurrentMediaTime()
        captureCounts["tick", default: 0] += 1
        defer { reportCaptureWindow(reason: "5s window") }
        if captureTask != nil {
            guard now - lastCaptureHostTime >= 1 else {
                captureCounts["skip-inflight", default: 0] += 1
                return
            }
            captureCounts["hung-release", default: 0] += 1
            captureGeneration += 1
            captureTask?.cancel()
            captureTask = nil
            logFeedEvent("取帧挂住超 1 秒，放走本轮以保住 33ms 节拍")
        }
        let cadenceTolerance = captureInterval < 0.1 ? 0.001 : 0
        guard lastCaptureHostTime == 0 || now - lastCaptureHostTime >= captureInterval - cadenceTolerance else {
            captureCounts["skip-cadence", default: 0] += 1
            return
        }
        captureCounts["request", default: 0] += 1
        lastCaptureHostTime = now
        captureGeneration += 1
        let generation = captureGeneration
        captureTask = Task { [weak self] in
            guard let self else { return }
            let frame = await engine.captureRawFrameForPictureInPicture()
            guard self.captureGeneration == generation else { return }
            self.captureCounts["return", default: 0] += 1
            self.captureTask = nil
            guard self.isCapturing else { return }
            guard let frame else {
                self.captureCounts["no-frame", default: 0] += 1
                self.logOnce("screenshot-raw 没拿到画中画帧")
                self.driveSynchronizer(engine: engine)
                self.logFeedEvent("断帧：原帧未取到，保持时基")
                return
            }
            self.captureCounts["raw-frame", default: 0] += 1
            self.enqueue(frame)
        }
    }

    private func enqueue(_ frame: MPVRawFrame) {
        guard let engine else { return }
        let (time, paused) = engine.pictureInPictureTiming()
        if paused, lastPTS.isFinite, abs(time - lastPTS) < 0.05 {
            captureCounts["skip-paused", default: 0] += 1
            driveSynchronizer(engine: engine)
            logFeedEvent("断帧：mpv 暂停，保持时基")
            return
        }
        if time.isFinite, lastPTS.isFinite, time + 0.5 < lastPTS {
            renderer.flush()
            lastPTS = .nan
        }
        var pts = time.isFinite ? max(0, time) : (lastPTS.isFinite ? lastPTS + 1.0 / 30.0 : 0)
        if lastPTS.isFinite, pts <= lastPTS {
            pts = lastPTS + 1.0 / 30.0
            logFeedEvent("时基未前进，按 30fps 递增 pts 保持喂帧")
        }

        let aspect = CGFloat(frame.width) / CGFloat(max(1, frame.height))
        if aspect.isFinite, aspect > 0.1, aspect < 10, abs(aspect - lastReportedAspect) > 0.001 {
            lastReportedAspect = aspect
            onVideoAspectChanged?(aspect)
        }
        guard let pixelBuffer = frame.makePixelBuffer() else {
            captureCounts["pixel-failure", default: 0] += 1
            logOnce("原始帧转 CVPixelBuffer 失败（\(frame.format)，\(frame.width)×\(frame.height)）")
            driveSynchronizer(engine: engine)
            logFeedEvent("断帧：转缓冲失败，保持时基", frame: frame)
            return
        }
        // 同一条播放内核里分辨率或像素格式变了：旧 formatDescription 不能再用，
        // 否则每帧 CMSampleBufferCreateReadyWithImageBuffer 都会失败，小窗永久冻住。
        let pixelWidth = CVPixelBufferGetWidth(pixelBuffer)
        let pixelHeight = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if formatDescription != nil,
           formatWidth > 0,
           (formatWidth != pixelWidth
            || formatHeight != pixelHeight
            || formatPixelFormat != pixelFormat) {
            formatDescription = nil
            formatWidth = 0
            formatHeight = 0
            formatPixelFormat = 0
            renderer.flush()
            lastPTS = .nan
            logFeedEvent("尺寸或像素格式变化 → 重建 formatDescription", frame: frame)
        }
        guard let sampleBuffer = makeSampleBuffer(pixelBuffer: pixelBuffer, presentationTime: pts) else {
            captureCounts["sample-failure", default: 0] += 1
            logOnce("CMSampleBuffer 创建失败")
            driveSynchronizer(engine: engine)
            logFeedEvent("断帧：封装失败，保持时基", frame: frame)
            return
        }

        if renderer.status == .failed {
            captureCounts["renderer-failed", default: 0] += 1
            renderer.flush()
            logFeedEvent("renderer.failed 已 flush", frame: frame)
        }
        guard renderer.isReadyForMoreMediaData else {
            captureCounts["renderer-not-ready", default: 0] += 1
            driveSynchronizer(engine: engine)
            logFeedEvent("断帧：renderer 未就绪，保持时基", frame: frame)
            return
        }
        syncTime(to: pts, paused: paused)
        renderer.enqueue(sampleBuffer)
        captureCounts["enqueue", default: 0] += 1
        lastPTS = pts
        lastEnqueuedHostTime = CACurrentMediaTime()
        logFeedEvent("喂入新帧", frame: frame)
        if !didLogFirstFrame {
            didLogFirstFrame = true
            onLog?("取到第一帧 \(frame.width)x\(frame.height)")
        }
        logSynchronizerObservation("喂帧观察")
    }

    private func syncTime(to seconds: Double, paused: Bool) {
        guard seconds.isFinite else { return }
        // Pausing freezes at the actual media position, never at zero.
        if paused { logSynchronizerObservation("mpv 内核暂停，保持当前时基") }
        synchronizer.setRate(
            paused ? 0 : 1,
            time: CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        )
    }

    private func makeSampleBuffer(pixelBuffer: CVPixelBuffer, presentationTime: Double) -> CMSampleBuffer? {
        if formatDescription == nil {
            var description: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &description
            )
            guard status == noErr, let description else { return nil }
            formatDescription = description
            formatWidth = CVPixelBufferGetWidth(pixelBuffer)
            formatHeight = CVPixelBufferGetHeight(pixelBuffer)
            formatPixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        }
        guard let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: presentationTime, preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        return status == noErr ? sampleBuffer : nil
    }

    private func reportCaptureWindow(reason: String, force: Bool = false) {
        let now = CACurrentMediaTime()
        guard captureWindowHostTime > 0 else { return }
        let elapsed = now - captureWindowHostTime
        guard force || elapsed >= 5 else { return }
        if captureInterval < 0.1 {
            let window = String(format: "%.3f", captureWindowHostTime)
            let feed = ["tick", "request", "return", "raw-frame", "enqueue", "skip-inflight", "skip-cadence"]
                .map { "\($0)=\(captureCounts[$0, default: 0])" }.joined(separator: " ")
            let drops = ["skip-paused", "hung-release", "no-frame", "pixel-failure", "sample-failure", "renderer-failed", "renderer-not-ready"]
                .map { "\($0)=\(captureCounts[$0, default: 0])" }.joined(separator: " ")
            // Keep each payload below the diagnostics' 600-character limit,
            // including the shared lifecycle prefix. Both lines share window.
            onLog?("capture window=\(window) part=1 \(reason) duration=\(String(format: "%.3f", elapsed))s interval=\(String(format: "%.6f", captureInterval)) timer=33333333ns \(feed)")
            onLog?("capture window=\(window) part=2 \(drops)；request=取帧API/enqueue=入队，非呈现FPS；submit/reply/timeout由Engine统计")
        }
        captureWindowHostTime = now
        captureCounts.removeAll(keepingCapacity: true)
    }

    private func logSynchronizerObservation(_ reason: String) {
        logPlaybackObservation("\(reason)；pts=\(lastPTS.isFinite ? String(format: "%.3f", lastPTS) : "无")")
    }

    func logPlaybackObservation(_ message: String) {
        let now = CACurrentMediaTime()
        guard now - lastObservationLogTime >= 2 else { return }
        lastObservationLogTime = now
        let current = synchronizer.currentTime().seconds
        let ptsSyncDelta = lastPTS.isFinite && current.isFinite ? String(format: "%.3f", lastPTS - current) : "无"
        onLog?("\(message)；同步器 rate=\(String(format: "%.2f", synchronizer.rate)) current=\(current.isFinite ? String(format: "%.3f", current) : "无") pts-sync=\(ptsSyncDelta)s")
    }

    private func logOnce(_ message: String) {
        guard !didLogFailure else { return }
        didLogFailure = true
        onLog?(message)
    }
}
