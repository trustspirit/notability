import XCTest
@testable import Notability

final class RetryPolicyTests: XCTestCase {
    func test_standard_policy_doubles_delay_per_attempt() {
        let policy = RetryPolicy.standard
        XCTAssertEqual(policy.delay(forAttempt: 0), 1, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(forAttempt: 1), 2, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(forAttempt: 2), 4, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(forAttempt: 3), 8, accuracy: 1e-9)
    }

    func test_delay_is_capped_at_max() {
        let policy = RetryPolicy(maxAttempts: 10, baseDelay: 1, maxDelay: 30)
        XCTAssertEqual(policy.delay(forAttempt: 9), 30, accuracy: 1e-9)
    }

    func test_rate_limit_and_server_errors_are_retryable() {
        XCTAssertTrue(RetryPolicy.isRetryable(statusCode: 429))
        XCTAssertTrue(RetryPolicy.isRetryable(statusCode: 500))
        XCTAssertTrue(RetryPolicy.isRetryable(statusCode: 503))
    }

    func test_client_errors_are_not_retryable() {
        XCTAssertFalse(RetryPolicy.isRetryable(statusCode: 400))
        XCTAssertFalse(RetryPolicy.isRetryable(statusCode: 401))
        XCTAssertFalse(RetryPolicy.isRetryable(statusCode: 404))
    }

    // MARK: - Thrown-error classification (judgement call: transient network
    // failures should be retried just like 429/5xx, since this request only
    // happens once per meeting and a dropped connection is not the user's fault).

    func test_transient_url_errors_are_retryable() {
        XCTAssertTrue(RetryPolicy.isRetryable(error: URLError(.networkConnectionLost)))
        XCTAssertTrue(RetryPolicy.isRetryable(error: URLError(.timedOut)))
        XCTAssertTrue(RetryPolicy.isRetryable(error: URLError(.notConnectedToInternet)))
        XCTAssertTrue(RetryPolicy.isRetryable(error: URLError(.cannotConnectToHost)))
        XCTAssertTrue(RetryPolicy.isRetryable(error: URLError(.dnsLookupFailed)))
        XCTAssertTrue(RetryPolicy.isRetryable(error: URLError(.dataNotAllowed)))
    }

    func test_tls_handshake_failure_is_not_retryable() {
        // A failed handshake is as likely to be a misconfigured proxy or an
        // intercepted connection as a flaky one, and retrying only delays
        // showing the user something they have to act on.
        XCTAssertFalse(RetryPolicy.isRetryable(error: URLError(.secureConnectionFailed)))
    }

    func test_url_error_cancelled_is_not_retryable() {
        // .cancelled means the request was deliberately stopped (e.g. user
        // action or a cancelled parent Task) — retrying would fight the caller.
        XCTAssertFalse(RetryPolicy.isRetryable(error: URLError(.cancelled)))
    }

    func test_swift_cancellation_error_is_not_retryable() {
        XCTAssertFalse(RetryPolicy.isRetryable(error: CancellationError()))
    }

    func test_non_network_url_errors_are_not_retryable() {
        // A malformed request (bad URL, unsupported scheme) will fail the
        // same way on every attempt, so retrying just burns time.
        XCTAssertFalse(RetryPolicy.isRetryable(error: URLError(.badURL)))
        XCTAssertFalse(RetryPolicy.isRetryable(error: URLError(.unsupportedURL)))
    }

    func test_unrecognized_errors_are_not_retryable() {
        struct SomeOtherError: Error {}
        XCTAssertFalse(RetryPolicy.isRetryable(error: SomeOtherError()))
    }
}
