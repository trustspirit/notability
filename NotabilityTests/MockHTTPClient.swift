import Foundation
@testable import Notability

final class MockHTTPClient: HTTPClient {
    struct Stub {
        let data: Data
        let statusCode: Int
        let error: Error?

        init(data: Data, statusCode: Int) {
            self.data = data
            self.statusCode = statusCode
            self.error = nil
        }

        /// A stub that makes `data(for:)` throw instead of returning a response,
        /// for simulating transport-level failures (dropped connection, cancellation).
        init(error: Error) {
            self.data = Data()
            self.statusCode = 0
            self.error = error
        }
    }

    private var stubs: [Stub]
    private let repeatLast: Bool
    private(set) var requests: [URLRequest] = []

    /// Single fixed response, repeated for every request.
    convenience init(responseData: Data, statusCode: Int) {
        self.init(stubs: [Stub(data: responseData, statusCode: statusCode)], repeatLast: true)
    }

    /// Consumes one stub per request, in order.
    init(stubs: [Stub], repeatLast: Bool = false) {
        self.stubs = stubs
        self.repeatLast = repeatLast
    }

    var requestCount: Int { requests.count }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let stub: Stub
        if stubs.count > 1 || !repeatLast {
            stub = stubs.isEmpty ? Stub(data: Data(), statusCode: 500) : stubs.removeFirst()
        } else {
            stub = stubs[0]
        }
        if let error = stub.error {
            throw error
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (stub.data, response)
    }
}
