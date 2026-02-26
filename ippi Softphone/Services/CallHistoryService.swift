//
//  CallHistoryService.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import Foundation
import SwiftData
#if os(iOS)
import UserNotifications
#endif

@MainActor
final class CallHistoryService {
    // MARK: - Properties
    
    private var modelContext: ModelContext?
    
    // MARK: - Initialization
    
    init() {
        Log.general.success("CallHistoryService initialized")
    }
    
    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }
    
    // MARK: - CRUD Operations
    
    func addEntry(from call: VoIPCall) async {
        guard let context = modelContext else {
            Log.general.failure("Model context not set")
            return
        }
        
        Log.general.call("Adding call history entry")
        
        let entry = CallHistoryEntry(from: call)
        context.insert(entry)

        do {
            try context.save()
            Log.general.success("Call history entry saved")
        } catch {
            Log.general.failure("Failed to save call history", error: error)
        }
    }
    
    func fetchHistory(limit: Int = 100) async -> [CallHistoryEntry] {
        guard let context = modelContext else {
            Log.general.failure("Model context not set")
            return []
        }
        
        Log.general.call("Fetching call history")
        
        do {
            var descriptor = FetchDescriptor<CallHistoryEntry>(
                sortBy: [SortDescriptor(\.startTime, order: .reverse)]
            )
            descriptor.fetchLimit = limit
            
            let entries = try context.fetch(descriptor)
            Log.general.success("Fetched \(entries.count) history entries")
            return entries
        } catch {
            Log.general.failure("Failed to fetch call history", error: error)
            return []
        }
    }
    
    func fetchMissedCalls() async -> [CallHistoryEntry] {
        guard let context = modelContext else { return [] }
        
        do {
            let predicate = #Predicate<CallHistoryEntry> { entry in
                entry.wasMissed == true
            }
            
            var descriptor = FetchDescriptor<CallHistoryEntry>(
                predicate: predicate,
                sortBy: [SortDescriptor(\.startTime, order: .reverse)]
            )
            descriptor.fetchLimit = 50
            
            return try context.fetch(descriptor)
        } catch {
            Log.general.failure("Failed to fetch missed calls", error: error)
            return []
        }
    }
    
    func deleteEntry(_ entry: CallHistoryEntry) async {
        guard let context = modelContext else { return }
        
        Log.general.call("Deleting call history entry")
        
        context.delete(entry)
        
        do {
            try context.save()
            Log.general.success("Call history entry deleted")
        } catch {
            Log.general.failure("Failed to delete call history entry", error: error)
        }
    }
    
    func clearAll() async {
        guard let context = modelContext else { return }
        
        Log.general.call("Clearing all call history")
        
        do {
            try context.delete(model: CallHistoryEntry.self)
            try context.save()
            Log.general.success("All call history cleared")
        } catch {
            Log.general.failure("Failed to clear call history", error: error)
        }
    }
    
    // MARK: - Missed Call from Notification

    #if os(iOS)
    enum MissedCallResult {
        case created
        case duplicate
        case failed
    }

    /// Create a missed call history entry from a delivered APNs notification.
    func addMissedCallFromNotification(remoteAddress: String, date: Date) async -> MissedCallResult {
        guard let context = modelContext else {
            Log.general.failure("Model context not set")
            return .failed
        }

        // Check for duplicate: an entry with the same number within 60 seconds
        let windowStart = date.addingTimeInterval(-60)
        let windowEnd = date.addingTimeInterval(60)
        let predicate = #Predicate<CallHistoryEntry> { entry in
            entry.wasMissed == true
            && entry.startTime >= windowStart
            && entry.startTime <= windowEnd
        }

        do {
            let descriptor = FetchDescriptor<CallHistoryEntry>(predicate: predicate)
            let existing = try context.fetch(descriptor)

            // Check if any existing entry matches the same phone number
            let phoneNumber = SIPAddressHelper.extractPhoneNumber(from: remoteAddress)
            let isDuplicate = existing.contains { entry in
                SIPAddressHelper.extractPhoneNumber(from: entry.remoteAddress) == phoneNumber
            }

            if isDuplicate {
                Log.general.call("Skipping duplicate missed call entry for \(phoneNumber)")
                return .duplicate
            }
        } catch {
            Log.general.failure("Failed to check for duplicate missed call", error: error)
            // Continue anyway — better to have a duplicate than lose the entry
        }

        let entry = CallHistoryEntry(
            remoteAddress: remoteAddress,
            direction: .incoming,
            startTime: date,
            endTime: date,
            wasMissed: true
        )

        context.insert(entry)

        do {
            try context.save()
            Log.general.success("Missed call from notification saved: \(remoteAddress)")
            return .created
        } catch {
            Log.general.failure("Failed to save missed call from notification", error: error)
            return .failed
        }
    }

    /// Process all delivered missed call notifications and create history entries.
    /// Removes processed notifications from the notification center.
    func processMissedCallNotifications() async {
        let center = UNUserNotificationCenter.current()
        let notifications = await center.deliveredNotifications()

        var processedIdentifiers: [String] = []

        for notification in notifications {
            // Only process notifications with a "from" field (missed call from OpenSIPS)
            guard let sipFrom = notification.request.content.userInfo["from"] as? String else { continue }

            let result = await addMissedCallFromNotification(remoteAddress: sipFrom, date: notification.date)

            if result == .failed {
                Log.general.failure("Failed to process missed call notification, keeping for retry")
            } else {
                processedIdentifiers.append(notification.request.identifier)
            }
        }

        if !processedIdentifiers.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: processedIdentifiers)
            Log.general.call("Removed \(processedIdentifiers.count) processed missed call notifications")
        }
    }
    #endif

    // MARK: - Statistics
    
    func getMissedCallCount() async -> Int {
        guard let context = modelContext else { return 0 }

        do {
            let predicate = #Predicate<CallHistoryEntry> { entry in
                entry.wasMissed == true
            }
            let descriptor = FetchDescriptor<CallHistoryEntry>(predicate: predicate)
            return try context.fetchCount(descriptor)
        } catch {
            Log.general.failure("Failed to count missed calls", error: error)
            return 0
        }
    }

    func getTotalCallDuration() async -> TimeInterval {
        guard let context = modelContext else { return 0 }

        do {
            // TODO: Optimize with aggregate query when SwiftData supports it
            let descriptor = FetchDescriptor<CallHistoryEntry>()
            let entries = try context.fetch(descriptor)
            return entries.reduce(0) { $0 + $1.duration }
        } catch {
            Log.general.failure("Failed to compute total call duration", error: error)
            return 0
        }
    }
}
