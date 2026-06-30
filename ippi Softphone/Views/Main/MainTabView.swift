//
//  MainTabView.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import SwiftUI

struct MainTabView: View {
    @State private var selectedTab: Tab = .dialer
    @Environment(\.appEnvironment) private var environment
    
    // Reset to dialer tab when view appears (after login)
    init() {
        _selectedTab = State(initialValue: .dialer)
    }
    
    enum Tab: CaseIterable {
        case dialer
        case history
        case contacts
        case settings
        
        var icon: String {
            switch self {
            case .dialer: return "circle.grid.3x3.fill"
            case .history: return "clock.fill"
            case .contacts: return "person.crop.circle.fill"
            case .settings: return "gearshape.fill"
            }
        }
        
        var label: String {
            switch self {
            case .dialer: return String(localized: "tab.dialer")
            case .history: return String(localized: "tab.history")
            case .contacts: return String(localized: "tab.contacts")
            case .settings: return String(localized: "tab.settings")
            }
        }
    }
    
    var body: some View {
        TabView(selection: $selectedTab) {
            DialerView()
                .tabItem {
                    Label(Tab.dialer.label, systemImage: Tab.dialer.icon)
                }
                .tag(Tab.dialer)
            
            NavigationStack {
                CallHistoryView()
            }
            .tabItem {
                Label(Tab.history.label, systemImage: Tab.history.icon)
            }
            .tag(Tab.history)
            .badge(environment.unseenMissedCallCount)
            
            NavigationStack {
                ContactsListView()
            }
            .tabItem {
                Label(Tab.contacts.label, systemImage: Tab.contacts.icon)
            }
            .tag(Tab.contacts)
            
            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label(Tab.settings.label, systemImage: Tab.settings.icon)
            }
            .tag(Tab.settings)
        }
        .fullScreenCover(isPresented: hasActiveCallBinding) {
            ActiveCallView()
                .presentationBackground(Color.appGroupedBackground)
        }
        .onChange(of: selectedTab) { _, newTab in
            if newTab == .history {
                environment.unseenMissedCallCount = 0
            }
        }
        .onChange(of: environment.unseenMissedCallCount) { _, newCount in
            if selectedTab == .history && newCount > 0 {
                environment.unseenMissedCallCount = 0
            }
        }
        .onChange(of: environment.pendingNavigation) { _, target in
            guard let target else { return }
            switch target {
            case .history: selectedTab = .history
            }
            environment.pendingNavigation = nil
        }
    }
    
    private var hasActiveCallBinding: Binding<Bool> {
        Binding(
            get: { environment.activeCallCount > 0 },
            set: { _ in }
        )
    }
}

#Preview {
    MainTabView()
}
