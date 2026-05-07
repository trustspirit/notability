import XCTest
@testable import MeetingScribe

final class KeychainHelperTests: XCTestCase {
    let testKey = "com.meetingscribe.test.apikey.\(UUID().uuidString)"

    override func tearDown() {
        KeychainHelper.delete(forKey: testKey)
        super.tearDown()
    }

    func test_save_and_load() {
        KeychainHelper.save("sk-test-key", forKey: testKey)
        XCTAssertEqual(KeychainHelper.load(forKey: testKey), "sk-test-key")
    }

    func test_overwrite() {
        KeychainHelper.save("old", forKey: testKey)
        KeychainHelper.save("new", forKey: testKey)
        XCTAssertEqual(KeychainHelper.load(forKey: testKey), "new")
    }

    func test_load_missing_returns_nil() {
        XCTAssertNil(KeychainHelper.load(forKey: testKey))
    }

    func test_delete() {
        KeychainHelper.save("value", forKey: testKey)
        KeychainHelper.delete(forKey: testKey)
        XCTAssertNil(KeychainHelper.load(forKey: testKey))
    }
}
