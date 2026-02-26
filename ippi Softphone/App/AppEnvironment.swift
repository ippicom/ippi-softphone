//
//  AppEnvironment.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import Foundation
import SwiftUI
import CallKit
#if os(iOS)
import UIKit
import UserNotifications
import FirebaseCore
#endif

@MainActor
@Observable
final class AppEnvironment {
    // MARK: - Singleton
    static let shared = AppEnvironment()
    
    // MARK: - Managers
    let sipManager: SIPManager
    let callKitManager: CallKitManager
    let audioManager: AudioSessionManager
    #if os(iOS)
    let pushKitManager: PushKitManager
    let ringtonePlayer: RingtonePlayer
    #endif
    
    // MARK: - Services
    let callService: CallService
    let contactsService: ContactsService
    let callHistoryService: CallHistoryService
    #if os(iOS)
    let crashReporting: CrashReportingService
    #endif
    
    // MARK: - State
    var isLoggedIn: Bool = false
    var isInitializing: Bool = true  // True until splash screen phase is complete
    var needsOnboarding: Bool = false
    var currentAccount: Account?

    /// Navigation target set by notification tap — consumed by MainTabView/MainSidebarView
    var pendingNavigation: NavigationTarget?

    /// Unseen missed call count, synced to App Group storage and app badge.
    var unseenMissedCallCount: Int {
        didSet {
            Self.sharedDefaults?.set(unseenMissedCallCount, forKey: Self.badgeCountKey)
            #if os(iOS)
            UNUserNotificationCenter.current().setBadgeCount(unseenMissedCallCount) { error in
                if let error {
                    Log.general.failure("Failed to set badge count: \(error.localizedDescription)")
                }
            }
            #endif
        }
    }

    /// Shared UserDefaults for App Group (NSE + main app)
    private static let sharedDefaults = UserDefaults(suiteName: Constants.AppGroup.identifier)
    private static let badgeCountKey = "unseenMissedCallCount"
    
    // Multi-call support: array of active calls
    var activeCalls: [VoIPCall] = []
    
    /// The currently focused/foreground call (for UI display)
    var currentCall: VoIPCall? {
        // Return the call that is connected or most recently active
        activeCalls.first { $0.state == .connected } ??
        activeCalls.first { $0.state != .paused && $0.state != .ended } ??
        activeCalls.first
    }
    
    /// Legacy compatibility - returns the current call (read-only, use updateOrAddCall/removeCall to modify)
    var activeCall: VoIPCall? {
        currentCall
    }
    
    // Pending incoming call from PushKit (to sync with SIP via callId)
    #if os(iOS)
    private(set) var pendingIncomingCallUUID: UUID?
    private(set) var pendingIncomingCallId: String?

    /// UUID of the incoming call whose ringtone is handled by CallKit.
    /// Set by PushKitManager when CallKit reports the call, cleared after processing in handleCallStateChange.
    /// Per-call to avoid suppressing ringtone for a second incoming call arriving in foreground.
    var callKitHandlingIncomingUUID: UUID?
    #endif
    
    // MARK: - Call Waiters (continuation-based, replaces polling)

    /// Continuations waiting for a specific call UUID to appear
    private var callWaiters: [UUID: CheckedContinuation<VoIPCall?, Never>] = [:]

    /// Wait for a call with the given UUID to appear, with timeout.
    /// Returns immediately if the call already exists.
    func waitForCall(uuid: UUID, timeout: TimeInterval = 15) async -> VoIPCall? {
        // Check if already available
        if let existing = call(for: uuid) { return existing }

        // Register a continuation that handleCallStateChange will resume
        return await withCheckedContinuation { continuation in
            callWaiters[uuid] = continuation

            // Schedule timeout to avoid hanging forever
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self else { return }
                // If still waiting, resume with nil
                if let waiter = callWaiters.removeValue(forKey: uuid) {
                    Log.callKit.call("waitForCall timed out for UUID: \(uuid)")
                    waiter.resume(returning: nil)
                }
            }
        }
    }

    /// Resume any continuation waiting for a call with the given UUID
    private func notifyCallWaiters(for call: VoIPCall) {
        if let waiter = callWaiters.removeValue(forKey: call.uuid) {
            Log.callKit.notice("waitForCall resolved: uuid=\(call.uuid.uuidString.prefix(8))…, state=\(call.state.displayText)")
            waiter.resume(returning: call)
        } else if !callWaiters.isEmpty && call.state == .incoming {
            // UUID mismatch: an incoming call arrived but waiters expect a different UUID
            // (e.g. duplicate push created a different CallKit UUID).
            // Resume all waiters with nil immediately so the fallback in
            // handleAnswerCall can grab this call before it's destroyed.
            let waitingFor = callWaiters.keys.map { $0.uuidString.prefix(8) }.joined(separator: ", ")
            Log.callKit.call("Incoming call (uuid=\(call.uuid.uuidString.prefix(8))…) but waiters expect: [\(waitingFor)…] — resuming waiters for fallback")
            let staleWaiters = callWaiters
            callWaiters.removeAll()
            for (_, waiter) in staleWaiters {
                waiter.resume(returning: nil)
            }
        }
    }

    // MARK: - Multi-Call Management

    /// Add or update a call in the active calls list
    func updateOrAddCall(_ call: VoIPCall) {
        if let index = activeCalls.firstIndex(where: { $0.uuid == call.uuid }) {
            activeCalls[index] = call
        } else {
            activeCalls.append(call)
        }
        // Resume any continuation waiting for this call UUID
        notifyCallWaiters(for: call)
    }
    
    /// Remove a call from the active calls list
    func removeCall(uuid: UUID) {
        activeCalls.removeAll { $0.uuid == uuid }
    }
    
    /// Get a specific call by UUID
    func call(for uuid: UUID) -> VoIPCall? {
        activeCalls.first { $0.uuid == uuid }
    }
    
    /// Check if there's a call on hold
    var hasCallOnHold: Bool {
        activeCalls.contains { $0.isOnHold || $0.state == .paused }
    }
    
    /// Get the call that's on hold (if any)
    var heldCall: VoIPCall? {
        activeCalls.first { $0.isOnHold || $0.state == .paused }
    }
    
    /// Number of active calls
    var activeCallCount: Int {
        activeCalls.filter { $0.state != .ended && $0.state != .error }.count
    }
    
    // MARK: - Initialization
    
    private init() {
        // Configure Firebase before CrashReportingService accesses Crashlytics
        #if os(iOS)
        FirebaseApp.configure()
        self.crashReporting = CrashReportingService.shared
        #endif

        self.unseenMissedCallCount = Self.sharedDefaults?.integer(forKey: Self.badgeCountKey) ?? 0

        // Initialize managers
        self.sipManager = SIPManager()
        self.callKitManager = CallKitManager()
        self.audioManager = AudioSessionManager()
        #if os(iOS)
        self.pushKitManager = PushKitManager()
        self.ringtonePlayer = RingtonePlayer()
        #endif

        // Initialize services
        self.callService = CallService()
        self.contactsService = ContactsService()
        self.callHistoryService = CallHistoryService()
        
        // Setup connections between components
        setupConnections()

        #if os(iOS)
        setupPushTokenRefresh()
        #endif

        Log.general.success("AppEnvironment initialized")
    }
    
    // MARK: - Setup
    
    private func setupConnections() {
        // Connect CallKit to SIP manager
        callKitManager.delegate = callService
        
        // Connect SIP manager callbacks
        sipManager.onRegistrationStateChanged = { [weak self] state in
            self?.handleRegistrationStateChange(state)
        }

        sipManager.onCallStateChanged = { [weak self] call in
            self?.handleCallStateChange(call)
        }

        #if os(iOS)
        audioManager.onRouteChanged = { [weak self] route in
            self?.crashReporting.updateAudioRoute(route)
        }
        #endif
    }
    
    // MARK: - Registration

    /// Shared SIP registration: initialize, register, update account state
    private func registerWithCredentials(username: String, password: String, domain: String) throws {
        try sipManager.initialize()
        try sipManager.register(username: username, password: password, domain: domain)
        currentAccount = Account(username: username, domain: domain, registrationState: .progress)
        isLoggedIn = true
    }

    /// Pending credentials to save after registration succeeds
    private var pendingCredentials: StoredCredentials?

    func login(username: String, password: String) async throws {
        Log.general.call("Attempting login for \(username)")

        let domain = Constants.SIP.effectiveDomain

        // Store credentials temporarily — only persisted to Keychain after SIP auth succeeds
        pendingCredentials = StoredCredentials(username: username, password: password, domain: domain)

        // Initialize and register SIP, but DON'T set isLoggedIn yet —
        // LoginView must stay visible with spinner until registration completes.
        try sipManager.initialize()
        try sipManager.register(username: username, password: password, domain: domain)
        currentAccount = Account(username: username, domain: domain, registrationState: .progress)

        // Wait for SIP registration to complete (success or failure)
        var didRegister = false
        for _ in 0..<150 { // 200ms × 150 = 30s max
            let state = currentAccount?.registrationState
            if state == .registered {
                didRegister = true
                break
            }
            if state == .failed {
                throw SIPError.registrationFailed
            }
            try await Task.sleep(for: .milliseconds(200))
        }

        // If we timed out without confirmation, treat as failure
        if !didRegister {
            throw SIPError.registrationFailed
        }

        // Now transition: set onboarding flag BEFORE isLoggedIn so ContentView
        // goes directly to OnboardingView, not the dialer.
        #if os(iOS)
        needsOnboarding = true
        crashReporting.setUser(username)
        #endif
        isLoggedIn = true
    }
    
    func completeOnboarding() {
        needsOnboarding = false
    }

    func logout() async {
        Log.general.call("Logging out")

        // Disable push on server before losing credentials (best-effort: don't block logout)
        #if os(iOS)
        try? await disablePushOnServer()
        pushKitManager.unregister()
        UserDefaults.standard.set(false, forKey: "pushNotificationsEnabled")
        #endif

        // Full shutdown: waits for core to finish async tasks before continuing
        await sipManager.shutdownAsync()

        // Disable SRTP so next login starts unencrypted
        UserDefaults.standard.set(false, forKey: Constants.UserDefaultsKeys.srtpEnabled)

        // Delete credentials from Keychain
        try? KeychainService.shared.deleteCredentials()

        currentAccount = nil
        isLoggedIn = false

        #if os(iOS)
        crashReporting.setUser(nil)
        #endif
    }
    
    /// Toggle SIP connection: unregister if registered, or re-register with saved credentials
    func toggleConnection() throws {
        let state = currentAccount?.registrationState ?? .none
        if state == .registered {
            sipManager.unregister()
        } else if state == .none || state == .cleared || state == .failed {
            let credentials = try KeychainService.shared.getCredentials()
            try sipManager.register(
                username: credentials.username,
                password: credentials.password,
                domain: Constants.SIP.effectiveDomain
            )
        }
    }

    /// Try to restore session from saved credentials
    private var isRestoringSession = false
    
    /// Initialize app with splash screen: minimum 1.25s display, then go to login or dialer
    func initializeApp() async {
        Log.general.call("initializeApp() started")
        
        // Start timer for minimum splash duration
        let splashStart = Date()
        let minimumSplashDuration: TimeInterval = 1.25
        
        // Try to restore session
        await restoreSession()

        // Note: PushKit + APNs re-registration at launch is handled by ippi_SoftphoneApp.init()

        // Preload contacts for caller ID / history reconciliation
        await preloadContacts()
        
        // Ensure minimum splash duration
        let elapsed = Date().timeIntervalSince(splashStart)
        if elapsed < minimumSplashDuration {
            let remaining = minimumSplashDuration - elapsed
            try? await Task.sleep(for: .seconds(remaining))
        }
        
        #if os(iOS)
        await processPendingNotifications()
        #endif

        // Mark initialization complete - this will dismiss splash screen
        isInitializing = false
        Log.general.call("initializeApp() complete - isLoggedIn=\(isLoggedIn)")
    }
    
    /// Preload contacts phone index for caller ID (lightweight — no thumbnails)
    private func preloadContacts() async {
        // Only load if permission already granted (don't prompt during splash)
        guard contactsService.isAuthorized else {
            Log.contacts.call("Contacts not authorized, skipping preload")
            return
        }

        do {
            try await contactsService.preloadPhoneIndex()
        } catch {
            Log.contacts.failure("Failed to preload contacts phone index", error: error)
        }
    }
    
    func restoreSession() async {
        Log.general.call("restoreSession() called - isLoggedIn=\(isLoggedIn), registrationState=\(sipManager.registrationState.rawValue), isRestoringSession=\(isRestoringSession)")
        
        // Prevent multiple concurrent restore attempts
        guard !isRestoringSession else {
            Log.general.call("Session restore already in progress, skipping")
            return
        }
        
        // Skip if already logged in and actively registered (allow retry from idle/failed states)
        let state = sipManager.registrationState
        let needsRegistration = !isLoggedIn || state == .none || state == .cleared || state == .failed
        guard needsRegistration else {
            Log.general.call("Already logged in and registered, skipping restore")
            return
        }
        
        isRestoringSession = true
        defer { isRestoringSession = false }
        
        Log.general.call("Attempting to restore session - passed all guards")
        
        do {
            let credentials = try KeychainService.shared.getCredentials()
            Log.general.call("Retrieved credentials for: \(credentials.username)")

            try registerWithCredentials(
                username: credentials.username,
                password: credentials.password,
                domain: Constants.SIP.effectiveDomain
            )

            #if os(iOS)
            crashReporting.setUser(credentials.username)
            #endif

            Log.general.success("Session restored for \(credentials.username)")
        } catch KeychainError.itemNotFound {
            Log.general.call("No stored credentials found - showing login")
        } catch {
            Log.general.failure("Failed to restore session", error: error)
        }
    }
    
    // MARK: - Event Handlers
    
    private func handleRegistrationStateChange(_ state: SIPRegistrationState) {
        Log.sip.call("Registration state changed: \(state.rawValue)")
        currentAccount?.registrationState = state

        #if os(iOS)
        crashReporting.updateSIPState(state)
        if state == .failed {
            crashReporting.recordSIPError(
                NSError(domain: "SIP", code: -1, userInfo: [NSLocalizedDescriptionKey: "Registration failed"]),
                context: "registration"
            )
        }
        #endif

        // Persist credentials only after successful registration
        if state == .registered, let credentials = pendingCredentials {
            do {
                try KeychainService.shared.saveCredentials(credentials)
                Log.general.success("Credentials saved after successful registration")
            } catch {
                Log.general.failure("Failed to save credentials after registration", error: error)
            }
            pendingCredentials = nil
        } else if state == .failed, pendingCredentials != nil {
            Log.general.call("Clearing pending credentials after registration failure")
            pendingCredentials = nil
        }
    }
    
    private func handleCallStateChange(_ call: VoIPCall) {
        Log.sip.call("Call state changed: \(call.uuid) -> \(call.state.displayText)")
        
        switch call.state {
        case .connected:
            #if os(iOS)
            ringtonePlayer.stopRinging()
            #endif

            // Report to CallKit that outgoing call is now connected
            if call.direction == .outgoing {
                callKitManager.reportOutgoingCallConnected(uuid: call.uuid)
                Log.callKit.call("Reported outgoing call connected to CallKit: \(call.uuid)")
            }
            updateOrAddCall(call)
            
        case .ended, .error:
            #if os(iOS)
            ringtonePlayer.stopRinging()
            #endif

            // Report call ended to CallKit
            let reason: CXCallEndedReason = call.state == .error ? .failed : .remoteEnded
            callKitManager.reportCallEnded(uuid: call.uuid, reason: reason)
            Log.callKit.call("Reported call ended to CallKit: \(call.uuid)")

            #if os(iOS)
            if call.state == .error {
                crashReporting.recordCallError(
                    NSError(domain: "Call", code: -1, userInfo: [NSLocalizedDescriptionKey: "Call failed"]),
                    callUUID: call.uuid
                )
            }
            #endif

            // Save to history
            Task {
                await callHistoryService.addEntry(from: call)
            }

            // Remove from active calls
            removeCall(uuid: call.uuid)
            
            #if os(iOS)
            if activeCallCount == 0 {
                // Deactivate linphone audio and audio session when no more calls
                sipManager.activateAudioSession(false)
                try? audioManager.deactivateSession()

                // If app is in background, shut down SIP entirely — push will handle incoming calls
                if UIApplication.shared.applicationState == .background {
                    Log.general.call("All calls ended in background - shutting down SIP")
                    sipManager.shutdown()
                }
            }
            #endif
            
        case .incoming:
            updateOrAddCall(call)

            // Play our own ringtone in foreground when CallKit is not handling it
            #if os(iOS)
            let callKitHandlesThis = callKitHandlingIncomingUUID == call.uuid
            if callKitHandlesThis {
                callKitHandlingIncomingUUID = nil
            }
            if !callKitHandlesThis && UIApplication.shared.applicationState == .active {
                ringtonePlayer.startRinging()
            }
            #endif

        default:
            updateOrAddCall(call)
        }

        #if os(iOS)
        crashReporting.updateCallState(currentCall)
        crashReporting.updateCallCount(activeCallCount)
        #endif
    }
    
    #if os(iOS)
    /// Sync badge counter from shared storage (NSE may have incremented it).
    func syncBadgeFromSharedStorage() {
        let sharedCount = Self.sharedDefaults?.integer(forKey: Self.badgeCountKey) ?? 0
        if sharedCount != unseenMissedCallCount {
            Log.general.call("Syncing badge from shared storage: \(unseenMissedCallCount) → \(sharedCount)")
            unseenMissedCallCount = sharedCount
        }
    }

    /// Sync badge from shared storage and process delivered missed-call notifications into history.
    func processPendingNotifications() async {
        syncBadgeFromSharedStorage()
        await callHistoryService.processMissedCallNotifications()
    }

    /// Set pending incoming call info (from PushKit, before SIP call arrives)
    func setPendingIncomingCall(uuid: UUID, callId: String?) {
        Log.general.call("Setting pending incoming call UUID: \(uuid), callId: \(callId ?? "nil")")
        pendingIncomingCallUUID = uuid
        pendingIncomingCallId = callId
        sipManager.setPendingIncomingCall(uuid: uuid, callId: callId)
    }

    /// Clear pending incoming call info (after call is matched)
    func clearPendingIncomingCall() {
        pendingIncomingCallUUID = nil
        pendingIncomingCallId = nil
        sipManager.clearPendingIncomingCall()
    }
    
    // MARK: - Push Token Management

    /// Wire up callback to resync backend when iOS refreshes push tokens
    private func setupPushTokenRefresh() {
        pushKitManager.onTokenRefresh = { [weak self] voipToken, apnsToken in
            // Skip resync if APNs token unavailable — avoids overwriting valid token with empty string
            guard self != nil,
                  UserDefaults.standard.bool(forKey: "pushNotificationsEnabled"),
                  let credentials = try? KeychainService.shared.getCredentials(),
                  let apnsToken else {
                Log.pushKit.call("Token refresh skipped — push disabled, missing credentials, or APNs token unavailable")
                return
            }
            Task {
                do {
                    try await PushAPIService.shared.enablePush(
                        login: credentials.username,
                        password: credentials.password,
                        voipToken: voipToken,
                        standardToken: apnsToken
                    )
                    Log.pushKit.success("Push tokens resynced with server after refresh")
                } catch {
                    Log.pushKit.failure("Failed to resync push tokens after refresh", error: error)
                }
            }
        }
    }

    // MARK: - Push Notifications

    enum PushEnableResult {
        case success
        case notificationsDenied  // VoIP works but standard notifications denied
        case failed(String)
    }

    func enablePushNotifications() async -> PushEnableResult {
        // Register for VoIP pushes (no permission needed)
        pushKitManager.registerForVoIPPushes()

        // Request APNs standard notifications (shows permission dialog if not determined)
        let status = await pushKitManager.registerForAPNs()

        // Wait for both tokens (polling 200ms, max 10s)
        for _ in 0..<50 {
            if pushKitManager.voipTokenString != nil && pushKitManager.apnsTokenString != nil {
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }

        guard let voipToken = pushKitManager.voipTokenString,
              let standardToken = pushKitManager.apnsTokenString else {
            Log.pushKit.failure("Tokens not available after waiting")
            return .failed(String(localized: "settings.push.error.enable"))
        }

        // If notifications were denied, don't register push on server.
        // The user must first enable notifications in iOS Settings.
        if status == .denied {
            return .notificationsDenied
        }

        guard let credentials = try? KeychainService.shared.getCredentials() else {
            Log.pushKit.failure("Cannot read credentials for push registration")
            return .failed(String(localized: "settings.push.error.enable"))
        }

        do {
            try await PushAPIService.shared.enablePush(
                login: credentials.username,
                password: credentials.password,
                voipToken: voipToken,
                standardToken: standardToken
            )
            UserDefaults.standard.set(true, forKey: "pushNotificationsEnabled")
        } catch {
            Log.pushKit.failure("Failed to enable push on server", error: error)
            return .failed(String(localized: "settings.push.error.enable"))
        }

        return .success
    }

    /// Disable push on server. Throws on failure so callers can decide how to handle it.
    func disablePushOnServer() async throws {
        // Fall back to persisted token if PushKit was already unregistered (e.g. app restart)
        let voipToken = pushKitManager.voipTokenString
            ?? UserDefaults.standard.string(forKey: "lastVoipToken")
        guard let voipToken,
              let credentials = try? KeychainService.shared.getCredentials() else {
            Log.pushKit.warning("Cannot disable push on server — missing token or credentials")
            throw PushAPIError.missingTokenOrCredentials
        }
        try await PushAPIService.shared.disablePush(
            login: credentials.username,
            password: credentials.password,
            voipToken: voipToken
        )
        // Purge persisted tokens after successful server-side disable
        UserDefaults.standard.removeObject(forKey: "lastVoipToken")
        UserDefaults.standard.removeObject(forKey: "lastApnsToken")
    }

    /// Wake up SIP stack for incoming call (called from PushKit)
    func wakeUpForIncomingCall() async {
        Log.general.call("Waking up for incoming call (registrationState=\(sipManager.registrationState), isLoggedIn=\(isLoggedIn))")

        // If SIP is already initialized and registered, just refresh
        if sipManager.registrationState == .registered {
            sipManager.wakeUp()
            return
        }

        // If registration is already in progress (e.g. restoreSession or duplicate push),
        // don't create a second registration — that causes two parallel REGISTERs
        // which fight each other and both end up unregistering.
        // Check isInitialized (true after initialize(), false after shutdown()) to catch
        // the case where restoreSession already started registration but the async
        // registrationState callback hasn't fired yet.
        if sipManager.isInitialized || sipManager.registrationState == .progress {
            Log.general.call("SIP already initialized or registering — skipping duplicate wake-up")
            return
        }

        // Otherwise, need to re-initialize and register
        do {
            let credentials = try KeychainService.shared.getCredentials()

            try registerWithCredentials(
                username: credentials.username,
                password: credentials.password,
                domain: Constants.SIP.effectiveDomain
            )

            Log.general.success("SIP stack woken up for incoming call")
        } catch KeychainError.itemNotFound {
            Log.general.failure("No credentials available for incoming call")
        } catch {
            Log.general.failure("Failed to wake up SIP stack", error: error)
        }
    }
    #endif
}

// MARK: - Environment Key

private struct AppEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppEnvironment.shared
}

extension EnvironmentValues {
    var appEnvironment: AppEnvironment {
        get { self[AppEnvironmentKey.self] }
        set { self[AppEnvironmentKey.self] = newValue }
    }
}

// MARK: - Navigation Target

enum NavigationTarget: Equatable {
    case history
}
