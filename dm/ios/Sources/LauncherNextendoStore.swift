import Foundation

@_silgen_name("dm_mobile_nextendo_copy_legacy") private func copyLegacyNextendo(_ buffer: UnsafeMutablePointer<UInt8>, _ capacity: Int, _ size: UnsafeMutablePointer<Int>) -> Int32
@_silgen_name("dm_mobile_nextendo_remove_legacy") private func removeLegacyNextendo(_ expected: UnsafePointer<UInt8>?, _ size: Int) -> Int32

protocol MobileNextendoLegacyReading: Sendable {
    func load() -> Data?
    func remove(matching expected: Data?) -> Bool
}
struct MobileNextendoNativeLegacy: MobileNextendoLegacyReading {
    func load() -> Data? {
        var bytes = [UInt8](repeating: 0, count: 65_536), size = 0
        let capacity = bytes.count
        guard copyLegacyNextendo(&bytes, capacity, &size) == 1, (1...bytes.count).contains(size) else { return nil }
        return Data(bytes.prefix(size))
    }
    func remove(matching expected: Data?) -> Bool {
        if let expected { return expected.withUnsafeBytes { removeLegacyNextendo($0.baseAddress?.assumingMemoryBound(to: UInt8.self), expected.count) == 1 } }
        return removeLegacyNextendo(nil, 0) == 1
    }
}

/// Keychain wins even when it contains scoped OAuth rather than NEX. Legacy JSON
/// is only a validated migration source; no second credential authority remains.
struct MobileNextendoCredentialStore: NextendoCredentialStore, @unchecked Sendable {
    private let keychain: any NextendoCredentialStore
    private let legacy: any MobileNextendoLegacyReading
    private let preferences: UserDefaults
    private let disabledKey = "launcher.nextendoLegacyMigrationDisabled"
    init(keychain: any NextendoCredentialStore = NextendoKeychainStore(),
         legacy: any MobileNextendoLegacyReading = MobileNextendoNativeLegacy(), preferences: UserDefaults = .standard) {
        self.keychain = keychain; self.legacy = legacy; self.preferences = preferences
    }
    func load() throws -> NextendoSession? {
        if let current = try keychain.load() { return current }
        guard !preferences.bool(forKey: disabledKey), let data = legacy.load() else { return nil }
        let session = try NextendoSession.decodeStored(data)
        guard session.tokenKind == .nex else { return nil }
        try keychain.save(session)
        guard try keychain.load() == session else { throw NextendoError.invalidResponse }
        // A changed legacy file is retained. Keychain is still the sole authority.
        if legacy.remove(matching: data) { preferences.set(true, forKey: disabledKey) }
        return session
    }
    func save(_ session: NextendoSession) throws { try keychain.save(session) }
    func remove() throws {
        // Even if removal fails, a later account load must not resurrect JSON.
        preferences.set(true, forKey: disabledKey)
        try keychain.remove()
        guard legacy.remove(matching: nil) else { throw NextendoError.requestFailed }
    }
}
