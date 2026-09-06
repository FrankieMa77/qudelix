import Foundation
import Security

protocol KeychainStore: Sendable {
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], with attributes: [String: Any]) -> OSStatus
    func copy(_ query: [String: Any]) -> (status: OSStatus, data: Data?)
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SecItemStore: KeychainStore {
    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(_ query: [String: Any], with attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func copy(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item as? Data)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

struct AIKeychain {
    enum Reading: Equatable {
        case key(String)
        case none
        case denied
    }

    static let service = "com.qudelixbar.app.ai"

    static let shared = AIKeychain()

    let store: KeychainStore

    init(store: KeychainStore = SecItemStore()) { self.store = store }

    static func query(provider: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: provider]
    }

    @discardableResult
    func save(key: String, provider: String) -> Bool {
        let clean = Self.printable(key)
        let data = Data(clean.utf8)
        guard !data.isEmpty else { return false }
        var attributes = Self.query(provider: provider)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let status = store.add(attributes)
        if status == errSecSuccess { return true }
        guard status == errSecDuplicateItem else { return false }
        return store.update(Self.query(provider: provider),
                            with: [kSecValueData as String: data]) == errSecSuccess
    }

    func load(provider: String) -> Reading {
        var q = Self.query(provider: provider)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne

        let (status, item) = store.copy(q)
        switch status {
        case errSecSuccess:
            break
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            return .denied
        default:
            return .none
        }
        guard let item, let text = String(data: item, encoding: .utf8) else { return .none }
        let clean = Self.printable(text)
        return clean.isEmpty ? .none : .key(clean)
    }

    @discardableResult
    func delete(provider: String) -> Bool {
        let status = store.delete(Self.query(provider: provider))
        return status == errSecSuccess || status == errSecItemNotFound
    }

    func hasKey(provider: String) -> Bool {
        var q = Self.query(provider: provider)
        q[kSecReturnData as String] = false
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        return store.copy(q).status == errSecSuccess
    }
}
