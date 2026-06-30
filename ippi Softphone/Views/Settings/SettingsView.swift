//
//  SettingsView.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Appearance Mode

enum AppearanceMode: Int, CaseIterable {
    case system = 0
    case light = 1
    case dark = 2
    
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    
    var localizedName: String {
        switch self {
        case .system: return String(localized: "settings.appearance.auto")
        case .light: return String(localized: "settings.appearance.light")
        case .dark: return String(localized: "settings.appearance.dark")
        }
    }
}

// MARK: - Identifiable URL wrapper for sheet presentation

struct IdentifiableURL: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()
    @AppStorage("pushNotificationsEnabled") private var pushNotificationsEnabled = false
    @AppStorage("appearanceMode") private var appearanceMode: Int = AppearanceMode.system.rawValue
    @State private var logFileURL: IdentifiableURL?
    @State private var isExportingLogs = false
    @State private var showNotificationDeniedAlert = false
    @State private var showPushErrorAlert = false
    @State private var pushErrorMessage = ""
    @State private var isPushToggleLoading = false
    @State private var isNotificationDeniedBySystem = false
    
    @Environment(\.scenePhase) private var scenePhase

    // Debug mode state
    @State private var isDebugModeActive = LogFileManager.shared.isDebugMode
    @State private var debugModeTimeRemaining: TimeInterval? = LogFileManager.shared.debugModeTimeRemaining
    
    private var currentYear: String {
        String(Calendar.current.component(.year, from: Date()))
    }
    
    var body: some View {
        List {
            // Account Section
            Section("settings.account") {
                // Account status - tappable to toggle online/offline
                Button(action: {
                    Task { await viewModel.toggleConnection() }
                }) {
                    HStack {
                        Image(systemName: "person.circle.fill")
                            .font(.title)
                            .foregroundStyle(Color.ippiBlue)
                        
                        Text(viewModel.accountUsername)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        
                        Spacer()
                        
                        // Registration status
                        HStack(spacing: 4) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 8, height: 8)
                            
                            Text(registrationStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                
                // Change password button
                Button {
                    viewModel.showChangePassword = true
                } label: {
                    HStack {
                        Image(systemName: "key.fill")
                            .foregroundStyle(Color.ippiBlue)
                            .frame(width: 24)
                        Text("settings.password.change")
                    }
                }
            }
            
            // Notifications Section
            Section("settings.notifications") {
                Toggle(isOn: Binding(
                    get: { pushNotificationsEnabled && !isNotificationDeniedBySystem },
                    set: { newValue in
                        Task {
                            if newValue {
                                await enablePushNotifications()
                            } else {
                                await disablePushNotifications()
                            }
                        }
                    }
                )) {
                    HStack {
                        Image(systemName: "bell.fill")
                            .foregroundStyle(Color.ippiBlue)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("settings.push.enabled")
                            if isNotificationDeniedBySystem {
                                Text("settings.push.denied.hint")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        if isPushToggleLoading {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isPushToggleLoading || isNotificationDeniedBySystem)

                if isNotificationDeniedBySystem {
                    Button {
                        openSettings()
                    } label: {
                        HStack {
                            Image(systemName: "gear")
                                .foregroundStyle(Color.ippiBlue)
                                .frame(width: 24)
                            Text("settings.notifications.denied.openSettings")
                            Spacer()
                            Image(systemName: "arrow.up.forward")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            
            // Network Section
            Section("settings.network") {
                Toggle(isOn: Binding(
                    get: { viewModel.isSRTPEnabled },
                    set: { newValue in
                        Task { await viewModel.toggleEncryptedCalls(newValue) }
                    }
                )) {
                    HStack {
                        Image(systemName: "lock.shield")
                            .foregroundStyle(Color.ippiBlue)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("settings.srtp.enabled")
                            Text("settings.srtp.description")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(viewModel.isTogglingEncryption)

                Toggle(isOn: Binding(
                    get: { viewModel.isSTUNEnabled },
                    set: { viewModel.isSTUNEnabled = $0 }
                )) {
                    HStack {
                        Image(systemName: "network")
                            .foregroundStyle(Color.ippiBlue)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("settings.stun.enabled")
                            Text("settings.stun.description")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Appearance Section
            Section("settings.appearance") {
                Picker(selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.rawValue) { mode in
                        Text(mode.localizedName).tag(mode.rawValue)
                    }
                } label: {
                    HStack {
                        Image(systemName: "circle.lefthalf.filled")
                            .foregroundStyle(Color.ippiBlue)
                            .frame(width: 24)
                        Text("settings.appearance.mode")
                    }
                }
            }

            // Data Section
            Section("settings.data") {
                Button(role: .destructive) {
                    viewModel.showClearHistoryConfirmation = true
                } label: {
                    HStack {
                        Image(systemName: "trash")
                            .frame(width: 24)
                        Text("settings.clearhistory")
                    }
                }
            }
            
            // About Section - App name, version, website and copyright
            Section("settings.about") {
                // App name and version
                HStack(spacing: 12) {
                    Image("Logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 50, height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Constants.App.name)
                            .font(.headline)
                        Text("Version \(viewModel.appVersion)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                
                Link(destination: URL(string: "https://www.ippi.com")!) {
                    HStack {
                        Text("www.ippi.com")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(String(format: String(localized: "footer.copyright"), currentYear))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // Licenses
            Section {
                NavigationLink {
                    CreditsView()
                } label: {
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundStyle(Color.ippiBlue)
                            .frame(width: 24)
                        Text("settings.credits")
                    }
                }
            }

            // Debug and logs
            Section {
                // Debug logging mode button
                Button {
                    toggleDebugMode()
                } label: {
                    HStack {
                        Image(systemName: isDebugModeActive ? "ladybug.fill" : "ladybug")
                            .foregroundStyle(isDebugModeActive ? Color.orange : Color.ippiBlue)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("settings.debug.mode")
                            if isDebugModeActive, let remaining = debugModeTimeRemaining {
                                Text(String(format: String(localized: "settings.debug.expires"), formatTimeRemaining(remaining)))
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            } else {
                                Text("settings.debug.description")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        if isDebugModeActive {
                            Text("settings.debug.active")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                // Send diagnostic logs button
                Button {
                    exportLogs()
                } label: {
                    HStack {
                        Image(systemName: "doc.text")
                            .foregroundStyle(Color.ippiBlue)
                            .frame(width: 24)
                        Text("settings.logs.send")
                        Spacer()
                        if isExportingLogs {
                            ProgressView()
                        } else {
                            Image(systemName: "square.and.arrow.up")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(isExportingLogs)
            }

            // Logout Section
            Section {
                Button(role: .destructive) {
                    viewModel.showLogoutConfirmation = true
                } label: {
                    HStack {
                        Spacer()
                        Text("settings.logout")
                        Spacer()
                    }
                }
            }
        }
        .alert(String(localized: "history.clearall"), isPresented: $viewModel.showClearHistoryConfirmation) {
            Button(String(localized: "common.cancel"), role: .cancel) {}
            Button(String(localized: "history.clearall"), role: .destructive) {
                Task {
                    await viewModel.clearCallHistory()
                }
            }
        } message: {
            Text("settings.clearhistory.confirm")
        }
        .alert(String(localized: "settings.logout"), isPresented: $viewModel.showLogoutConfirmation) {
            Button(String(localized: "common.cancel"), role: .cancel) {}
            Button(String(localized: "settings.logout"), role: .destructive) {
                Task {
                    await viewModel.logout()
                }
            }
        } message: {
            Text("settings.logout.confirm")
        }
        .navigationTitle(String(localized: "settings.title"))
        #if os(iOS)
        .task {
            await syncNotificationStatus()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await syncNotificationStatus() }
            }
        }
        #endif
        .task(id: isDebugModeActive) {
            // Tick every 30s while debug mode is active to update "expires in X min"
            guard isDebugModeActive else { return }
            while !Task.isCancelled {
                debugModeTimeRemaining = LogFileManager.shared.debugModeTimeRemaining
                if debugModeTimeRemaining == nil {
                    isDebugModeActive = false
                    break
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .alert(String(localized: "settings.password.change"), isPresented: $viewModel.showChangePassword) {
            SecureField(String(localized: "settings.password.new"), text: $viewModel.newPassword)
            Button(String(localized: "common.cancel"), role: .cancel) {
                viewModel.cancelPasswordChange()
            }
            Button(String(localized: "settings.password.save")) {
                Task {
                    await viewModel.changePassword()
                }
            }
            .disabled(viewModel.newPassword.isEmpty)
        } message: {
            if let error = viewModel.passwordChangeError {
                Text(error)
            } else {
                Text("settings.password.message")
            }
        }
        #if os(iOS)
        .onChange(of: logFileURL) {
            guard let item = logFileURL else { return }
            presentShareSheet(for: item.url)
            logFileURL = nil
        }
        .alert(String(localized: "settings.notifications.denied.title"), isPresented: $showNotificationDeniedAlert) {
            Button(String(localized: "settings.notifications.denied.openSettings")) {
                openSettings()
            }
            Button(String(localized: "common.cancel"), role: .cancel) {}
        } message: {
            Text("settings.notifications.denied.message")
        }
        .alert(String(localized: "settings.push.error.title"), isPresented: $showPushErrorAlert) {
            Button(String(localized: "common.ok"), role: .cancel) {}
        } message: {
            Text(pushErrorMessage)
        }
        #endif
    }
    
    private var statusColor: Color {
        viewModel.registrationState.statusColor
    }

    private var registrationStatusText: String {
        viewModel.registrationState.localizedStatusText
    }
    
    private func exportLogs() {
        isExportingLogs = true
        
        // Run export on background thread to not block UI
        Task.detached {
            let url = await LogFileManager.shared.exportLogs()
            
            await MainActor.run {
                isExportingLogs = false
                
                if let url {
                    #if os(iOS)
                    logFileURL = IdentifiableURL(url: url)
                    #else
                    // macOS: Use NSSharingServicePicker
                    let picker = NSSharingServicePicker(items: [url])
                    if let window = NSApp.keyWindow,
                       let contentView = window.contentView {
                        picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
                    }
                    #endif
                }
            }
        }
    }
    
    #if os(iOS)
    /// Check iOS notification authorization and disable push toggle if denied
    private func syncNotificationStatus() async {
        let status = await AppEnvironment.shared.pushKitManager.checkNotificationStatus()
        let denied = (status == .denied)
        isNotificationDeniedBySystem = denied

        // Auto-disable push if iOS notifications were revoked
        if denied && pushNotificationsEnabled {
            await disablePushNotifications()
        }
    }

    private func showPushError(_ messageKey: String.LocalizationValue) {
        pushErrorMessage = String(localized: messageKey)
        showPushErrorAlert = true
    }

    private func enablePushNotifications() async {
        isPushToggleLoading = true
        defer { isPushToggleLoading = false }

        let result = await AppEnvironment.shared.enablePushNotifications()
        switch result {
        case .success:
            pushNotificationsEnabled = true
        case .notificationsDenied:
            pushNotificationsEnabled = false
            showNotificationDeniedAlert = true
        case .failed(let message):
            pushNotificationsEnabled = false
            pushErrorMessage = message
            showPushErrorAlert = true
        }
    }

    private func disablePushNotifications() async {
        isPushToggleLoading = true
        defer { isPushToggleLoading = false }

        let env = AppEnvironment.shared

        do {
            try await env.disablePushOnServer()
        } catch {
            Log.pushKit.failure("Failed to disable push on server", error: error)
            showPushError("settings.push.error.disable")
            return
        }

        env.pushKitManager.unregister()
        pushNotificationsEnabled = false
    }
    
    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    /// Present UIActivityViewController directly from root VC to avoid
    /// sandbox/Launch Services errors that occur when hosted inside a SwiftUI .sheet
    private func presentShareSheet(for url: URL) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = scene.keyWindow?.rootViewController else { return }
        // Walk to the topmost presented VC
        var presenter = rootVC
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // iPad requires popover anchor
        activityVC.popoverPresentationController?.sourceView = presenter.view
        activityVC.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
        activityVC.popoverPresentationController?.permittedArrowDirections = []
        presenter.present(activityVC, animated: true)
    }
    #endif
    
    // MARK: - Debug Mode
    
    private func toggleDebugMode() {
        if isDebugModeActive {
            LogFileManager.shared.disableDebugMode()
            isDebugModeActive = false
            debugModeTimeRemaining = nil
        } else {
            LogFileManager.shared.enableDebugMode()
            isDebugModeActive = true
            debugModeTimeRemaining = LogFileManager.shared.debugModeTimeRemaining
        }
    }
    
    private func formatTimeRemaining(_ seconds: TimeInterval) -> String {
        "\(max(1, Int(seconds) / 60)) min"
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
