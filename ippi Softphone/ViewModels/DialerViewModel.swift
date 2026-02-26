//
//  DialerViewModel.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import Foundation

@MainActor
@Observable
final class DialerViewModel {
    // MARK: - Properties
    
    var phoneNumber: String = ""
    /// Raw phone number stripped of formatting (for validation and dialing)
    var rawPhoneNumber: String {
        if isAlphanumericInput(phoneNumber) { return phoneNumber }
        return phoneNumber.filter { $0 != " " }
    }
    var isLoading: Bool = false
    var errorMessage: String?
    var isShowingError: Bool = false
    var isMicPermissionError: Bool = false
    
    private let environment: AppEnvironment

    init() {
        self.environment = .shared
    }

    init(environment: AppEnvironment) {
        self.environment = environment
    }
    
    // MARK: - Computed Properties
    
    var canDial: Bool {
        isValidNumber && environment.currentAccount?.registrationState == .registered
    }
    
    /// Validates that the input is suitable for dialing:
    /// 1. SIP URI (contains @) → accepted as-is
    /// 2. Phone number (digits, +, *, #) → accepted
    /// 3. ippi username (alphanumeric, ., -, _) → accepted
    private var isValidNumber: Bool {
        let trimmed = rawPhoneNumber.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return false }

        // SIP URI (contains @) → accept as-is
        if trimmed.contains("@") { return true }

        // Phone number (digits, +, *, #)
        if SIPAddressHelper.isPhoneNumber(trimmed) { return true }

        // ippi username: alphanumeric + . - _
        let usernameChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return usernameChars.isSuperset(of: CharacterSet(charactersIn: trimmed))
    }
    
    var registrationState: SIPRegistrationState {
        environment.currentAccount?.registrationState ?? .none
    }
    
    var isRegistered: Bool {
        registrationState == .registered
    }
    
    var canConnect: Bool {
        registrationState == .none || registrationState == .cleared || registrationState == .failed
    }
    
    var accountDisplay: String {
        // Show just the username without domain
        environment.currentAccount?.username ?? String(localized: "account.notloggedin")
    }
    
    var registrationError: String? {
        if registrationState == .failed {
            return String(localized: "registration.failed.message")
        }
        return nil
    }
    
    /// Returns the SIP error details (code + reason) when registration fails
    var registrationErrorDetails: String? {
        guard registrationState == .failed,
              let error = environment.sipManager.lastRegistrationError else {
            return nil
        }
        // Only show code if it's a valid SIP response code (> 0)
        if error.code > 0 {
            return "(\(error.code) - \(error.reason))"
        } else {
            return "(\(error.reason))"
        }
    }
    
    // MARK: - Actions
    
    func appendDigit(_ digit: String) {
        let raw = rawPhoneNumber + digit
        phoneNumber = formatForDisplay(raw)
    }

    func deleteLastDigit() {
        var raw = rawPhoneNumber
        guard !raw.isEmpty else { return }
        raw.removeLast()
        phoneNumber = formatForDisplay(raw)
    }

    func clearNumber() {
        phoneNumber = ""
    }

    /// Called when the TextField text changes (keyboard input or paste)
    func setPhoneNumber(_ value: String) {
        phoneNumber = formatForDisplay(value)
    }
    
    func dial() async {
        guard !phoneNumber.isEmpty else { return }
        
        guard isValidNumber else {
            showError(message: String(localized: "dialer.error.invalid"))
            return
        }
        
        guard isRegistered else {
            showError(message: String(localized: "dialer.error.notregistered"))
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        do {
            let trimmed = rawPhoneNumber.trimmingCharacters(in: .whitespaces)
            let destination: String
            if trimmed.contains("@") {
                // SIP URI → pass as-is
                destination = trimmed
            } else if SIPAddressHelper.isPhoneNumber(trimmed) {
                // Phone number → normalize (converts 0... to +33...)
                destination = PhoneNumberFormatter.normalize(trimmed)
            } else {
                // ippi username → build SIP address
                destination = "\(trimmed)@\(Constants.SIP.sipDomain)"
            }
            try await environment.callService.dial(destination)
            // Clear number after successful dial
            phoneNumber = ""
        } catch let error as CallServiceError where error == .microphonePermissionDenied {
            Log.general.failure("Failed to dial — mic permission denied")
            isMicPermissionError = true
            showError(message: error.localizedDescription)
        } catch {
            Log.general.failure("Failed to dial", error: error)
            showError(message: error.localizedDescription)
        }
        
        isLoading = false
    }
    
    func dialContact(_ contact: Contact) async {
        guard let number = contact.primaryPhoneNumber else { return }
        // Use normalized value for dialing
        phoneNumber = number.normalizedValue.isEmpty ? number.value : number.normalizedValue
        await dial()
    }
    
    // MARK: - Connection Actions
    
    func toggleConnection() async {
        do {
            try environment.toggleConnection()
        } catch {
            Log.general.failure("Failed to reconnect", error: error)
            showError(message: String(localized: "dialer.error.connection"))
        }
    }
    
    // MARK: - Private Methods
    
    /// Returns true if the input contains letters or @ (SIP URI / username — not a phone number)
    private func isAlphanumericInput(_ text: String) -> Bool {
        text.contains("@") || text.contains(where: { $0.isLetter })
    }

    /// Formats a raw phone number for display, or returns as-is for usernames/SIP URIs
    private func formatForDisplay(_ raw: String) -> String {
        guard !raw.isEmpty, !isAlphanumericInput(raw) else { return raw }
        // Strip any existing spaces before formatting
        let stripped = raw.filter { $0 != " " }
        // Don't format strings with * or # (DTMF sequences)
        if stripped.contains("*") || stripped.contains("#") { return stripped }
        return PhoneNumberFormatter.formatPartial(stripped)
    }

    private func showError(message: String) {
        errorMessage = message
        isShowingError = true
    }

    func clearError() {
        isMicPermissionError = false
        errorMessage = nil
    }
}
