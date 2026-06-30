//
//  SettingsViewModel.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import Foundation

@MainActor
@Observable
final class SettingsViewModel {
    // MARK: - Properties
    
    var showLogoutConfirmation: Bool = false
    var showClearHistoryConfirmation: Bool = false
    var showChangePassword: Bool = false
    var newPassword: String = ""
    var isChangingPassword: Bool = false
    var passwordChangeError: String?
    
    private let environment: AppEnvironment

    init() {
        self.environment = .shared
    }

    init(environment: AppEnvironment) {
        self.environment = environment
    }
    
    // MARK: - Computed Properties
    
    var currentAccount: Account? {
        environment.currentAccount
    }
    
    var accountUsername: String {
        currentAccount?.username ?? String(localized: "account.notloggedin")
    }
    
    var registrationState: SIPRegistrationState {
        currentAccount?.registrationState ?? .none
    }
    
    var isRegistered: Bool {
        registrationState == .registered
    }
    
    var canConnect: Bool {
        registrationState == .none || registrationState == .cleared || registrationState == .failed
    }
    
    var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
    
    // MARK: - Actions
    
    func logout() async {
        await environment.logout()
    }
    
    func clearCallHistory() async {
        await environment.callHistoryService.clearAll()
    }
    
    func toggleConnection() async {
        do {
            try environment.toggleConnection()
        } catch {
            Log.general.failure("Failed to reconnect", error: error)
        }
    }
    
    // MARK: - Password Change
    
    func changePassword() async {
        guard !newPassword.isEmpty else {
            passwordChangeError = String(localized: "settings.password.error.empty")
            return
        }

        isChangingPassword = true
        passwordChangeError = nil

        do {
            // Get current credentials
            let credentials = try KeychainService.shared.getCredentials()

            // Always unregister first if connected (to cleanly disconnect)
            if isRegistered {
                await environment.sipManager.unregisterAndWait()
            }

            // Register with new password — DON'T save to Keychain yet
            try environment.sipManager.register(
                username: credentials.username,
                password: newPassword,
                domain: Constants.SIP.effectiveDomain
            )

            // Wait for SIP registration to confirm the new password works
            var confirmed = false
            for _ in 0..<150 { // 200ms × 150 = 30s max
                let state = environment.currentAccount?.registrationState
                if state == .registered {
                    confirmed = true
                    break
                }
                if state == .failed {
                    break
                }
                try await Task.sleep(for: .milliseconds(200))
            }

            guard confirmed else {
                // Re-register with old password to restore connection
                try? environment.sipManager.register(
                    username: credentials.username,
                    password: credentials.password,
                    domain: Constants.SIP.effectiveDomain
                )
                passwordChangeError = String(localized: "settings.password.error.rejected")
                isChangingPassword = false
                return
            }

            // SIP confirmed — now safe to persist to Keychain
            let newCredentials = StoredCredentials(
                username: credentials.username,
                password: newPassword,
                domain: Constants.SIP.effectiveDomain
            )
            do {
                try KeychainService.shared.saveCredentials(newCredentials)
            } catch {
                // SIP accepted the password but Keychain write failed.
                // Re-register with old password to stay consistent with stored credentials.
                Log.general.failure("Keychain write failed after SIP password change — rolling back", error: error)
                await environment.sipManager.unregisterAndWait()
                try? environment.sipManager.register(
                    username: credentials.username,
                    password: credentials.password,
                    domain: Constants.SIP.effectiveDomain
                )
                passwordChangeError = String(localized: "settings.password.error.save")
                isChangingPassword = false
                return
            }

            // Clear and close
            newPassword = ""
            showChangePassword = false

            Log.general.success("Password changed successfully")
        } catch {
            Log.general.failure("Failed to change password", error: error)
            passwordChangeError = error.localizedDescription
        }

        isChangingPassword = false
    }
    
    func cancelPasswordChange() {
        newPassword = ""
        passwordChangeError = nil
        showChangePassword = false
    }
    
    // MARK: - SRTP Settings

    var isSRTPEnabled: Bool {
        UserDefaults.standard.bool(forKey: Constants.UserDefaultsKeys.srtpEnabled)
    }

    var isTogglingEncryption: Bool = false

    func toggleEncryptedCalls(_ enabled: Bool) async {
        isTogglingEncryption = true
        defer { isTogglingEncryption = false }

        let previousValue = isSRTPEnabled

        UserDefaults.standard.set(enabled, forKey: Constants.UserDefaultsKeys.srtpEnabled)
        environment.sipManager.updateMediaEncryption(enabled)

        // If registered, cycle UNREGISTER → RE-REGISTER with new domain
        guard environment.sipManager.registrationState == .registered else { return }

        do {
            let credentials = try KeychainService.shared.getCredentials()

            // Unregister from current domain and wait for SIP response
            await environment.sipManager.unregisterAndWait()

            // Re-register with effective domain (now reflects new SRTP preference)
            try environment.sipManager.register(
                username: credentials.username,
                password: credentials.password,
                domain: Constants.SIP.effectiveDomain
            )

            // Update stored credentials with new domain
            let updated = StoredCredentials(
                username: credentials.username,
                password: credentials.password,
                domain: Constants.SIP.effectiveDomain
            )
            try KeychainService.shared.saveCredentials(updated)

            Log.general.success("SRTP \(enabled ? "enabled" : "disabled") — re-registered on \(Constants.SIP.effectiveDomain)")
        } catch {
            // Revert on failure
            Log.general.failure("Failed to toggle SRTP", error: error)
            UserDefaults.standard.set(previousValue, forKey: Constants.UserDefaultsKeys.srtpEnabled)
            environment.sipManager.updateMediaEncryption(previousValue)
        }
    }

    // MARK: - STUN Settings
    
    var isSTUNEnabled: Bool {
        get {
            UserDefaults.standard.bool(forKey: Constants.UserDefaultsKeys.stunEnabled)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Constants.UserDefaultsKeys.stunEnabled)
            // Update SIP manager immediately
            environment.sipManager.updateSTUNEnabled(newValue)
            Log.general.call("STUN \(newValue ? "enabled" : "disabled") by user")
        }
    }
}
