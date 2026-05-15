import XCTest
@testable import OpenOatsKit

/// `FileSecretStore` reads/writes the singleton file at
/// `~/Library/Application Support/OpenOats/secrets.json`. These tests use a
/// throwaway key prefix and clean up after themselves so they don't pollute the
/// real on-disk store.
final class FileSecretStoreTests: XCTestCase {

    private let keyPrefix = "FileSecretStoreTests."

    private var keys: [String] = []

    override func tearDown() {
        for key in keys {
            FileSecretStore.delete(key: key)
        }
        keys.removeAll()
        super.tearDown()
    }

    private func newKey(_ suffix: String = UUID().uuidString) -> String {
        let key = "\(keyPrefix)\(suffix)"
        keys.append(key)
        return key
    }

    func testSaveAndLoadRoundTrip() {
        let key = newKey()
        FileSecretStore.save(key: key, value: "secret-value-xyz")
        XCTAssertEqual(FileSecretStore.load(key: key), "secret-value-xyz")
    }

    func testOverwriteReplacesPreviousValue() {
        let key = newKey()
        FileSecretStore.save(key: key, value: "first")
        FileSecretStore.save(key: key, value: "second")
        XCTAssertEqual(FileSecretStore.load(key: key), "second")
    }

    func testDeleteRemovesValue() {
        let key = newKey()
        FileSecretStore.save(key: key, value: "v")
        FileSecretStore.delete(key: key)
        XCTAssertNil(FileSecretStore.load(key: key))
    }

    func testLoadReturnsNilForMissingKey() {
        XCTAssertNil(FileSecretStore.load(key: newKey()))
    }

    func testMultipleKeysAreIsolated() {
        let a = newKey("a")
        let b = newKey("b")
        FileSecretStore.save(key: a, value: "alpha")
        FileSecretStore.save(key: b, value: "beta")
        XCTAssertEqual(FileSecretStore.load(key: a), "alpha")
        XCTAssertEqual(FileSecretStore.load(key: b), "beta")
    }

    func testFileHasOwnerOnlyPermissions() throws {
        let key = newKey()
        FileSecretStore.save(key: key, value: "v")
        let path = FileSecretStore.fileURL.path
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perms = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.int16Value, 0o600, "secrets.json must be owner-only")
    }
}
