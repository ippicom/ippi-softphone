//
//  CallHistoryViewModel.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import Foundation

/// Cached display info for a call history entry
struct HistoryDisplayInfo {
    let contactName: String?
    let formattedNumber: String
}

@MainActor
@Observable
final class CallHistoryViewModel {
    // MARK: - Properties
    
    var entries: [CallHistoryEntry] = []
    var isLoading: Bool = false
    var selectedFilter: HistoryFilter = .all
    var searchText: String = ""
    
    /// Cache of display info keyed by entry UUID - computed once at load time
    private(set) var displayInfoCache: [UUID: HistoryDisplayInfo] = [:]
    
    private let environment: AppEnvironment

    /// Debounce: skip reload if one completed within this interval
    private var lastLoadTime: Date?
    private let minReloadInterval: TimeInterval = 0.5

    init() {
        self.environment = .shared
    }

    init(environment: AppEnvironment) {
        self.environment = environment
    }
    
    // MARK: - Filter
    
    enum HistoryFilter: CaseIterable {
        case all
        case missed
        case incoming
        case outgoing
    }
    
    // MARK: - Computed Properties
    
    var filteredEntries: [CallHistoryEntry] {
        var result = entries
        
        // Apply filter
        switch selectedFilter {
        case .all:
            break
        case .missed:
            result = result.filter { $0.wasMissed }
        case .incoming:
            result = result.filter { $0.callDirection == .incoming }
        case .outgoing:
            result = result.filter { $0.callDirection == .outgoing }
        }
        
        // Apply search
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            let queryDigits = searchText.filter { $0.isNumber }

            result = result.filter { entry in
                // Match on display name from call log
                if entry.displayName?.lowercased().contains(query) == true { return true }

                // Match on resolved contact name and formatted number from cache
                if let info = displayInfoCache[entry.uuid] {
                    if info.contactName?.lowercased().contains(query) == true { return true }
                    if info.formattedNumber.lowercased().contains(query) { return true }
                }

                // Match by phone number digits (handles 0x ↔ +33x variations)
                guard !queryDigits.isEmpty else { return false }
                let phoneDigits = entry.cleanPhoneNumber.filter { $0.isNumber }
                return phoneDigitsMatch(phoneDigits: phoneDigits, queryDigits: queryDigits)
            }
        }
        
        return result
    }
    
    var missedCallCount: Int {
        entries.filter { $0.wasMissed }.count
    }
    
    // MARK: - Display Info
    
    /// Get cached display info for an entry
    func displayInfo(for entry: CallHistoryEntry) -> HistoryDisplayInfo {
        displayInfoCache[entry.uuid] ?? HistoryDisplayInfo(
            contactName: nil,
            formattedNumber: entry.cleanPhoneNumber
        )
    }
    
    // MARK: - Actions
    
    func loadHistory(force: Bool = false) async {
        // Debounce: skip if recently loaded (prevents redundant fetches on foreground)
        if !force, let lastLoad = lastLoadTime,
           Date().timeIntervalSince(lastLoad) < minReloadInterval {
            return
        }

        isLoading = entries.isEmpty // Only show spinner on first load
        entries = await environment.callHistoryService.fetchHistory()

        // Pre-compute display info for all entries once
        buildDisplayInfoCache()

        lastLoadTime = Date()
        isLoading = false
    }
    
    /// Build display info cache - called once after loading entries
    private func buildDisplayInfoCache() {
        var cache: [UUID: HistoryDisplayInfo] = [:]
        let contactsService = environment.contactsService

        for entry in entries {
            let user = entry.cleanPhoneNumber
            if SIPAddressHelper.isPhoneNumber(user) {
                // Phone number → contact lookup + formatted number
                let info = contactsService.displayInfo(for: user)
                cache[entry.uuid] = HistoryDisplayInfo(
                    contactName: info.name,
                    formattedNumber: info.formattedNumber
                )
            } else {
                // Username → display with or without domain
                cache[entry.uuid] = HistoryDisplayInfo(
                    contactName: nil,
                    formattedNumber: SIPAddressHelper.displayableUser(from: entry.remoteAddress)
                )
            }
        }

        displayInfoCache = cache
    }
    
    /// Checks if phone digits match a digit query, handling national prefix conversion (0x ↔ +33x)
    private func phoneDigitsMatch(phoneDigits: String, queryDigits: String) -> Bool {
        if phoneDigits.contains(queryDigits) { return true }

        // Query "0633..." → "33633..." (national → international)
        if queryDigits.hasPrefix("0"), !queryDigits.hasPrefix("00") {
            let expanded = "33" + queryDigits.dropFirst()
            if phoneDigits.contains(expanded) { return true }
        }

        // Phone "0633..." → "33633..." (reverse)
        if phoneDigits.hasPrefix("0"), !phoneDigits.hasPrefix("00") {
            let phoneExpanded = "33" + phoneDigits.dropFirst()
            if phoneExpanded.contains(queryDigits) { return true }
        }

        // Query "0033633..." → "33633..."
        if queryDigits.hasPrefix("00") {
            let stripped = String(queryDigits.dropFirst(2))
            if phoneDigits.contains(stripped) { return true }
        }

        return false
    }

    func deleteEntry(_ entry: CallHistoryEntry) async {
        await environment.callHistoryService.deleteEntry(entry)
        entries.removeAll { $0.uuid == entry.uuid }
    }
    
    func clearAll() async {
        await environment.callHistoryService.clearAll()
        entries = []
    }
    
    func callBack(_ entry: CallHistoryEntry) async {
        do {
            let dialAddress = SIPAddressHelper.extractDialableAddress(from: entry.remoteAddress)
            // Phone numbers need E.164 normalization; usernames (with @) are ready as-is
            let destination = dialAddress.contains("@")
                ? dialAddress
                : PhoneNumberFormatter.normalize(dialAddress)
            try await environment.callService.dial(destination)
        } catch {
            Log.general.failure("Failed to call back", error: error)
        }
    }
}
