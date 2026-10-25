import Foundation
import Security

/// Storage for the rewrite agent's Anthropic API key.
public protocol SecretStore: Sendable {
    var source: String { get }
    func get() -> String?
    func set(_ value: String) throws
    func delete() throws
}

public struct SecretStoreError: Error, CustomStringConvertible, Sendable {
    public let description: String
}

/// macOS Keychain (generic password). The key never touches disk in plaintext.
public struct KeychainSecretStore: SecretStore {
    public let service: String
    public let account: String
    public var source: String { "keychain" }

    public init(service: String = "io.github.diorama.rewrite-agent", account: String = "anthropic-api-key") {
        self.service = service
        self.account = account
    }

    var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func get() -> String? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ value: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "Diorama rewrite agent API key"
            let s = SecItemAdd(add as CFDictionary, nil)
            guard s == errSecSuccess else { throw SecretStoreError(description: "Keychain add failed (\(s))") }
        } else if status != errSecSuccess {
            throw SecretStoreError(description: "Keychain update failed (\(status))")
        }
    }

    public func delete() throws {
        let s = SecItemDelete(baseQuery as CFDictionary)
        guard s == errSecSuccess || s == errSecItemNotFound else { throw SecretStoreError(description: "Keychain delete failed (\(s))") }
    }
}

/// Read-only key from `DIORAMA_ANTHROPIC_API_KEY` (CI and headless setups). Takes priority
/// over the Keychain when set, so it can be used without touching the user's keychain.
public struct EnvironmentSecretStore: SecretStore {
    public let variable: String
    let environment: [String: String]
    public var source: String { "environment (\(variable))" }

    public init(variable: String = "DIORAMA_ANTHROPIC_API_KEY", environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.variable = variable
        self.environment = environment
    }

    public func get() -> String? { environment[variable].flatMap { $0.isEmpty ? nil : $0 } }
    public func set(_ value: String) throws { throw SecretStoreError(description: "\(variable) is read-only") }
    public func delete() throws { throw SecretStoreError(description: "\(variable) is read-only") }
}

public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    public var source: String { "memory" }
    public init(_ value: String? = nil) { self.value = value }
    public func get() -> String? { lock.withLock { value } }
    public func set(_ v: String) throws { lock.withLock { value = v } }
    public func delete() throws { lock.withLock { value = nil } }
}

/// Environment first, then the writable store.
public struct LayeredSecretStore: SecretStore {
    public let override: SecretStore?
    public let primary: SecretStore

    public init(override: SecretStore?, primary: SecretStore) {
        self.override = override
        self.primary = primary
    }

    public var source: String { override?.get() != nil ? override!.source : primary.source }
    public func get() -> String? { override?.get() ?? primary.get() }
    public func set(_ value: String) throws { try primary.set(value) }
    public func delete() throws { try primary.delete() }

    public static func hint(for key: String?) -> String? {
        guard let key, key.count >= 8 else { return nil }
        return "…" + key.suffix(4)
    }
}
