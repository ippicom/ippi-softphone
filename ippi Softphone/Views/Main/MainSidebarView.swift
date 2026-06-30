//
//  MainSidebarView.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import SwiftUI

struct MainSidebarView: View {
    @State private var selectedSection: SidebarSection? = .dialer
    @Environment(\.appEnvironment) private var environment
    
    enum SidebarSection: String, CaseIterable, Identifiable {
        case dialer
        case history
        case contacts
        case settings

        var id: String { rawValue }

        var localizedName: String {
            switch self {
            case .dialer: return String(localized: "Keypad")
            case .history: return String(localized: "Recent")
            case .contacts: return String(localized: "Contacts")
            case .settings: return String(localized: "Settings")
            }
        }

        var icon: String {
            switch self {
            case .dialer: return "circle.grid.3x3.fill"
            case .history: return "clock.fill"
            case .contacts: return "person.crop.circle.fill"
            case .settings: return "gearshape.fill"
            }
        }
    }
    
    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                Section {
                    ForEach(SidebarSection.allCases) { section in
                        NavigationLink(value: section) {
                            Label(section.localizedName, systemImage: section.icon)
                        }
                        .badge(section == .history ? environment.unseenMissedCallCount : 0)
                    }
                }
                
                // Registration status at bottom
                Section {
                    SidebarStatusView(state: environment.currentAccount?.registrationState ?? .none)
                }
            }
            .navigationTitle("ippi")
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            #endif
        } detail: {
            if let section = selectedSection {
                detailView(for: section)
            } else {
                Text(String(localized: "Select a section"))
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: hasActiveCallBinding) {
            ActiveCallView()
        }
        .onChange(of: selectedSection) { _, newSection in
            if newSection == .history {
                environment.unseenMissedCallCount = 0
            }
        }
        .onChange(of: environment.unseenMissedCallCount) { _, newCount in
            if selectedSection == .history && newCount > 0 {
                environment.unseenMissedCallCount = 0
            }
        }
        .onChange(of: environment.pendingNavigation) { _, target in
            guard let target else { return }
            switch target {
            case .history: selectedSection = .history
            }
            environment.pendingNavigation = nil
        }
    }
    
    @ViewBuilder
    private func detailView(for section: SidebarSection) -> some View {
        switch section {
        case .dialer:
            DialerView()
        case .history:
            CallHistoryView()
        case .contacts:
            ContactsListView()
        case .settings:
            SettingsView()
        }
    }
    
    private var hasActiveCallBinding: Binding<Bool> {
        Binding(
            get: { environment.activeCallCount > 0 },
            set: { _ in }
        )
    }
}

// MARK: - Sidebar Status View

struct SidebarStatusView: View {
    let state: SIPRegistrationState
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
            
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    
    var stateColor: Color {
        switch state {
        case .registered: return .green
        case .progress: return .orange
        case .failed: return .red
        default: return .gray
        }
    }
    
    var statusText: String {
        switch state {
        case .registered: return String(localized: "Online")
        case .progress: return String(localized: "Connecting...")
        case .failed: return String(localized: "Failed")
        case .cleared, .none: return String(localized: "Offline")
        }
    }
}

#Preview {
    MainSidebarView()
}
