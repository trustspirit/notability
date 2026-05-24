import XCTest
@testable import Notability

final class CredentialStoreSandbox {
    let directory: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotabilityTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        CredentialsStore.directoryOverride = directory
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        CredentialsStore.directoryOverride = nil
    }
}

final class CredentialsStoreTests: XCTestCase {
    let testKey = "com.notability.test.apikey.\(UUID().uuidString)"
    private var sandbox: CredentialStoreSandbox!

    override func setUp() {
        super.setUp()
        sandbox = CredentialStoreSandbox()
    }

    override func tearDown() {
        CredentialsStore.delete(forKey: testKey)
        sandbox.tearDown()
        sandbox = nil
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
