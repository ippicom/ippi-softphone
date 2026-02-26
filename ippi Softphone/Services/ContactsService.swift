//
//  ContactsService.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import Foundation
@preconcurrency import Contacts

@MainActor
final class ContactsService {
    // MARK: - Properties
    
    private let store = CNContactStore()
    private var cachedContacts: [Contact] = []
    private var normalizedPhoneIndex: [String: Contact] = [:]
    private var lastFetchDate: Date?
    private let cacheValidityDuration: TimeInterval = 300 // 5 minutes
    
    // MARK: - Initialization
    
    init() {
        Log.contacts.success("ContactsService initialized")
    }
    
    // MARK: - Authorization
    
    var authorizationStatus: CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }
    
    var isAuthorized: Bool {
        authorizationStatus == .authorized
    }
    
    func requestAccess() async throws -> Bool {
        Log.contacts.call("Requesting contacts access")
        
        do {
            let granted = try await store.requestAccess(for: .contacts)
            if granted {
                Log.contacts.success("Contacts access granted")
            } else {
                Log.contacts.failure("Contacts access denied")
            }
            return granted
        } catch {
            Log.contacts.failure("Failed to request contacts access", error: error)
            throw error
        }
    }
    
    // MARK: - Fetching Contacts
    
    func fetchAllContacts(forceRefresh: Bool = false) async throws -> [Contact] {
        // Return cached if valid
        if !forceRefresh,
           let lastFetch = lastFetchDate,
           Date().timeIntervalSince(lastFetch) < cacheValidityDuration,
           !cachedContacts.isEmpty {
            Log.contacts.call("Returning cached contacts")
            return cachedContacts
        }
        
        if !isAuthorized {
            let granted = try await requestAccess()
            guard granted else {
                return []
            }
        }
        
        Log.contacts.call("Fetching all contacts")
        
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor
        ]
        
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        request.sortOrder = .givenName
        
        var contacts: [Contact] = []
        
        // Capture store reference before entering async context
        let contactStore = self.store
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    // Safe: enumerateContacts calls its block synchronously on this serial queue,
                    // so `contacts` is only mutated from a single thread.
                    try contactStore.enumerateContacts(with: request) { cnContact, _ in
                        let phoneNumbers = cnContact.phoneNumbers.map { phoneNumber in
                            PhoneNumber(
                                label: CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: phoneNumber.label ?? ""),
                                value: phoneNumber.value.stringValue
                            )
                        }
                        
                        // Only include contacts with phone numbers
                        guard !phoneNumbers.isEmpty else { return }
                        
                        let contact = Contact(
                            id: cnContact.identifier,
                            givenName: cnContact.givenName,
                            familyName: cnContact.familyName,
                            phoneNumbers: phoneNumbers,
                            thumbnailImageData: cnContact.thumbnailImageData
                        )
                        contacts.append(contact)
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        
        cachedContacts = contacts
        lastFetchDate = Date()
        buildPhoneIndex()

        Log.contacts.success("Fetched \(contacts.count) contacts")
        return contacts
    }
    
    /// Lightweight preload: fetch only names + phone numbers (no thumbnails).
    /// Builds the phone index for caller ID without populating the full contacts cache.
    func preloadPhoneIndex() async throws {
        guard isAuthorized else { return }

        Log.contacts.call("Preloading phone index (lightweight, no thumbnails)")

        let keysToFetch: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor
        ]

        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        request.sortOrder = .givenName

        var contacts: [Contact] = []
        let contactStore = self.store

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try contactStore.enumerateContacts(with: request) { cnContact, _ in
                        let phoneNumbers = cnContact.phoneNumbers.map { phoneNumber in
                            PhoneNumber(
                                label: CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: phoneNumber.label ?? ""),
                                value: phoneNumber.value.stringValue
                            )
                        }
                        guard !phoneNumbers.isEmpty else { return }
                        let contact = Contact(
                            id: cnContact.identifier,
                            givenName: cnContact.givenName,
                            familyName: cnContact.familyName,
                            phoneNumbers: phoneNumbers,
                            thumbnailImageData: nil
                        )
                        contacts.append(contact)
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        // Build phone index only — don't fill the full contacts cache
        // so fetchAllContacts() will still do a full fetch with thumbnails later
        normalizedPhoneIndex = [:]
        for contact in contacts {
            for phone in contact.phoneNumbers {
                let normalized = PhoneNumberFormatter.normalize(phone.value)
                normalizedPhoneIndex[normalized] = contact
            }
        }

        Log.contacts.success("Phone index preloaded: \(normalizedPhoneIndex.count) entries from \(contacts.count) contacts")
    }

    // MARK: - Search
    
    func searchContacts(query: String) async -> [Contact] {
        let contacts = try? await fetchAllContacts()
        guard let contacts = contacts, !query.isEmpty else {
            return contacts ?? []
        }
        
        let lowercasedQuery = query.lowercased()
        
        return contacts.filter { contact in
            contact.fullName.lowercased().contains(lowercasedQuery) ||
            contact.phoneNumbers.contains { $0.value.contains(query) }
        }
    }
    
    // MARK: - Contact Matching

    /// Build a normalized phone number → Contact lookup dictionary for O(1) lookups
    private func buildPhoneIndex() {
        normalizedPhoneIndex = [:]
        for contact in cachedContacts {
            for phone in contact.phoneNumbers {
                let normalized = PhoneNumberFormatter.normalize(phone.value)
                normalizedPhoneIndex[normalized] = contact
            }
        }
        Log.contacts.call("Built phone index with \(normalizedPhoneIndex.count) entries")
    }

    /// Finds a contact by phone number using the pre-built normalized index (O(1) lookup)
    func findContact(for phoneNumber: String) -> Contact? {
        let normalized = PhoneNumberFormatter.normalize(phoneNumber)
        return normalizedPhoneIndex[normalized]
    }
    
    /// Returns the contact name for a phone number, or nil if not found
    func findContactName(for phoneNumber: String) -> String? {
        findContact(for: phoneNumber)?.fullName
    }
    
    /// Returns display info for a phone number: (name, formattedNumber) tuple
    /// If contact found: returns (contactName, formattedNumber)
    /// If not found: returns (nil, formattedNumber)
    func displayInfo(for phoneNumber: String) -> (name: String?, formattedNumber: String) {
        let formatted = PhoneNumberFormatter.format(phoneNumber)
        let contactName = findContactName(for: phoneNumber)
        return (contactName, formatted)
    }
    
}
