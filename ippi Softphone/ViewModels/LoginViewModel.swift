//
//  LoginViewModel.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import Foundation

@MainActor
@Observable
final class LoginViewModel {
    // MARK: - Properties
    
    var username: String = ""
    var password: String = ""
    var isLoading: Bool = false
    var errorMessage: String?
    var showError: Bool = false
    
    private let environment: AppEnvironment

    init() {
        self.environment = .shared
    }

    init(environment: AppEnvironment) {
        self.environment = environment
    }
    
    // MARK: - Computed Properties
    
    var isFormValid: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty &&
        password.count >= 3
    }
    
    // MARK: - Actions
    
    func login() async {
        guard !isLoading else { return }
        guard isFormValid else {
            showError(message: String(localized: "login.error.form"))
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        do {
            // Clean username (remove domain if user added it)
            let cleanUsername = username
                .replacingOccurrences(of: "@\(Constants.SIP.domain)", with: "")
                .replacingOccurrences(of: "@\(Constants.SIP.srtpDomain)", with: "")
                .trimmingCharacters(in: .whitespaces)
            
            try await environment.login(username: cleanUsername, password: password)
            
            Log.general.success("Login successful for \(cleanUsername)")
        } catch {
            Log.general.failure("Login failed", error: error)
            showError(message: error.localizedDescription)
        }
        
        isLoading = false
    }
    
    func clearError() {
        errorMessage = nil
        showError = false
    }
    
    // MARK: - Private Methods
    
    private func showError(message: String) {
        errorMessage = message
        showError = true
    }
}
