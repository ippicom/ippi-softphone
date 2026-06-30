//
//  KeychainService.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import Foundation
import Security

/// Stored credentials structure
struct StoredCredentials: Codable, Sendable {
    let username: String
    let password: String
    let domain: String
}

/// Keychain service for secure credential storage
/// Using @MainActor to avoid concurrency issues
@MainActor
final class KeychainService {
    static let shared = KeychainService()
    
    private let credentialsKey = "ippi_sip_credentials"
    private let service = Constants.Keychain.service
    
    private init() {}
    
    // MARK: - Migration

    /// Re-save existing credentials to update keychain accessibility level.
    /// Required after changing from kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    /// to kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly for PushKit background access.
    func migrateAccessibilityIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "keychainAccessibilityMigrated") else { return }
        guard let credentials = try? getCredentials() else {
            // No credentials stored — nothing to migrate
            UserDefaults.standard.set(true, forKey: "keychainAccessibilityMigrated")
            return
        }
        do {
            try saveCredentials(credentials)
            UserDefaults.standard.set(true, forKey: "keychainAccessibilityMigrated")
            Log.general.success("Keychain accessibility migrated for background access")
        } catch {
            Log.general.failure("Keychain accessibility migration failed", error: error)
        }
    }

    // MARK: - Credentials (Complete Account)

    /// Save complete credentials (username + password + domain) securely
    func saveCredentials(_ credentials: StoredCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        
        // Delete existing item first
        try? deleteCredentials()
        
        // Use kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly:
        // - Accessible after first unlock (even when screen re-locks)
        // - Required for PushKit: app must read credentials in background to register SIP
        // - Not included in backups/migrations to other devices
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialsKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        
        guard status == errSecSuccess else {
            Log.general.failure("Failed to save credentials to keychain", error: KeychainError.unhandledError(status: status))
            throw KeychainError.unhandledError(status: status)
        }
        
        Log.general.success("Credentials saved to keychain")
    }
    
    /// Get stored credentials
    func getCredentials() throws -> StoredCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialsKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data else {
            throw KeychainError.itemNotFound
        }
        
        return try JSONDecoder().decode(StoredCredentials.self, from: data)
    }
    
    /// Delete stored credentials
    func deleteCredentials() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialsKey
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledError(status: status)
        }
        
        Log.general.success("Credentials deleted from keychain")
    }
    
    /// Check if credentials exist
    func hasCredentials() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialsKey,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
    
}

// MARK: - Keychain Errors

enum KeychainError: LocalizedError {
    case itemNotFound
    case unhandledError(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "Password not found in keychain"
        case .unhandledError(let status):
            return "Keychain error: \(status)"
        }
    }
}
