import Foundation

/// Race an async operation against a wall-clock deadline.
///
/// Deliberately built on UNSTRUCTURED tasks. A `withThrowingTaskGroup` race
/// cannot rethrow the timeout until it has cancelled AND AWAITED its remaining
/// child — and a wedged Core ML inference ignores cooperative cancellation, so
/// a structured race blocks right past the deadline: exactly the hang this
/// guard exists to bound (the menu would stay pinned on "Transcribing…" and the
/// utterance would never settle). Here the loser is truly abandoned: a wedged
/// body keeps running detached (still occupying its engine actor, so later
/// utterances queue behind it), but the caller gets `TimeoutError` AT the
/// deadline and the UI recovers to .error → idle instead of spinning forever.
enum AsyncTimeout {
    struct TimeoutError: Error {}

    /// Run `body`, throwing `TimeoutError` if it hasn't finished after
    /// `seconds` — even when `body` never observes cooperative cancellation.
    static func run<T: Sendable>(
        seconds: TimeInterval,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            // First racer to claim the arbiter resumes the continuation; the
            // other's result is dropped. This is what guarantees exactly-once
            // resumption without awaiting the loser.
            let arbiter = Arbiter()
            let work = Task {
                let result: Result<T, Error>
                do { result = .success(try await body()) }
                catch { result = .failure(error) }
                if await arbiter.claim() {
                    continuation.resume(with: result)
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if await arbiter.claim() {
                    // Best-effort: aborts any cancellation-cooperative stretch
                    // of the body (e.g. a URLSession model download). A wedged
                    // Core ML call ignores this and is simply abandoned.
                    work.cancel()
                    continuation.resume(throwing: TimeoutError())
                }
            }
            // When `work` wins, the deadline task sleeps out its remaining
            // time, loses the claim, and exits — a dormant sleeper, not a leak.
        }
    }

    /// Exactly-once gate for the two racing tasks.
    private actor Arbiter {
        private var claimed = false
        func claim() -> Bool {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
