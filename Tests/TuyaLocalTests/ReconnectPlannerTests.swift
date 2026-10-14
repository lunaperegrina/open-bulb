import XCTest
@testable import TuyaLocal

/// Regression tests for the reconnect policy that used to livelock the app:
/// every failed poll spawned a full-subnet sweep on the shared serial queue,
/// so sweeps piled up faster than they drained and the popover stayed stuck
/// in "conectando…" with the power button hidden.
final class ReconnectPlannerTests: XCTestCase {
    func testSingleBlipDoesNotSweep() {
        var p = ReconnectPlanner()
        XCTAssertFalse(p.opFailed(now: 100))
        XCTAssertEqual(p.totalScansAuthorized, 0, "one failed poll must not trigger a subnet sweep")
        XCTAssertTrue(p.isReconnecting)
    }

    func testTwoConsecutiveFailuresAuthorizeExactlyOneSweep() {
        var p = ReconnectPlanner()
        XCTAssertFalse(p.opFailed(now: 100))
        XCTAssertTrue(p.opFailed(now: 105), "second consecutive failure should sweep")
        // further failures inside the throttle window authorize nothing
        for t in [110, 115, 120, 130] {
            XCTAssertFalse(p.opFailed(now: Double(t)), "sweep throttled at t=\(t)")
        }
        XCTAssertEqual(p.totalScansAuthorized, 1)
    }

    func testSweepReauthorizesOnlyAfterThrottleWindow() {
        var p = ReconnectPlanner()
        _ = p.opFailed(now: 100)
        XCTAssertTrue(p.opFailed(now: 105))
        XCTAssertFalse(p.opFailed(now: 164), "59s after the sweep: still throttled")
        XCTAssertTrue(p.opFailed(now: 166), "61s after the sweep: new sweep allowed")
        XCTAssertEqual(p.totalScansAuthorized, 2)
    }

    func testSuccessResetsFailureStreakAndThrottle() {
        var p = ReconnectPlanner()
        _ = p.opFailed(now: 100)
        XCTAssertTrue(p.opFailed(now: 105))
        p.opSucceeded()
        XCTAssertFalse(p.isReconnecting)
        // a fresh failure streak needs two failures again before sweeping
        XCTAssertFalse(p.opFailed(now: 200))
        XCTAssertTrue(p.opFailed(now: 205))
    }

    func testBlipThenRecoveryThenBlipNeverSweeps() {
        var p = ReconnectPlanner()
        _ = p.opFailed(now: 100)
        p.opSucceeded()
        _ = p.opFailed(now: 130)
        p.opSucceeded()
        _ = p.opFailed(now: 160)
        p.opSucceeded()
        XCTAssertEqual(p.totalScansAuthorized, 0,
                       "isolated blips must self-heal via plain polls, no sweeps")
    }
}
