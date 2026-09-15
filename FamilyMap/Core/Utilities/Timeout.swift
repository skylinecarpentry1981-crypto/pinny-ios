import Foundation

/// Runs `operation` and fails with `timeoutError` if it has not finished after `nanoseconds`.
/// The operation is not cancelled (a Firestore write can't be); a late result is ignored.
/// Same pattern as `LocationSync.write`, for callers outside it.
@MainActor
func withTimeout(
    nanoseconds: UInt64,
    timeoutError: Error,
    operation: @escaping @MainActor () async throws -> Void
) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let gate = TimeoutGate(continuation)
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            gate.resume(with: .failure(timeoutError))
        }
        Task { @MainActor in
            do {
                try await operation()
                gate.resume(with: .success(()))
            } catch {
                gate.resume(with: .failure(error))
            }
            timeoutTask.cancel()
        }
    }
}

/// Resumes the continuation at most once. Only touched from main-actor tasks, so the callers never race.
private final class TimeoutGate {
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Void, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
