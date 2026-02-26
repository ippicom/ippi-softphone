//
//  NotificationService.swift
//  NotificationServiceExtension
//
//  Created by Guillaume Lacroix on 18/02/2026.
//

import UserNotifications
import Contacts

class NotificationService: UNNotificationServiceExtension {
    // Shared constants (NSE can't access main app's Constants.swift)
    private static let appGroupID = "group.com.ippi.softphone"
    private static let badgeCountKey = "unseenMissedCallCount"

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent

        guard let bestAttemptContent else {
            contentHandler(request.content)
            return
        }

        // Extract SIP URI from payload
        guard let sipFrom = request.content.userInfo["from"] as? String else {
            contentHandler(bestAttemptContent)
            return
        }

        // Increment badge before contact lookup (which may be slow or time out)
        let sharedDefaults = UserDefaults(suiteName: Self.appGroupID)
        let currentCount = sharedDefaults?.integer(forKey: Self.badgeCountKey) ?? 0
        let newCount = currentCount + 1
        sharedDefaults?.set(newCount, forKey: Self.badgeCountKey)
        bestAttemptContent.badge = NSNumber(value: newCount)

        // Enrich notification body with contact name
        let phoneNumber = extractPhoneNumber(from: sipFrom)
        let displayName = lookupContactName(for: phoneNumber) ?? formatPhoneNumber(phoneNumber)

        let format = Bundle.main.localizedString(
            forKey: "notification.missed_call_from",
            value: "Missed call from %@",
            table: nil
        )
        bestAttemptContent.body = String(format: format, displayName)

        contentHandler(bestAttemptContent)
    }

    override func serviceExtensionTimeWillExpire() {
        // Deliver whatever we have before timeout
        if let contentHandler, let bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }

    // MARK: - SIP Address Parsing (same logic as SIPAddressHelper)

    private func extractPhoneNumber(from sipAddress: String) -> String {
        var address = sipAddress

        if address.lowercased().hasPrefix("sip:") {
            address = String(address.dropFirst(4))
        }
        if let atIndex = address.firstIndex(of: "@") {
            address = String(address[..<atIndex])
        }
        if let semicolonIndex = address.firstIndex(of: ";") {
            address = String(address[..<semicolonIndex])
        }

        return address
    }

    // MARK: - Contact Lookup

    private func lookupContactName(for phoneNumber: String) -> String? {
        let store = CNContactStore()
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor
        ]

        // PhoneNumber predicate handles various formats (+33, 06, etc.)
        let predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: phoneNumber))

        guard let contacts = try? store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch),
              let contact = contacts.first else {
            return nil
        }

        let name = [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return name.isEmpty ? nil : name
    }

    // MARK: - Phone Number Formatting

    /// Basic formatting for display when no contact is found.
    /// Groups digits for readability (e.g., +33 6 00 00 00 00).
    private func formatPhoneNumber(_ number: String) -> String {
        // If it's a French number starting with +33, format as +33 X XX XX XX XX
        if number.hasPrefix("+33") && number.count == 12 {
            let digits = number.dropFirst(3) // "600000000"
            var result = "+33 "
            for (index, char) in digits.enumerated() {
                if index == 1 || (index > 1 && index % 2 == 1) {
                    result += " "
                }
                result.append(char)
            }
            return result
        }

        // For other numbers, just return as-is (the extension doesn't have PhoneNumberKit)
        return number
    }
}
