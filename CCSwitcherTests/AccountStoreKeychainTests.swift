import Security
import XCTest

/// `AccountStore` against a temporary keychain.
final class AccountStoreKeychainTests: XCTestCase {
    private var keychain: TempKeychain!
    private var store: AccountStore!

    override func setUpWithError() throws {
        keychain = try TempKeychain()
        store = AccountStore(service: "com.adarshchbs.ccswitcher.tests", keychain: try keychain.open())
    }

    override func tearDownWithError() throws {
        try keychain.delete()
    }

    func testWriteAddsThenUpdates() throws {
        try store.write(id: "a", data: Data("one".utf8))
        XCTAssertEqual(try store.read(id: "a"), Data("one".utf8))
        let dump = try SecurityTool().run(["dump-keychain", keychain.path], stdin: nil)
        XCTAssertTrue(String(decoding: dump.stdout, as: UTF8.self).contains("com.adarshchbs.ccswitcher.tests"))
        try store.write(id: "a", data: Data("two".utf8))
        XCTAssertEqual(try store.read(id: "a"), Data("two".utf8))
    }

    func testItemsAreSeparatePerAccount() throws {
        try store.write(id: "a", data: Data("A".utf8))
        try store.write(id: "b", data: Data("B".utf8))
        XCTAssertEqual(try store.read(id: "a"), Data("A".utf8))
        XCTAssertEqual(try store.read(id: "b"), Data("B".utf8))
    }

    func testDeleteRemovesTheItem() throws {
        try store.write(id: "a", data: Data("A".utf8))
        try store.delete(id: "a")
        XCTAssertThrowsError(try store.read(id: "a")) { XCTAssertEqual($0 as? AccountStore.Failure, .notFound) }
        XCTAssertThrowsError(try store.delete(id: "a")) { XCTAssertEqual($0 as? AccountStore.Failure, .notFound) }
    }

    func testItemIsNotSynchronizable() throws {
        try store.write(id: "a", data: Data("A".utf8))
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.adarshchbs.ccswitcher.tests",
            kSecAttrAccount as String: "a",
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchSearchList as String: [try keychain.open()],
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertNotEqual(attributes[kSecAttrSynchronizable as String] as? Bool, true)
    }
}
