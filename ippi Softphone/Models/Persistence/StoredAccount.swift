//
//  StoredAccount.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import Foundation
import SwiftData

@Model
final class StoredAccount {
    @Attribute(.unique) var username: String
    var domain: String
    var displayName: String?
    var isDefault: Bool
    var createdAt: Date
    
    init(
        username: String,
        domain: String = Constants.SIP.domain,
        displayName: String? = nil,
        isDefault: Bool = true
    ) {
        self.username = username
        self.domain = domain
        self.displayName = displayName
        self.isDefault = isDefault
        self.createdAt = Date()
    }
    
    var sipAddress: String {
        "sip:\(username)@\(domain)"
    }
    
    var displayAddress: String {
        "\(username)@\(domain)"
    }
    
    func toAccount(registrationState: SIPRegistrationState = .none) -> Account {
        Account(
            username: username,
            domain: domain,
            displayName: displayName,
            registrationState: registrationState
        )
    }
}
