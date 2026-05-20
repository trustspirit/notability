import XCTest
@testable import Notability

final class CredentialsStoreTests: XCTestCase {
    let testKey = "com.notability.test.apikey.\(UUID().uuidString)"

    override func tearDown() {
        CredentialsStore.delete(forKey: testKey)
        super.tearDown()
    }

    func test_save_and_load() {
        CredentialsStore.save("sk-test-key", forKey: testKey)
        XCTAssertEqual(CredentialsStore.load(forKey: testKey), "sk-test-key")
    }

    func test_overwrite() {
        CredentialsStore.save("old", forKey: testKey)
        CredentialsStore.save("new", forKey: testKey)
        XCTAssertEqual(CredentialsStore.load(forKey: testKey), "new")
    }

    func test_load_missing_returns_nil() {
        XCTAssertNil(CredentialsStore.load(forKey: testKey))
    }

    func test_delete() {
        CredentialsStore.save("value", forKey: testKey)
        CredentialsStore.delete(forKey: testKey)
        XCTAssertNil(CredentialsStore.load(forKey: testKey))
    }
}
