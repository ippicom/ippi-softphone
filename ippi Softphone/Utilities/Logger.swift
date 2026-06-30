//
//  Logger.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import Foundation
import OSLog

/// Logger categories for the app - AppLogger is Sendable so safe from any context
/// nonisolated required to allow access from nonisolated delegate callbacks
enum Log: Sendable {
    nonisolated static let sip = AppLogger(category: "SIP")
    nonisolated static let callKit = AppLogger(category: "CallKit")
    nonisolated static let pushKit = AppLogger(category: "PushKit")
    nonisolated static let audio = AppLogger(category: "Audio")
    nonisolated static let contacts = AppLogger(category: "Contacts")
    nonisolated static let general = AppLogger(category: "General")
}

/// Custom logger that writes to both OSLog and file
/// nonisolated required on all methods because OSLog.Logger is not Sendable
struct AppLogger: Sendable {
    private let osLogger: Logger
    private let category: String

    init(category: String) {
        self.category = category
        self.osLogger = Logger(subsystem: "com.ippi.softphone", category: category)
    }

    nonisolated func debug(_ message: String, function: String = #function) {
        let formattedMessage = "[\(function)] \(message)"
        osLogger.debug("\(formattedMessage)")
        LogFileManager.shared.write(formattedMessage, category: category, level: .debug)
    }

    nonisolated func info(_ message: String, function: String = #function) {
        let formattedMessage = "[\(function)] \(message)"
        osLogger.info("\(formattedMessage)")
        LogFileManager.shared.write(formattedMessage, category: category, level: .info)
    }

    /// Alias for info
    nonisolated func call(_ message: String, function: String = #function) {
        info(message, function: function)
    }

    nonisolated func notice(_ message: String, function: String = #function) {
        let formattedMessage = "[\(function)] \(message)"
        osLogger.notice("\(formattedMessage)")
        LogFileManager.shared.write(formattedMessage, category: category, level: .notice)
    }

    nonisolated func success(_ message: String, function: String = #function) {
        let formattedMessage = "[\(function)] ✓ \(message)"
        osLogger.notice("\(formattedMessage)")
        LogFileManager.shared.write(formattedMessage, category: category, level: .notice)
    }

    nonisolated func warning(_ message: String, function: String = #function) {
        let formattedMessage = "[\(function)] ⚠ \(message)"
        osLogger.warning("\(formattedMessage)")
        LogFileManager.shared.write(formattedMessage, category: category, level: .warning)
    }

    /// Log an error/failure message with optional error details
    nonisolated func failure(_ message: String, error: Error? = nil, function: String = #function) {
        let formattedMessage: String
        if let error = error {
            formattedMessage = "[\(function)] ✗ \(message): \(error.localizedDescription)"
        } else {
            formattedMessage = "[\(function)] ✗ \(message)"
        }
        osLogger.error("\(formattedMessage)")
        LogFileManager.shared.write(formattedMessage, category: category, level: .error)
    }
}
