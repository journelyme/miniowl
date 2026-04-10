import CoreGraphics
import Foundation

/// Tracks whether the user is "away from keyboard" — idle for longer
/// than a threshold — by polling the system's integer count of seconds
/// since the last input event.
///
/// **Privacy:** this watcher reads **one number** and nothing else.
/// `CGEventSource.secondsSinceLastEventType` returns a single Double
/// (seconds since the most recent keyboard or mouse event). It does not
/// expose *which* key was pressed, *where* the mouse moved, or anything
/// else. See `Sources/miniowl/Privacy/ForbiddenImports.swift` for the
/// list of input-interception APIs miniowl is mechanically forbidden
/// from using.
///
/// State machine:
///   - `active` → `afk`  when idle ≥ 180s. The AFK interval is
///     *back-dated* to `now - 180_000` ms because the user actually
///     went away 3 minutes ago, not the moment we noticed.
///   - `afk` → `active`  when idle < 5s (i.e. there's fresh input).
///
/// Known quirk: watching a video with no cursor motion will look like
/// AFK. That's the honest signal — "no input at the keyboard" — and
/// we document rather than try to fix it.
final class AFKWatcher {
    private let coordinator: EventCoordinator
    private let queue = DispatchQueue(label: "miniowl.watcher.afk")
    private var timer: DispatchSourceTimer?

    /// Once idle for this long, the user is considered AFK.
    static let afkThresholdSeconds: Double = 180

    /// How often we poll `CGEventSource` for the idle count.
    static let pollInterval: DispatchTimeInterval = .seconds(5)

    /// Cached "any input event" sentinel. `~0` is the documented value
    /// of `kCGAnyInputEventType` and means "return idle time regardless
    /// of which event type".
    private let anyInputEvent = CGEventType(rawValue: ~0)!

    /// Current state — mutated only from `queue`.
    private var isAFK = false

    init(coordinator: EventCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(
            deadline: .now() + .seconds(2),
            repeating: Self.pollInterval
        )
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        self.timer = t
    }

    // MARK: - Sampling

    private func sample() {
        let idle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: anyInputEvent
        )
        let nowTs = nowMs()

        if !isAFK && idle >= Self.afkThresholdSeconds {
            // Transition active → afk. Back-date the start to when
            // the idle period actually began.
            let startTs = nowTs - Int64(Self.afkThresholdSeconds * 1000)
            isAFK = true
            let kind = EventKind.afk(away: true)
            Task { await coordinator.observe(kind, at: startTs) }
            // Immediately extend to now so the pending interval has
            // a non-zero duration on first disk write.
            Task { await coordinator.observe(kind, at: nowTs) }
        } else if isAFK && idle < 5 {
            // Transition afk → active. The pending AFK event closes
            // at (now - idle*1000) — that's when input actually resumed.
            let endTs = nowTs - Int64(idle * 1000)
            isAFK = false
            // Close the AFK interval by emitting an "active" observation
            // at endTs; the coordinator's merge rules will close the
            // previous AFK pending and open a new "active" one (which
            // we never persist because `afk(away:false)` is skipped by
            // writeClosedEvent).
            let kind = EventKind.afk(away: false)
            Task { await coordinator.observe(kind, at: endTs) }
        } else if isAFK {
            // Still AFK — extend the pending end_ts so state.json
            // heartbeat can reflect the current duration.
            let kind = EventKind.afk(away: true)
            Task { await coordinator.observe(kind, at: nowTs) }
        }
        // (active + not-yet-afk → do nothing; keeps disk quiet)
    }

    deinit {
        timer?.cancel()
    }
}
