import Foundation

struct RetryPolicy {
    let maxAttempts: Int
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval

    static let standard = RetryPolicy(maxAttempts: 5, baseDelay: 1, maxDelay: 30)

    /// Exponential backoff. `attempt` is zero-based.
    func delay(forAttempt attempt: Int) -> TimeInterval {
        min(maxDelay, baseDelay * pow(2, Double(attempt)))
    }

    /// Rate limits and server faults are transient; client errors are not.
    static func isRetryable(statusCode: Int) -> Bool {
        statusCode == 429 || (500..<600).contains(statusCode)
    }

    /// Classifies errors thrown by the transport itself (before any HTTP
    /// status is known), e.g. a dropped connection or timeout. Only a
    /// curated set of `URLError` codes that self-heal on retry qualify;
    /// cancellation (both `CancellationError` and `URLError.cancelled`,
    /// which is how `URLSession` surfaces a cancelled task) must never be
    /// retried, since that would silently redo work the caller stopped.
    static func isRetryable(error: Error) -> Bool {
        guard !(error is CancellationError) else { return false }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .dataNotAllowed, .internationalRoamingOff, .callIsActive,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }
}
