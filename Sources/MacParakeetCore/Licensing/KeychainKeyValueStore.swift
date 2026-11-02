import Foundation
import Security

public final class KeychainKeyValueStore: KeyValueStore {
    private let service: String
    private let allowUserInteraction: Bool
    // The file-based Keychain UI switch is process-wide. Serialize our calls so
    // one store cannot restore it while another store is accessing credentials.
    private static let interactionLock = NSLock()

    static func withoutUserInteraction<T>(_ operation: () throws -> T) throws -> T {
        try withUserInteractionAllowed(false, operation)
    }

    private static func withUserInteractionAllowed<T>(_ allowed: Bool, _ operation: () throws -> T) throws -> T {
        try interactionLock.withLock {
            var previouslyAllowed = DarwinBoolean(false)
            let readStatus = SecKeychainGetUserInteractionAllowed(&previouslyAllowed)
            guard readStatus == errSecSuccess else { throw KeychainError(status: readStatus) }
            let status = SecKeychainSetUserInteractionAllowed(allowed)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
            defer { SecKeychainSetUserInteractionAllowed(previouslyAllowed.boolValue) }
            return try operation()
        }
    }

    /// Interactive access is opt-in for an explicit user action. The same lock
    /// protects both policies because this legacy Keychain switch is process-wide.
    public init(service: String, allowUserInteraction: Bool = false) {
        self.service = service
        self.allowUserInteraction = allowUserInteraction
    }

    private func withConfiguredUserInteraction<T>(_ operation: () throws -> T) throws -> T {
        try Self.withUserInteractionAllowed(allowUserInteraction, operation)
    }

    public func getString(_ key: String) throws -> String? {
        try withConfiguredUserInteraction {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecReturnData as String: true,
                    // kSecUseDataProtectionKeychain requires entitlements not available in SPM dev builds
            ]

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw KeychainError(status: status) }
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    public func setString(_ value: String, forKey key: String) throws {
        try withConfiguredUserInteraction {
            let data = Data(value.utf8)
            let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                // kSecUseDataProtectionKeychain requires entitlements not available in SPM dev builds
                kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            ]

            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: accessibility,
            ]

            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var add = query
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = accessibility
                let addStatus = SecItemAdd(add as CFDictionary, nil)
                guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
                return
            }
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        }
    }

    public func delete(_ key: String) throws {
        try withConfiguredUserInteraction {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                    // kSecUseDataProtectionKeychain requires entitlements not available in SPM dev builds
            ]
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        }
    }
}

public struct KeychainError: Error, LocalizedError {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var errorDescription: String? {
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled {
            return "Saved credential access is blocked. Allow MacParakeet access in Keychain Access, then retry."
        }
        if let msg = SecCopyErrorMessageString(status, nil) as String? {
            return "Keychain error: \(msg) (\(status))"
        }
        return "Keychain error: \(status)"
    }
}
