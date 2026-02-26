//
//  Contact.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import Foundation

// MARK: - Contact Model

struct Contact: Identifiable, Equatable {
    let id: String
    let givenName: String
    let familyName: String
    let phoneNumbers: [PhoneNumber]
    let thumbnailImageData: Data?
    
    var fullName: String {
        let name = "\(givenName) \(familyName)".trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Unknown" : name
    }
    
    var initials: String {
        let first = givenName.first.map { String($0).uppercased() } ?? ""
        let last = familyName.first.map { String($0).uppercased() } ?? ""
        let initials = "\(first)\(last)"
        return initials.isEmpty ? "?" : initials
    }
    
    var primaryPhoneNumber: PhoneNumber? {
        phoneNumbers.first
    }
}

// MARK: - Phone Number

struct PhoneNumber: Identifiable, Equatable {
    let id: String
    let label: String?
    let value: String

    init(label: String? = nil, value: String) {
        self.id = "\(label ?? ""):\(value)"
        self.label = label
        self.value = value
    }
    
    var displayLabel: String {
        label ?? "Phone"
    }
    
    /// Returns the phone number with only digits and leading + (for international format)
    var normalizedValue: String {
        let digitsOnly = value.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        // Preserve leading + for international numbers
        if value.hasPrefix("+") {
            return "+" + digitsOnly
        }
        return digitsOnly
    }
}
