import XCTest
@testable import LocalDictation

final class AsyncTimeoutTests: XCTestCase {

    func testBodyFinishingFirstReturnsItsValue() async throws {
        let value = try await AsyncTimeout.run(seconds: 5) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testBodyErrorPropagatesUnwrapped() async {
        struct BodyError: Error {}
        do {
            _ = try await AsyncTimeout.run(seconds: 5) { () -> Int in throw BodyError() }
            XCTFail("expected BodyError")
        } catch {
            XCTAssertTrue(error is BodyError)
            XCTAssertFalse(error is AsyncTimeout.TimeoutError)
        }
    }

    func testTimeoutFiresOnCooperativeSleeper() async {
        do {
            _ = try await AsyncTimeout.run(seconds: 0.05) { () -> Int in
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return 0
            }
            XCTFail("expected TimeoutError")
        } catch {
            XCTAssertTrue(error is AsyncTimeout.TimeoutError)
        }
    }

    /// The regression AsyncTimeout exists for: the deadline must fire ON TIME
    /// even when the body ignores cooperative cancellation (a wedged Core ML
    /// inference). A withThrowingTaskGroup-based race cannot rethrow until it
    /// has awaited the abandoned child, so against that implementation this
    /// body would hold the timeout hostage for its full ~3 s and the elapsed
    /// bound below would fail.
    func testTimeoutFiresEvenWhenBodyIgnoresCancellation() async {
        let start = Date()
        do {
            _ = try await AsyncTimeout.run(seconds: 0.1) { () -> Int in
                // Busy-wait that never observes Task.isCancelled: it yields so
                // the cooperative pool isn't starved, but refuses to stop.
                let deadline = Date().addingTimeInterval(3)
                while Date() < deadline { await Task.yield() }
                return 0
            }
            XCTFail("expected TimeoutError")
        } catch {
            XCTAssertTrue(error is AsyncTimeout.TimeoutError)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.5,
            "timeout did not fire at the deadline — the race is blocking on the abandoned body")
    }
}
