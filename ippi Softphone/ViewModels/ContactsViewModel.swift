//
//  ContactsViewModel.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import Foundation
import Contacts
#if os(iOS)
import UIKit
#endif

@MainActor
@Observable
final class ContactsViewModel {
    // MARK: - Properties
    
    var contacts: [Contact] = []
    var isLoading: Bool = false
    var searchText: String = ""
    var showPermissionAlert: Bool = false
    var errorMessage: String?
    
    private let environment: AppEnvironment

    init() {
        self.environment = .shared
    }

    init(environment: AppEnvironment) {
        self.environment = environment
    }
    
    // MARK: - Computed Properties
    
    var filteredContacts: [Contact] {
        guard !searchText.isEmpty else { return contacts }

        let query = searchText.lowercased()
        let queryDigits = searchText.filter { $0.isNumber }

        return contacts.filter { contact in
            // Match by name
            if contact.fullName.lowercased().contains(query) {
                return true
            }

            // Match by phone number digits
            guard !queryDigits.isEmpty else { return false }

            return contact.phoneNumbers.contains { phone in
                phoneDigitsMatch(phoneValue: phone.value, queryDigits: queryDigits)
            }
        }
    }

    /// Checks if a phone number matches a digit query, handling national prefix conversion (0x ↔ +33x)
    private func phoneDigitsMatch(phoneValue: String, queryDigits: String) -> Bool {
        let phoneDigits = phoneValue.filter { $0.isNumber }

        // Direct digit match
        if phoneDigits.contains(queryDigits) { return true }

        // Query "0633..." should match phone "+33633..." (national → international)
        if queryDigits.hasPrefix("0"), !queryDigits.hasPrefix("00") {
            let expanded = "33" + queryDigits.dropFirst()
            if phoneDigits.contains(expanded) { return true }
        }

        // Phone "0633..." should match query "33633..." (reverse)
        if phoneDigits.hasPrefix("0"), !phoneDigits.hasPrefix("00") {
            let phoneExpanded = "33" + phoneDigits.dropFirst()
            if phoneExpanded.contains(queryDigits) { return true }
        }

        // Query "0033633..." should match phone "+33633..."
        if queryDigits.hasPrefix("00") {
            let stripped = String(queryDigits.dropFirst(2))
            if phoneDigits.contains(stripped) { return true }
        }

        return false
    }
    
    var groupedContacts: [(String, [Contact])] {
        let grouped = Dictionary(grouping: filteredContacts) { contact -> String in
            let firstChar = contact.fullName.first?.uppercased() ?? "#"
            return firstChar.rangeOfCharacter(from: .letters) != nil ? firstChar : "#"
        }
        
        return grouped.sorted { $0.key < $1.key }
    }
    
    var hasPermission: Bool {
        environment.contactsService.isAuthorized
    }
    
    // MARK: - Actions
    
    func loadContacts() async {
        isLoading = true
        errorMessage = nil
        
        do {
            contacts = try await environment.contactsService.fetchAllContacts()
        } catch {
            Log.contacts.failure("Failed to load contacts", error: error)
            
            if !hasPermission {
                showPermissionAlert = true
            } else {
                errorMessage = error.localizedDescription
            }
        }
        
        isLoading = false
    }
    
    func refreshContacts() async {
        do {
            contacts = try await environment.contactsService.fetchAllContacts(forceRefresh: true)
        } catch {
            Log.contacts.failure("Failed to refresh contacts", error: error)
        }
    }
    
    /// True when contacts permission has been permanently denied (user must go to Settings)
    var isPermissionDenied: Bool {
        environment.contactsService.authorizationStatus == .denied
    }

    func requestPermission() async {
        // If already denied, iOS won't show the dialog again — open Settings instead
        #if os(iOS)
        if isPermissionDenied {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                await UIApplication.shared.open(url)
            }
            return
        }
        #endif

        do {
            let granted = try await environment.contactsService.requestAccess()
            if granted {
                await loadContacts()
            } else {
                showPermissionAlert = true
            }
        } catch {
            Log.contacts.failure("Failed to request permission", error: error)
        }
    }
    
    func call(_ contact: Contact, phoneNumber: PhoneNumber) async {
        do {
            // Normalize the phone number for SIP (converts 0... to +33...)
            let dialNumber = PhoneNumberFormatter.normalize(phoneNumber.value)
            try await environment.callService.dial(dialNumber)
        } catch {
            Log.general.failure("Failed to call contact", error: error)
        }
    }
}
