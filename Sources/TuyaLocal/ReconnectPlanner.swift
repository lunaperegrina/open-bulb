import Foundation

/// Pure decision core for the lamp reconnect loop: given op outcomes and a
/// clock, decides when a network sweep (rediscovery) is warranted. No timers,
/// no I/O — the app layer owns polling cadence and executes the plan, which
/// keeps the policy unit-testable.
///
/// Contract:
/// - a single blip (one failed op) never triggers a sweep — the next poll
///   almost always recovers a transient WiFi hiccup on its own;
/// - after two consecutive failures a sweep runs, but never more than one per
///   throttle window (sweeps take 10–25s on a real network and used to pile
///   up unboundedly, wedging the app in "reconnecting" forever);
/// - any success resets everything.
public struct ReconnectPlanner: Equatable {
    private(set) var consecutiveFailures: Int = 0
    /// Clock reading (seconds) of the last sweep this planner authorized.
    private(set) var lastScanAt: Double?
    private(set) var totalScansAuthorized: Int = 0

    public init() {}

    public mutating func reset() {
        consecutiveFailures = 0
        lastScanAt = nil
    }

    public mutating func opSucceeded() {
        reset()
    }

    /// Register a failed op. Returns true when a rediscovery sweep should
    /// start now.
    public mutating func opFailed(now: Double, scanThrottle: Double = 60) -> Bool {
        consecutiveFailures += 1
        guard consecutiveFailures >= 2 else { return false }
        if let last = lastScanAt, now - last < scanThrottle { return false }
        lastScanAt = now
        totalScansAuthorized += 1
        return true
    }

    /// A user explicitly asked for a retry: record the sweep time (so the
    /// auto-throttle doesn't stack another one right after), skipping the
    /// failure-streak check.
    public mutating func userScanRequested(now: Double) {
        lastScanAt = now
        totalScansAuthorized += 1
    }

    /// True while ops are failing but the lamp may come back on its own —
    /// the UI shows "reconectando…" rather than declaring offline.
    public var isReconnecting: Bool { consecutiveFailures > 0 }
}
