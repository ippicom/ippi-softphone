//
//  PhoneNumberFormatter.swift
//  ippi Softphone
//
//  Created by ippi on 17/02/2026.
//

import Foundation
@preconcurrency import PhoneNumberKit

/// Utility for formatting phone numbers in international format
/// Uses PhoneNumberKit (Google's libphonenumber port for Swift)
enum PhoneNumberFormatter {
    private nonisolated(unsafe) static let phoneNumberUtility = PhoneNumberUtility()
    private nonisolated(unsafe) static let partialFormatter = PartialFormatter(
        utility: phoneNumberUtility, defaultRegion: "FR", withPrefix: true
    )

    // Country code mapping for national prefix conversion
    private static let regionCountryCodes: [String: String] = [
        "FR": "+33", "US": "+1", "GB": "+44", "DE": "+49", "ES": "+34",
        "IT": "+39", "BE": "+32", "CH": "+41", "NL": "+31", "PT": "+351"
    ]

    /// Convert national number (starting with 0) to international format using defaultRegion
    private static func applyNationalPrefix(_ number: String, defaultRegion: String) -> String {
        guard number.hasPrefix("0") && !number.hasPrefix("00") else { return number }
        let countryCode = regionCountryCodes[defaultRegion] ?? "+33"
        return countryCode + number.dropFirst()
    }

    /// Parse a phone number with automatic region detection
    private static func parseNumber(_ number: String, defaultRegion: String) throws -> PhoneNumberKit.PhoneNumber {
        let clean = applyNationalPrefix(number, defaultRegion: defaultRegion)
        if clean.hasPrefix("+") {
            return try phoneNumberUtility.parse(clean)
        } else {
            return try phoneNumberUtility.parse(clean, withRegion: defaultRegion)
        }
    }

    /// Formats a phone number to international format
    static func format(_ number: String, defaultRegion: String = "FR") -> String {
        do {
            let parsed = try parseNumber(number, defaultRegion: defaultRegion)
            return phoneNumberUtility.format(parsed, toType: .international)
        } catch {
            return number
        }
    }

    /// Checks if a phone number is valid
    static func isValid(_ number: String, defaultRegion: String = "FR") -> Bool {
        let clean = applyNationalPrefix(number, defaultRegion: defaultRegion)
        if clean.hasPrefix("+") {
            return phoneNumberUtility.isValidPhoneNumber(clean)
        } else {
            return phoneNumberUtility.isValidPhoneNumber(clean, withRegion: defaultRegion)
        }
    }

    /// Normalizes a phone number to E.164 format for SIP dialing
    static func normalize(_ number: String, defaultRegion: String = "FR") -> String {
        do {
            let parsed = try parseNumber(number, defaultRegion: defaultRegion)
            return phoneNumberUtility.format(parsed, toType: .e164)
        } catch {
            // Fallback: just keep digits and leading +
            let digitsOnly = number.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            if number.hasPrefix("+") || number.hasPrefix("00") {
                return "+" + digitsOnly.dropFirst(number.hasPrefix("00") ? 2 : 0)
            }
            return digitsOnly
        }
    }

    /// Formats a phone number as-you-type (for real-time display while dialing)
    static func formatPartial(_ number: String) -> String {
        partialFormatter.formatPartial(number)
    }

    /// Compares two phone numbers to check if they represent the same number
    static func areEqual(_ number1: String, _ number2: String, defaultRegion: String = "FR") -> Bool {
        let normalized1 = normalize(number1, defaultRegion: defaultRegion)
        let normalized2 = normalize(number2, defaultRegion: defaultRegion)
        return normalized1 == normalized2
    }
}
