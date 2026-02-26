//
//  Account.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import Foundation
import SwiftUI

// MARK: - Account Model

struct Account: Identifiable, Equatable {
    let id: UUID
    let username: String
    let domain: String
    var displayName: String?
    var registrationState: SIPRegistrationState
    
    init(
        id: UUID = UUID(),
        username: String,
        domain: String = Constants.SIP.domain,
        displayName: String? = nil,
        registrationState: SIPRegistrationState = .none
    ) {
        self.id = id
        self.username = username
        self.domain = domain
        self.displayName = displayName
        self.registrationState = registrationState
    }
    
    var sipAddress: String {
        "sip:\(username)@\(domain)"
    }
    
    var displayAddress: String {
        "\(username)@\(domain)"
    }
}

// MARK: - Registration State

enum SIPRegistrationState: String, Equatable {
    case none
    case progress
    case registered
    case failed
    case cleared
    
    var statusColor: Color {
        switch self {
        case .none, .cleared: return .gray
        case .progress: return .orange
        case .registered: return .green
        case .failed: return .red
        }
    }

    var localizedStatusText: String {
        switch self {
        case .none: return String(localized: "registration.none")
        case .progress: return String(localized: "registration.progress")
        case .registered: return String(localized: "registration.registered")
        case .failed: return String(localized: "registration.failed")
        case .cleared: return String(localized: "registration.cleared")
        }
    }
    
    var isConnected: Bool {
        self == .registered
    }
}
