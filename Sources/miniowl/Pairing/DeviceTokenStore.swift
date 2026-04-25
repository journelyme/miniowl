import Foundation
import Security

/// Keychain-based storage for device tokens from the pairing flow.
///
/// Replaces the Phase 2a token.txt file approach with proper macOS Keychain
/// integration. Tokens are stored with:
/// - Service: com.contextly.miniowl
/// - Account: device_token
/// - Accessibility: AfterFirstUnlockThisDeviceOnly (no iCloud sync, requires unlock)
struct DeviceTokenStore {

    private static let service = "com.contextly.miniowl"
    private static let account = "device_token"

    enum KeychainError: Error, LocalizedError {
        case unhandledError(status: OSStatus)
        case itemNotFound
        case duplicateItem
        case dataConversionError

        var errorDescription: String? {
            switch self {
            case .unhandledError(let status):
                return "Keychain error: \(status)"
            case .itemNotFound:
                return "Token not found in keychain"
            case .duplicateItem:
                return "Token already exists in keychain"
            case .dataConversionError:
                return "Failed to convert token data"
            }
        }
    }

    /// Save a device token to the macOS Keychain.
    /// If a token already exists, it will be updated.
    func save(token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw KeychainError.dataConversionError
        }

        // First, try to update an existing item
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]

        let updateAttributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecSuccess {
            return // Successfully updated existing item
        }

        if updateStatus != errSecItemNotFound {
            throw KeychainError.unhandledError(status: updateStatus)
        }

        // Item doesn't exist, create a new one
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

        guard addStatus == errSecSuccess else {
            throw KeychainError.unhandledError(status: addStatus)
        }
    }

    /// Read the device token from the macOS Keychain.
    /// Returns nil if no token is stored.
    func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            return nil
        }

        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }

        return token
    }

    /// Delete the device token from the macOS Keychain.
    /// Used for sign out functionality.
    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledError(status: status)
        }
    }
}