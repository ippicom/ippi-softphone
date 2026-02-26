//
//  Call.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import Foundation

// MARK: - VoIP Call Model

struct VoIPCall: Identifiable, Equatable {
    var id: UUID { uuid }
    let uuid: UUID
    let remoteAddress: String
    var displayName: String?
    let direction: CallDirection
    var state: CallState
    var startTime: Date?
    var connectTime: Date?
    var endTime: Date?
    var isMuted: Bool = false
    var isOnHold: Bool = false

    init(
        uuid: UUID = UUID(),
        remoteAddress: String,
        displayName: String? = nil,
        direction: CallDirection,
        state: CallState = .idle
    ) {
        self.uuid = uuid
        self.remoteAddress = remoteAddress
        self.displayName = displayName
        self.direction = direction
        self.state = state
        self.startTime = Date()
    }
    
    var duration: TimeInterval? {
        guard let connect = connectTime else { return nil }
        let end = endTime ?? Date()
        return end.timeIntervalSince(connect)
    }
    
    var formattedDuration: String {
        guard let duration = duration else { return "00:00" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    var callerDisplay: String {
        if let name = displayName, !name.isEmpty { return name }
        let user = cleanPhoneNumber
        return SIPAddressHelper.isPhoneNumber(user)
            ? PhoneNumberFormatter.format(user)
            : SIPAddressHelper.displayableUser(from: remoteAddress)
    }
    
    var cleanPhoneNumber: String {
        SIPAddressHelper.extractPhoneNumber(from: remoteAddress)
    }
}

// MARK: - SIP Address Helper

/// Extracts and formats SIP address components
/// e.g., "sip:+33123456789@sip.ippi.com" -> "+33123456789"
enum SIPAddressHelper: Sendable {
    /// ippi-owned SIP domains — addresses on these show only the user part in UI
    private nonisolated static let ippiDomains: Set<String> = ["sip.ippi.com", "tls.ippi.com", "sips.ippi.com"]

    /// Extract just the user part (phone number or username) from a SIP address
    nonisolated static func extractPhoneNumber(from sipAddress: String) -> String {
        var address = sipAddress

        // Remove "sip:" prefix
        if address.lowercased().hasPrefix("sip:") {
            address = String(address.dropFirst(4))
        }

        // Remove everything after @ (domain part)
        if let atIndex = address.firstIndex(of: "@") {
            address = String(address[..<atIndex])
        }

        // Remove any URI parameters (after ;)
        if let semicolonIndex = address.firstIndex(of: ";") {
            address = String(address[..<semicolonIndex])
        }

        return address
    }

    /// Extract the domain from a SIP address (e.g., "sip:user@domain.com" → "domain.com")
    nonisolated static func extractDomain(from sipAddress: String) -> String? {
        var address = sipAddress
        if address.lowercased().hasPrefix("sip:") {
            address = String(address.dropFirst(4))
        }
        guard let atIndex = address.firstIndex(of: "@") else { return nil }
        var domain = String(address[address.index(after: atIndex)...])
        if let semiIndex = domain.firstIndex(of: ";") {
            domain = String(domain[..<semiIndex])
        }
        return domain.isEmpty ? nil : domain
    }

    /// Whether the domain belongs to ippi infrastructure
    nonisolated static func isIppiDomain(_ domain: String) -> Bool {
        ippiDomains.contains(domain.lowercased())
    }

    /// Whether the user part looks like a phone number (digits, +, *, #)
    nonisolated static func isPhoneNumber(_ user: String) -> Bool {
        let phoneChars = CharacterSet(charactersIn: "0123456789+*#")
        return !user.isEmpty && phoneChars.isSuperset(of: CharacterSet(charactersIn: user))
    }

    /// Extract the dialable address for redial:
    /// - Phone numbers → just the number (for E.164 normalization)
    /// - Usernames → user@domain (passed as SIP URI to the stack)
    nonisolated static func extractDialableAddress(from sipAddress: String) -> String {
        let user = extractPhoneNumber(from: sipAddress)
        if isPhoneNumber(user) {
            return user
        }
        // Username — include the domain so SIPManager can route it
        if let domain = extractDomain(from: sipAddress) {
            return "\(user)@\(domain)"
        }
        return user
    }

    /// User part for display: username only for ippi domains, user@domain for external
    /// Does NOT format phone numbers — callers should use PhoneNumberFormatter for that.
    nonisolated static func displayableUser(from sipAddress: String) -> String {
        let user = extractPhoneNumber(from: sipAddress)
        if isPhoneNumber(user) {
            return user
        }
        if let domain = extractDomain(from: sipAddress), !isIppiDomain(domain) {
            return "\(user)@\(domain)"
        }
        return user
    }

}

// MARK: - Call Direction

enum CallDirection: String, Codable {
    case incoming
    case outgoing
    
    var icon: String {
        switch self {
        case .incoming: return "phone.arrow.down.left"
        case .outgoing: return "phone.arrow.up.right"
        }
    }
}

// MARK: - Call State

enum CallState: String, Codable {
    case idle
    case outgoingInit
    case outgoingProgress
    case outgoingRinging
    case incoming
    case connected
    case paused
    case pausedByRemote
    case error
    case ended
    
    var displayText: String {
        switch self {
        case .idle: return String(localized: "call.state.idle")
        case .outgoingInit: return String(localized: "call.state.initializing")
        case .outgoingProgress: return String(localized: "call.state.calling")
        case .outgoingRinging: return String(localized: "call.state.ringing")
        case .incoming: return String(localized: "call.incoming")
        case .connected: return String(localized: "call.state.connected")
        case .paused: return String(localized: "call.onhold")
        case .pausedByRemote: return String(localized: "call.state.heldbyremote")
        case .error: return String(localized: "common.error")
        case .ended: return String(localized: "call.state.ended")
        }
    }
    
    var isActive: Bool {
        switch self {
        case .connected, .paused, .pausedByRemote:
            return true
        default:
            return false
        }
    }
    
    var isRinging: Bool {
        switch self {
        case .incoming, .outgoingRinging:
            return true
        default:
            return false
        }
    }
}
