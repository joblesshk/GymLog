import Foundation
import Observation

/// One timed segment of a WOD's execution -- a plain countdown length plus
/// a display label. A single AMRAP/For-Time-with-cap prescription is one
/// phase; EMOM/interval prescriptions are N phases (EMOM: N identical work
/// intervals; a generic interval/Tabata preset: alternating work/rest
/// phases, `2 × repeats` of them). This is the ONE engine that covers all
/// four formats' countdown needs -- see `WODTimerModel.forPrescription`.
public struct WODTimerPhase: Equatable, Sendable {
    public var label: String
    public var durationSeconds: Int
    /// True for a work interval, false for a rest interval -- irrelevant
    /// for AMRAP/For-Time's single phase, meaningful for EMOM/interval so
    /// the UI can style a rest phase differently.
    public var isWork: Bool

    public init(label: String, durationSeconds: Int, isWork: Bool = true) {
        self.label = label
        self.durationSeconds = max(0, durationSeconds)
        self.isWork = isWork
    }
}

public enum WODTimerState: Equatable, Sendable {
    case idle
    case running
    case paused
    case ended
}

/// A lightweight, Codable recovery anchor for surviving the app being
/// killed and relaunched mid-WOD -- persisted alongside the WOD draft via
/// the same `DraftPersistence`/debounced-autosave machinery M0 already
/// built for strength drafts (`CONTRACT-M10.md` §7 follow-up), not a new
/// persistence mechanism.
///
/// 工程审阅 §7: "系统时间变更/重启需明确标记待核对" -- restoring from this
/// anchor always sets `WODTimerModel.resumedFromPersistedState = true` so
/// the UI can show an explicit "请核对" notice, rather than silently
/// trusting a wall-clock deadline that might have been crossed by a device
/// reboot or manual clock change while the process was dead.
public struct WODTimerAnchor: Codable, Equatable, Sendable {
    public var phaseIndex: Int
    /// The wall-clock instant the CURRENT phase is due to end.
    public var currentPhaseDeadline: Date
    /// Elapsed seconds accumulated in phases strictly before the current
    /// one (needed to resume `elapsedSeconds` correctly for count-up mode
    /// and for cross-phase progress display).
    public var elapsedBeforeCurrentPhase: Int
    public var isCountUp: Bool
    /// For count-up mode only: when the timer was originally started.
    public var countUpStartedAt: Date?

    public init(phaseIndex: Int, currentPhaseDeadline: Date, elapsedBeforeCurrentPhase: Int, isCountUp: Bool, countUpStartedAt: Date?) {
        self.phaseIndex = phaseIndex
        self.currentPhaseDeadline = currentPhaseDeadline
        self.elapsedBeforeCurrentPhase = elapsedBeforeCurrentPhase
        self.isCountUp = isCountUp
        self.countUpStartedAt = countUpStartedAt
    }
}

/// Independent WOD execution timer -- 工程审阅 §7: "只有一个主训练计时器"
/// (never conflated with `RestTimerModel`, which is a separate, shorter
/// between-set countdown that stays untouched by this type). Same
/// deadline-based-recompute discipline as `RestTimerModel` (see that type's
/// own doc comment for why per-second decrementing drifts under
/// backgrounding) -- `sync()` always re-derives from a wall-clock deadline,
/// never accumulates by subtraction.
///
/// Two modes:
/// - Phased countdown (`phases` non-empty): AMRAP/For-Time-with-cap (one
///   phase) or EMOM/interval (many phases) -- auto-advances to the next
///   phase when the current one reaches zero, firing `onPhaseFinish` (not
///   `onPhaseFinish` for every SECOND, only once per phase boundary --
///   "不逐秒累减或补播所有漏掉的提醒").
/// - Count-up (`phases` empty, `isCountUp == true`): an uncapped For Time,
///   counts elapsed seconds indefinitely until `end()` is called.
@MainActor
@Observable
public final class WODTimerModel {
    public private(set) var phases: [WODTimerPhase]
    public private(set) var isCountUp: Bool
    public private(set) var state: WODTimerState = .idle
    public private(set) var currentPhaseIndex: Int = 0
    public private(set) var remainingSecondsInPhase: Int
    /// Total elapsed seconds since the timer first started (across all
    /// phases, or since the count-up began) -- the AUTHORITATIVE value a
    /// completed For Time's `WODResult.elapsedSeconds` should be read from.
    public private(set) var elapsedSeconds: Int = 0
    /// True immediately after `restore(from:)` -- see `WODTimerAnchor`'s
    /// doc comment. The UI should show an explicit notice and let the
    /// coach confirm/adjust before trusting the resumed reading, then this
    /// flag can be cleared by the caller (`acknowledgeResumedState()`).
    public private(set) var resumedFromPersistedState = false

    /// Fires once when phase `index` finishes (auto-advance already
    /// applied) -- UI hooks a local-notification schedule / sound here.
    public var onPhaseFinish: ((_ finishedIndex: Int) -> Void)?
    /// Fires once when the LAST phase finishes (phased mode only).
    public var onAllPhasesFinished: (() -> Void)?

    private var deadline: Date?
    private var countUpStartedAt: Date?
    private var elapsedBeforeCurrentPhase = 0
    private let now: () -> Date
    private var ticker: Task<Void, Never>?

    /// Phased countdown mode (AMRAP/For-Time-with-cap/EMOM/interval).
    public init(phases: [WODTimerPhase], now: @escaping () -> Date = Date.init) {
        self.phases = phases
        self.isCountUp = false
        self.remainingSecondsInPhase = phases.first?.durationSeconds ?? 0
        self.now = now
    }

    /// Count-up mode (an uncapped For Time).
    public init(countUp now: @escaping () -> Date = Date.init) {
        self.phases = []
        self.isCountUp = true
        self.remainingSecondsInPhase = 0
        self.now = now
    }

    // MARK: - Derived display state

    public var currentPhase: WODTimerPhase? {
        guard currentPhaseIndex < phases.count else { return nil }
        return phases[currentPhaseIndex]
    }

    public var nextPhase: WODTimerPhase? {
        let nextIndex = currentPhaseIndex + 1
        guard nextIndex < phases.count else { return nil }
        return phases[nextIndex]
    }

    public var displayText: String {
        let seconds = isCountUp ? elapsedSeconds : remainingSecondsInPhase
        return String(format: "%d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
    }

    // MARK: - Controls

    public func start() {
        guard state == .idle || state == .paused else { return }
        if state == .idle {
            elapsedSeconds = 0
            elapsedBeforeCurrentPhase = 0
            currentPhaseIndex = 0
            remainingSecondsInPhase = phases.first?.durationSeconds ?? 0
            countUpStartedAt = isCountUp ? now() : nil
        }
        if isCountUp {
            // Resuming a paused count-up: shift the anchor so already-
            // elapsed time is preserved (`elapsedSeconds` was frozen by
            // `pause()`'s own `sync()` call).
            countUpStartedAt = now().addingTimeInterval(-TimeInterval(elapsedSeconds))
        } else {
            deadline = now().addingTimeInterval(TimeInterval(remainingSecondsInPhase))
        }
        state = .running
        startTicker()
    }

    public func pause() {
        guard state == .running else { return }
        sync()
        stopTicker()
        guard state == .running else { return } // sync() may have already ended it
        state = .paused
        deadline = nil
    }

    /// Ends the timer early (coach hits "結束" before all phases finish, or
    /// after finishing an uncapped For Time) -- `elapsedSeconds` at this
    /// instant is the authoritative reading the caller should read into
    /// the result.
    public func end() {
        sync()
        stopTicker()
        state = .ended
        deadline = nil
    }

    /// One-level undo for `advanceToNextPhase()` -- 工程审阅 §7: "完成一輪
    /// 支持撤銷誤觸". Deliberately scoped to MANUAL advances only (captured
    /// here, not inside `sync()`'s own natural-countdown/background-catch-up
    /// path) -- undoing a background catch-up jump wouldn't make sense, and
    /// a fat-fingered "完成本輪" tap is the actual failure mode this guards
    /// against. Only one level deep: confirming a second round clears the
    /// ability to undo the first.
    private var undoSnapshot: (index: Int, remainingInPhase: Int, elapsedBefore: Int, elapsedSeconds: Int, deadline: Date?)?

    public var canUndoLastAdvance: Bool { undoSnapshot != nil }

    /// Manually skip to the next phase (EMOM/interval: the coach confirms
    /// a station early, or the interval boundary needs a manual nudge) --
    /// forces the current phase's deadline to "now" and lets `sync()`'s own
    /// (carefully overshoot-correct) advance logic take it from there, so
    /// there is exactly one place phase-advance bookkeeping can be gotten
    /// right or wrong.
    public func advanceToNextPhase() {
        guard state == .running else { return }
        // Catch up on any real elapsed time FIRST -- without this, a caller
        // that hasn't ticked recently would have the undo snapshot capture
        // stale pre-tick values instead of the actually-current remaining
        // time (and, more importantly, `sync()` may have already naturally
        // advanced/ended the timer on its own by "now", in which case this
        // manual call has nothing left to force).
        sync()
        guard state == .running, currentPhaseIndex < phases.count else { return }
        undoSnapshot = (currentPhaseIndex, remainingSecondsInPhase, elapsedBeforeCurrentPhase, elapsedSeconds, deadline)
        deadline = now()
        sync()
    }

    /// Reverts the most recent `advanceToNextPhase()` call -- including
    /// un-ending the timer if that advance was the one that finished the
    /// last phase.
    public func undoLastAdvance() {
        guard let snapshot = undoSnapshot else { return }
        currentPhaseIndex = snapshot.index
        remainingSecondsInPhase = snapshot.remainingInPhase
        elapsedBeforeCurrentPhase = snapshot.elapsedBefore
        elapsedSeconds = snapshot.elapsedSeconds
        deadline = snapshot.deadline
        if state == .ended {
            state = .running
            startTicker()
        }
        undoSnapshot = nil
    }

    /// Re-derives `remainingSecondsInPhase`/`elapsedSeconds` from the wall-
    /// clock deadline -- call on every tick AND explicitly when the app
    /// returns to the foreground, so backgrounded time is never lost or
    /// double-counted (same discipline as `RestTimerModel.sync()`).
    public func sync() {
        guard state == .running else { return }
        if isCountUp {
            guard let countUpStartedAt else { return }
            elapsedSeconds = max(0, Int(now().timeIntervalSince(countUpStartedAt).rounded()))
            return
        }
        guard let deadline else { return }
        // A phased (non-count-up) timer constructed with zero phases has
        // nothing to run -- treat it as already ended rather than indexing
        // `phases[currentPhaseIndex]` below out of bounds. `forPrescription`
        // never produces this (EMOM/interval clamp their count to >= 1),
        // but this guard keeps direct `WODTimerModel(phases: [])`
        // construction safe too.
        guard !phases.isEmpty else {
            state = .ended
            self.deadline = nil
            stopTicker()
            return
        }
        // `remaining` stays SIGNED throughout the advance loop (never
        // clamped to 0 mid-loop) -- clamping the overshoot early would lose
        // how far past a LATER phase's own end the clock already is,
        // corrupting the accounting for whichever phase after that one
        // sync() still has to walk through. A single sync() can legitimately
        // need to advance through more than one finished phase (e.g. the
        // app was backgrounded through an entire short EMOM interval).
        // The deadline is only ever moved by whole phase lengths, never
        // re-anchored to `now + ceil(remaining)`: with the 200ms ticker that
        // re-anchor added the rounded-up fraction back every tick and froze
        // the countdown (see `testSubSecondTicksStillCountDown`).
        var phaseDeadline = deadline
        var remaining = Int(phaseDeadline.timeIntervalSince(now()).rounded(.up))
        while remaining <= 0, currentPhaseIndex < phases.count {
            let finishedIndex = currentPhaseIndex
            elapsedBeforeCurrentPhase += phases[finishedIndex].durationSeconds
            currentPhaseIndex += 1
            guard currentPhaseIndex < phases.count else {
                remainingSecondsInPhase = 0
                elapsedSeconds = elapsedBeforeCurrentPhase
                state = .ended
                self.deadline = nil
                stopTicker()
                onPhaseFinish?(finishedIndex)
                onAllPhasesFinished?()
                return
            }
            phaseDeadline = phaseDeadline.addingTimeInterval(TimeInterval(phases[currentPhaseIndex].durationSeconds))
            remaining = Int(phaseDeadline.timeIntervalSince(now()).rounded(.up))
            self.deadline = phaseDeadline // `onPhaseFinish` persists `makeAnchor()`
            onPhaseFinish?(finishedIndex)
        }
        remainingSecondsInPhase = max(0, remaining)
        self.deadline = phaseDeadline
        elapsedSeconds = elapsedBeforeCurrentPhase + (phases[currentPhaseIndex].durationSeconds - remainingSecondsInPhase)
    }

    // MARK: - Persistence (survive process death)

    public func makeAnchor() -> WODTimerAnchor? {
        guard state == .running else { return nil }
        if isCountUp {
            guard let countUpStartedAt else { return nil }
            return WODTimerAnchor(phaseIndex: 0, currentPhaseDeadline: countUpStartedAt, elapsedBeforeCurrentPhase: 0, isCountUp: true, countUpStartedAt: countUpStartedAt)
        }
        guard let deadline else { return nil }
        return WODTimerAnchor(phaseIndex: currentPhaseIndex, currentPhaseDeadline: deadline, elapsedBeforeCurrentPhase: elapsedBeforeCurrentPhase, isCountUp: false, countUpStartedAt: nil)
    }

    /// Rebuilds running state from a persisted anchor and immediately
    /// `sync()`s so any time elapsed while the process was dead is folded
    /// in (potentially advancing through/finishing phases right away).
    /// Always sets `resumedFromPersistedState = true` -- see that
    /// property's doc comment.
    public func restore(from anchor: WODTimerAnchor) {
        resumedFromPersistedState = true
        currentPhaseIndex = anchor.phaseIndex
        elapsedBeforeCurrentPhase = anchor.elapsedBeforeCurrentPhase
        if anchor.isCountUp {
            countUpStartedAt = anchor.countUpStartedAt
        } else {
            deadline = anchor.currentPhaseDeadline
            if currentPhaseIndex < phases.count {
                remainingSecondsInPhase = phases[currentPhaseIndex].durationSeconds
            }
        }
        state = .running
        sync()
        if state == .running { startTicker() }
    }

    public func acknowledgeResumedState() {
        resumedFromPersistedState = false
    }

    // MARK: - Ticker

    private func startTicker() {
        stopTicker()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self, !Task.isCancelled else { return }
                self.sync()
                if self.state != .running { return }
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }
}

extension WODTimerModel {
    /// Builds the right phase list (or count-up mode) for a prescription --
    /// the one place format→timer-shape mapping happens, so
    /// `WODBlockDraftCard`'s "開始計時" button never has to re-derive it.
    public static func forPrescription(_ prescription: WODPrescription, now: @escaping () -> Date = Date.init) -> WODTimerModel {
        switch prescription.format {
        case .amrap:
            let seconds = prescription.timeCapSeconds ?? 0
            return WODTimerModel(phases: [WODTimerPhase(label: L("AMRAP", "AMRAP"), durationSeconds: seconds)], now: now)
        case .forTime:
            if let cap = prescription.timeCapSeconds {
                return WODTimerModel(phases: [WODTimerPhase(label: L("計時完成", "For Time"), durationSeconds: cap)], now: now)
            }
            return WODTimerModel(countUp: now)
        case .emom:
            let interval = prescription.intervalSeconds ?? 60
            let count = max(1, prescription.intervalCount ?? 1)
            let phases = (0..<count).map { i in
                WODTimerPhase(label: L("第\(i + 1)個間隔", "Interval \(i + 1)"), durationSeconds: interval)
            }
            return WODTimerModel(phases: phases, now: now)
        case .interval:
            let work = prescription.intervalSeconds ?? 20
            let rest = prescription.restSeconds ?? 10
            let count = max(1, prescription.intervalCount ?? 1)
            var phases: [WODTimerPhase] = []
            for i in 0..<count {
                phases.append(WODTimerPhase(label: L("工作 \(i + 1)", "Work \(i + 1)"), durationSeconds: work, isWork: true))
                phases.append(WODTimerPhase(label: L("休息 \(i + 1)", "Rest \(i + 1)"), durationSeconds: rest, isWork: false))
            }
            return WODTimerModel(phases: phases, now: now)
        case .unknown:
            return WODTimerModel(countUp: now)
        }
    }
}
