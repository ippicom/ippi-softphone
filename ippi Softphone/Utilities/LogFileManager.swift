//
//  LogFileManager.swift
//  ippi Softphone
//
//  Created by ippi on 17/02/2026.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Notification posted when debug logging mode changes
extension Notification.Name {
    static let debugLoggingModeChanged = Notification.Name("debugLoggingModeChanged")
}

/// Manages log file writing, rotation, and export for debug purposes
/// Thread-safe: uses internal DispatchQueue for all file operations
final class LogFileManager: Sendable {
    nonisolated static let shared = LogFileManager()
    
    private let fileManager = FileManager.default
    private let maxFileSize: Int64 = 5 * 1024 * 1024 // 5 MB
    private let maxFiles = 3
    private let logFileName = "ippi-debug.log"
    private let writeQueue = DispatchQueue(label: "com.ippi.softphone.logwriter")
    
    // MARK: - Debug Mode
    
    private let debugModeKey = "debugLoggingEnabled"
    private let debugModeEnabledAtKey = "debugLoggingEnabledAt"
    private let debugModeDuration: TimeInterval = 900 // 15 minutes
    
    /// Returns the date debug mode was enabled, or nil if not active
    private nonisolated func debugModeEnabledAt() -> Date? {
        guard UserDefaults.standard.bool(forKey: debugModeKey) else { return nil }
        return UserDefaults.standard.object(forKey: debugModeEnabledAtKey) as? Date
    }

    /// Check if debug mode is currently active (and not expired)
    nonisolated var isDebugMode: Bool {
        guard let enabledAt = debugModeEnabledAt() else { return false }
        return Date().timeIntervalSince(enabledAt) < debugModeDuration
    }

    /// Time remaining in debug mode (in seconds), or nil if not active
    nonisolated var debugModeTimeRemaining: TimeInterval? {
        guard let enabledAt = debugModeEnabledAt() else { return nil }
        let remaining = debugModeDuration - Date().timeIntervalSince(enabledAt)
        return remaining > 0 ? remaining : nil
    }
    
    /// Enable debug mode for 15 minutes
    nonisolated func enableDebugMode() {
        // Clear existing logs then enable mode, all inside writeQueue to guarantee
        // ordering: no new log can be written (and then deleted) between the two steps.
        writeQueue.async { [self] in
            try? fileManager.removeItem(at: currentLogFile)
            for i in 1...maxFiles {
                let rotatedFile = logsDirectory.appendingPathComponent("ippi-debug.\(i).log")
                try? fileManager.removeItem(at: rotatedFile)
            }

            UserDefaults.standard.set(true, forKey: debugModeKey)
            UserDefaults.standard.set(Date(), forKey: debugModeEnabledAtKey)

            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .debugLoggingModeChanged, object: nil, userInfo: ["enabled": true])
            }
        }
    }
    
    /// Disable debug mode
    nonisolated func disableDebugMode() {
        UserDefaults.standard.removeObject(forKey: debugModeKey)
        UserDefaults.standard.removeObject(forKey: debugModeEnabledAtKey)
        
        // Post notification on main thread
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .debugLoggingModeChanged, object: nil, userInfo: ["enabled": false])
        }
    }
    
    /// Check if debug mode has expired and disable it if so
    /// Returns true if mode was expired and disabled
    @discardableResult
    nonisolated func checkDebugModeExpiry() -> Bool {
        guard let enabledAt = debugModeEnabledAt() else { return false }
        guard Date().timeIntervalSince(enabledAt) >= debugModeDuration else { return false }
        disableDebugMode()
        return true
    }
    
    private var logsDirectory: URL {
        let cachesDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cachesDir.appendingPathComponent("Logs", isDirectory: true)
    }
    
    private var currentLogFile: URL {
        logsDirectory.appendingPathComponent(logFileName)
    }
    
    private init() {
        createLogsDirectoryIfNeeded()
    }
    
    // MARK: - Directory Management
    
    private func createLogsDirectoryIfNeeded() {
        if !fileManager.fileExists(atPath: logsDirectory.path) {
            try? fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        }
    }
    
    // MARK: - Writing Logs
    
    /// Append a log entry to the current log file
    /// Thread-safe: dispatches to internal serial queue
    /// 
    /// Filtering rules:
    /// - Normal mode: only write error level
    /// - Debug mode: write info, notice, warning, error (and SIP protocol logs)
    /// - Never write debug level to file (OSLog only)
    nonisolated func write(_ message: String, category: String, level: LogLevel) {
        // Filter by level before dispatching to avoid unnecessary work
        let shouldWrite: Bool
        switch level {
        case .debug:
            // Never write debug level to file
            shouldWrite = false
        case .info, .notice, .warning:
            // Only write in debug mode
            shouldWrite = isDebugMode
        case .error:
            // Always write
            shouldWrite = true
        }
        
        guard shouldWrite else { return }
        
        let date = Date()

        writeQueue.async { [self] in
            let timestamp = date.ISO8601Format()
            let logLine = "[\(timestamp)] [\(level.rawValue)] [\(category)] \(message)\n"

            if !fileManager.fileExists(atPath: currentLogFile.path) {
                let header = createLogHeader()
                try? (header + logLine).write(to: currentLogFile, atomically: true, encoding: .utf8)
            } else {
                if let handle = try? FileHandle(forWritingTo: currentLogFile) {
                    handle.seekToEndOfFile()
                    if let data = logLine.data(using: .utf8) {
                        handle.write(data)
                    }
                    try? handle.close()
                }
            }

            rotateIfNeeded()
        }
    }
    
    // MARK: - Log Rotation
    
    private func rotateIfNeeded() {
        guard let attributes = try? fileManager.attributesOfItem(atPath: currentLogFile.path),
              let fileSize = attributes[.size] as? Int64,
              fileSize > maxFileSize else {
            return
        }
        
        // Rotate logs
        for i in stride(from: maxFiles - 1, through: 1, by: -1) {
            let oldFile = logsDirectory.appendingPathComponent("ippi-debug.\(i).log")
            let newFile = logsDirectory.appendingPathComponent("ippi-debug.\(i + 1).log")
            try? fileManager.removeItem(at: newFile)
            try? fileManager.moveItem(at: oldFile, to: newFile)
        }
        
        // Move current to .1
        let rotatedFile = logsDirectory.appendingPathComponent("ippi-debug.1.log")
        try? fileManager.moveItem(at: currentLogFile, to: rotatedFile)
    }
    
    // MARK: - Export
    
    /// Get all log files combined into a single exportable file
    /// Thread-safe: runs on internal serial queue to avoid conflicts with write()
    func exportLogs() -> URL? {
        writeQueue.sync {
            // Use a dedicated export directory under Caches (tmp/ causes sharing issues on iOS)
            let exportDir = logsDirectory.appendingPathComponent("Export", isDirectory: true)
            try? fileManager.createDirectory(at: exportDir, withIntermediateDirectories: true)
            // Clean previous exports
            if let existing = try? fileManager.contentsOfDirectory(at: exportDir, includingPropertiesForKeys: nil) {
                for file in existing { try? fileManager.removeItem(at: file) }
            }
            let exportFile = exportDir.appendingPathComponent("ippi-logs-\(dateString()).txt")

            var combinedLogs = createExportHeader()

            // Add archived logs (oldest first: 3 → 2 → 1)
            for i in stride(from: maxFiles, through: 1, by: -1) {
                let rotatedFile = logsDirectory.appendingPathComponent("ippi-debug.\(i).log")
                if let content = try? String(contentsOf: rotatedFile, encoding: .utf8) {
                    combinedLogs += "\n--- Archived Log \(i) ---\n"
                    combinedLogs += content
                }
            }

            // Add current log (newest)
            if let currentContent = try? String(contentsOf: currentLogFile, encoding: .utf8) {
                combinedLogs += "\n--- Current Log ---\n"
                combinedLogs += currentContent
            }

            do {
                try combinedLogs.write(to: exportFile, atomically: true, encoding: .utf8)
                return exportFile
            } catch {
                return nil
            }
        }
    }

    // MARK: - Headers
    
    private func createLogHeader() -> String {
        """
        =============================================
        ippi Softphone Debug Log
        Started: \(Date().ISO8601Format())
        \(deviceInfo())
        =============================================
        
        """
    }
    
    private func createExportHeader() -> String {
        """
        =============================================
        ippi Softphone - Diagnostic Report
        Exported: \(Date().ISO8601Format())
        
        \(deviceInfo())
        \(appInfo())
        =============================================
        """
    }
    
    private func deviceInfo() -> String {
        #if os(iOS)
        let device = UIDevice.current
        return """
        Device: \(device.model)
        System: \(device.systemName) \(device.systemVersion)
        """
        #else
        let processInfo = ProcessInfo.processInfo
        return """
        System: macOS \(processInfo.operatingSystemVersionString)
        """
        #endif
    }
    
    private func appInfo() -> String {
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return """
        App Version: \(version) (\(build))
        Bundle ID: \(bundle.bundleIdentifier ?? "?")
        """
    }
    
    private static let fileDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func dateString() -> String {
        Self.fileDateFormatter.string(from: Date())
    }
}

// MARK: - Log Level

enum LogLevel: String, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case notice = "NOTICE"
    case warning = "WARNING"
    case error = "ERROR"
}
