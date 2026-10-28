import Foundation
import Security

public protocol CredentialStore: Sendable {
    func load(service: String, account: String) -> String?
    func save(secret: String, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

public struct CredentialStoreError: LocalizedError, Equatable {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(self.status, nil) as String?
        return message ?? "Keychain error \(self.status)"
    }
}

public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    public static let shared = KeychainCredentialStore()

    public init() {}

    public func load(service: String, account: String) -> String? {
        var query = self.baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(secret: String, service: String, account: String) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CredentialStoreError(status: errSecParam)
        }
        let data = Data(trimmed.utf8)

        let query = self.baseQuery(service: service, account: account)
        var status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw CredentialStoreError(status: status)
        }
    }

    public func delete(service: String, account: String) throws {
        let query = self.baseQuery(service: service, account: account)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError(status: status)
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: String] = [:]

    public init() {}

    private func key(service: String, account: String) -> String {
        "\(service)/\(account)"
    }

    public func load(service: String, account: String) -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.store[self.key(service: service, account: account)]
    }

    public func save(secret: String, service: String, account: String) throws {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.store[self.key(service: service, account: account)] = secret
    }

    public func delete(service: String, account: String) throws {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.store.removeValue(forKey: self.key(service: service, account: account))
    }
}
