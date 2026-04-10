import Foundation

/// The kinds of events miniowl records.
///
/// Window and AFK events are *interval* events: they have a start and an
/// end, and consecutive identical observations get merged in memory so
/// the on-disk log stores one row per continuous state, not one row per
/// sample. System events are point-in-time — never merged.
enum EventKind: Equatable {
    case window(bundleID: String, appName: String, title: String?, url: String?)
    case afk(away: Bool)
}

/// An in-memory event that has opened but not yet closed. The
/// EventCoordinator holds at most one of these at a time per stream.
struct PendingEvent {
    var kind: EventKind
    let startMs: Int64
    var endMs: Int64

    /// Can the pending event absorb a new observation without closing?
    /// True iff the new observation describes the same state.
    func canExtend(with other: EventKind) -> Bool {
        return kind == other
    }
}

/// Unix milliseconds since epoch (UTC). Used for all on-disk timestamps.
///
/// Note: wall-clock, so susceptible to NTP adjustments. Duration math
/// inside a single pending event should stay close to reality because
/// the interval is short (seconds to minutes). For long-running durations
/// we'd reach for `DispatchTime.now()`; Phase 1 doesn't need that.
@inline(__always)
func nowMs() -> Int64 {
    return Int64(Date().timeIntervalSince1970 * 1000)
}
