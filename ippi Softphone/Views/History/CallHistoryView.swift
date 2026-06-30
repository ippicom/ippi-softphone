//
//  CallHistoryView.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import SwiftUI

struct CallHistoryView: View {
    @State private var viewModel = CallHistoryViewModel()
    @State private var showClearAllConfirmation = false
    @Environment(\.scenePhase) private var scenePhase
    private let environment = AppEnvironment.shared
    
    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.entries.isEmpty {
                ContentUnavailableView(
                    String(localized: "history.empty.title"),
                    systemImage: "phone.badge.waveform",
                    description: Text("history.empty.description")
                )
            } else {
                List {
                    // Filter picker as list header
                    Section {
                        Picker(String(localized: "history.filter.all"), selection: $viewModel.selectedFilter) {
                            ForEach(CallHistoryViewModel.HistoryFilter.allCases, id: \.self) { filter in
                                Text(filterName(for: filter)).tag(filter)
                            }
                        }
                        .pickerStyle(.segmented)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                    }

                    if viewModel.filteredEntries.isEmpty {
                        // Filter has no results but other entries exist — show empty state with filter visible
                        Section {
                            ContentUnavailableView(
                                String(localized: "history.filter.empty.title"),
                                systemImage: "phone.badge.waveform",
                                description: Text("history.filter.empty.description")
                            )
                            .listRowBackground(Color.clear)
                        }
                    } else {
                        Section {
                            ForEach(viewModel.filteredEntries, id: \.uuid) { entry in
                                let info = viewModel.displayInfo(for: entry)
                                CallHistoryRowView(
                                    entry: entry,
                                    onCall: {
                                        Task {
                                            await viewModel.callBack(entry)
                                        }
                                    },
                                    contactName: info.contactName,
                                    formattedNumber: info.formattedNumber
                                )
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        Task {
                                            await viewModel.deleteEntry(entry)
                                        }
                                    } label: {
                                        Label(String(localized: "common.delete"), systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .background { AppBackgroundGradient() }
        .navigationTitle(String(localized: "history.title"))
        .searchable(text: $viewModel.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: String(localized: "history.search"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(role: .destructive) {
                        showClearAllConfirmation = true
                    } label: {
                        Label(String(localized: "history.clearall"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert(String(localized: "history.clearall"), isPresented: $showClearAllConfirmation) {
            Button(String(localized: "common.cancel"), role: .cancel) {}
            Button(String(localized: "history.clearall"), role: .destructive) {
                Task {
                    await viewModel.clearAll()
                }
            }
        } message: {
            Text("history.clearall.confirm")
        }
        .task {
            await viewModel.loadHistory()
        }
        .onChange(of: environment.activeCallCount) { oldCount, newCount in
            // Reload history when a call ends (count decreases to 0)
            if oldCount > 0 && newCount == 0 {
                Task {
                    // Small delay to ensure history entry is saved
                    try? await Task.sleep(for: .milliseconds(300))
                    await viewModel.loadHistory()
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task {
                    // Small delay to let processMissedCallNotifications() finish first
                    try? await Task.sleep(for: .milliseconds(500))
                    await viewModel.loadHistory()
                }
            }
        }
        .refreshable {
            await viewModel.loadHistory()
        }
    }
    
    private func filterName(for filter: CallHistoryViewModel.HistoryFilter) -> String {
        switch filter {
        case .all: return String(localized: "history.filter.all")
        case .missed: return String(localized: "history.filter.missed")
        case .incoming: return String(localized: "history.filter.incoming")
        case .outgoing: return String(localized: "history.filter.outgoing")
        }
    }
}

// MARK: - Call History Row

struct CallHistoryRowView: View {
    let entry: CallHistoryEntry
    let onCall: () -> Void
    
    // Pre-computed display info passed from parent to avoid recalculation
    let contactName: String?
    let formattedNumber: String
    
    var body: some View {
        Button(action: onCall) {
            HStack(spacing: 12) {
                // Direction icon
                Image(systemName: entry.callDirection.icon)
                    .foregroundStyle(iconColor)
                    .frame(width: 24)
                
                // Contact info
                VStack(alignment: .leading, spacing: 4) {
                    if let contactName = contactName {
                        // Contact found: show name + formatted number
                        Text(contactName)
                            .font(.body)
                            .fontWeight(entry.wasMissed ? .semibold : .regular)
                            .foregroundStyle(entry.wasMissed ? .red : .primary)
                        
                        Text(formattedNumber)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        // No contact: show formatted number only
                        Text(formattedNumber)
                            .font(.body)
                            .fontWeight(entry.wasMissed ? .semibold : .regular)
                            .foregroundStyle(entry.wasMissed ? .red : .primary)
                    }
                    
                    // Date and duration
                    HStack(spacing: 4) {
                        Text(entry.formattedDate)
                        
                        if entry.wasAnswered {
                            Text("•")
                            Text(entry.formattedDuration)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                // Phone icon indicator
                Image(systemName: "phone.fill")
                    .foregroundStyle(Color.ippiBlue)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    var iconColor: Color {
        if entry.wasMissed {
            return .red
        }
        return entry.callDirection == .incoming ? .green : .blue
    }
}

#Preview {
    CallHistoryView()
}
