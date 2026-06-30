//
//  CallHistoryEntry.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import Foundation
import SwiftData

@Model
final class CallHistoryEntry {
    var uuid: UUID
    var remoteAddress: String
    var displayName: String?
    /// Stored as String for SwiftData migration safety (avoids schema changes if enum cases change)
    var direction: String
    var startTime: Date
    var connectTime: Date?
    var endTime: Date?
    var duration: TimeInterval
    var wasAnswered: Bool
    var wasMissed: Bool
    
    init(
        uuid: UUID = UUID(),
        remoteAddress: String,
        displayName: String? = nil,
        direction: CallDirection,
        startTime: Date = Date(),
        connectTime: Date? = nil,
        endTime: Date? = nil,
        duration: TimeInterval = 0,
        wasAnswered: Bool = false,
        wasMissed: Bool = false
    ) {
        self.uuid = uuid
        self.remoteAddress = remoteAddress
        self.displayName = displayName
        self.direction = direction.rawValue
        self.startTime = startTime
        self.connectTime = connectTime
        self.endTime = endTime
        self.duration = duration
        self.wasAnswered = wasAnswered
        self.wasMissed = wasMissed
    }
    
    convenience init(from call: VoIPCall) {
        self.init(
            uuid: call.uuid,
            remoteAddress: call.remoteAddress,
            displayName: call.displayName,
            direction: call.direction,
            startTime: call.startTime ?? Date(),
            connectTime: call.connectTime,
            endTime: call.endTime,
            duration: call.duration ?? 0,
            wasAnswered: call.connectTime != nil,
            wasMissed: call.direction == .incoming && call.connectTime == nil
        )
    }
    
    var callDirection: CallDirection {
        CallDirection(rawValue: direction) ?? .outgoing
    }
    
    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    var formattedDate: String {
        if Calendar.current.isDateInToday(startTime) {
            return startTime.formatted(Date.FormatStyle().hour().minute())
        } else if Calendar.current.isDateInYesterday(startTime) {
            return String(localized: "history.yesterday")
        } else {
            return startTime.formatted(Date.FormatStyle().day().month().year())
        }
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
