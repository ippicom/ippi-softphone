//
//  PushKitManager.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

#if os(iOS)
import Foundation
import PushKit
import UIKit
import UserNotifications

@MainActor
final class PushKitManager: NSObject {
    // MARK: - Properties
    
    private var registry: PKPushRegistry?
    private(set) var voipToken: Data?
    private(set) var apnsToken: Data?
    
    /// Notification authorization status
    enum NotificationStatus {
        case notDetermined
        case authorized
        case denied
        case provisional
    }
    
    private(set) var notificationStatus: NotificationStatus = .notDetermined

    /// Called when a token is refreshed by the system — used to resync with backend
    var onTokenRefresh: ((_ voipToken: String, _ apnsToken: String?) -> Void)?
    
    // MARK: - Initialization
    
    override init() {
        super.init()
        Log.pushKit.success("PushKitManager initialized")
    }
    
    // MARK: - VoIP Push Registration
    
    func registerForVoIPPushes() {
        Log.pushKit.call("Registering for VoIP pushes")
        
        registry = PKPushRegistry(queue: .main)
        registry?.delegate = self
        registry?.desiredPushTypes = [.voIP]
    }
    
    // MARK: - APNs Standard Registration
    
    /// Map UNAuthorizationStatus to our NotificationStatus enum
    private func mapAuthorizationStatus(_ status: UNAuthorizationStatus) -> NotificationStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .denied: return .denied
        case .provisional: return .provisional
        case .ephemeral: return .authorized
        @unknown default: return .denied
        }
    }

    /// Request notification permission and register for APNs
    func registerForAPNs() async -> NotificationStatus {
        Log.pushKit.call("Registering for APNs standard notifications")

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        if settings.authorizationStatus == .notDetermined {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                notificationStatus = granted ? .authorized : .denied
                Log.pushKit.success("Notification permission: \(granted ? "granted" : "denied")")
            } catch {
                Log.pushKit.failure("Failed to request notification permission", error: error)
                notificationStatus = .denied
            }
        } else {
            notificationStatus = mapAuthorizationStatus(settings.authorizationStatus)
        }

        // Register for remote notifications to get APNs token (regardless of permission status)
        UIApplication.shared.registerForRemoteNotifications()

        return notificationStatus
    }

    /// Check current notification authorization status without requesting
    func checkNotificationStatus() async -> NotificationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = mapAuthorizationStatus(settings.authorizationStatus)
        return notificationStatus
    }
    
    /// Called by AppDelegate when APNs token is received
    func didRegisterForRemoteNotifications(deviceToken: Data) {
        let oldToken = apnsTokenString
        apnsToken = deviceToken
        Log.pushKit.success("Received APNs token")

        let newToken = Self.formatToken(deviceToken)
        let voipFallback = voipTokenString ?? UserDefaults.standard.string(forKey: "lastVoipToken")
        handleTokenUpdate(kind: "apns", oldTokenString: oldToken, newToken: newToken, counterpartToken: voipFallback)
    }
    
    /// Called by AppDelegate when APNs registration fails
    func didFailToRegisterForRemoteNotifications(error: Error) {
        Log.pushKit.failure("Failed to register for APNs", error: error)
        apnsToken = nil
    }
    
    func unregister() {
        Log.pushKit.call("Unregistering from VoIP pushes")
        registry?.desiredPushTypes = []
        registry = nil
        voipToken = nil
        
        UIApplication.shared.unregisterForRemoteNotifications()
        apnsToken = nil
    }
    
    // MARK: - Token Formatting

    private nonisolated static func formatToken(_ token: Data) -> String {
        token.map { String(format: "%02.2hhx", $0) }.joined()
    }

    var voipTokenString: String? {
        guard let token = voipToken else { return nil }
        return Self.formatToken(token)
    }

    var apnsTokenString: String? {
        guard let token = apnsToken else { return nil }
        return Self.formatToken(token)
    }

    // Legacy compatibility
    var pushToken: Data? { voipToken }
    var tokenString: String? { voipTokenString }

    // MARK: - Token Change Detection

    /// Persist a new token string and notify `onTokenRefresh` if the token changed.
    /// `kind` is "voip" or "apns" (used for UserDefaults key and logging).
    /// `counterpartToken` is the other token to pass alongside in the refresh callback.
    private func handleTokenUpdate(
        kind: String,
        oldTokenString: String?,
        newToken: String,
        counterpartToken: String?
    ) {
        let persistKey = kind == "voip" ? "lastVoipToken" : "lastApnsToken"
        let previousToken = oldTokenString ?? UserDefaults.standard.string(forKey: persistKey)
        UserDefaults.standard.set(newToken, forKey: persistKey)

        guard previousToken != nil, previousToken != newToken else { return }

        let voip = kind == "voip" ? newToken : counterpartToken
        let apns = kind == "apns" ? newToken : counterpartToken
        guard let voip else { return }

        Log.pushKit.call("\(kind.uppercased()) token changed — notifying for backend resync")
        onTokenRefresh?(voip, apns)
    }
}

// MARK: - PKPushRegistryDelegate

extension PushKitManager: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        
        let token = pushCredentials.token
        Log.pushKit.success("Received VoIP push token")
        
        Task { @MainActor in
            let oldToken = self.voipTokenString
            self.voipToken = token
            let newToken = Self.formatToken(token)
            let apnsFallback = self.apnsTokenString ?? UserDefaults.standard.string(forKey: "lastApnsToken")
            self.handleTokenUpdate(kind: "voip", oldTokenString: oldToken, newToken: newToken, counterpartToken: apnsFallback)
        }
    }
    
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        
        Log.pushKit.call("VoIP push token invalidated")
        
        Task { @MainActor in
            self.voipToken = nil
        }
    }
    
    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else {
            completion()
            return
        }
        
        Log.pushKit.call("Received VoIP push notification")
        
        let payloadDict = payload.dictionaryPayload as? [String: Any] ?? [:]
        
        Log.pushKit.debug("VoIP push payload: \(payloadDict)")
        
        // Parse payload to extract caller info.
        // "from" can be a SIP URI ("sip:06...@domain") or a plain number.
        let rawFrom = payloadDict["from"] as? String ?? payloadDict["caller"] as? String ?? "Unknown"
        let callerHandle = SIPAddressHelper.extractPhoneNumber(from: rawFrom)
        let pushCallerName = payloadDict["caller_name"] as? String ?? payloadDict["display_name"] as? String
        let pushCallId = payloadDict["callId"] as? String ?? payloadDict["call-id"] as? String

        // PKPushRegistry is configured with queue: .main, so this callback runs on the main thread.
        // Verify this assumption explicitly — if it ever changes, we crash here with a clear message
        // rather than a confusing assumeIsolated trap.
        dispatchPrecondition(condition: .onQueue(.main))

        let (isAppActive, isSIPRegistered, callKitManager, displayName, existingCallUUID) = MainActor.assumeIsolated {
            let env = AppEnvironment.shared

            // Resolve display name: local contact > push payload name > formatted number
            let name: String? = env.contactsService.findContactName(for: callerHandle)
                ?? pushCallerName
                ?? {
                    let formatted = PhoneNumberFormatter.format(callerHandle)
                    return formatted != callerHandle ? formatted : nil
                }()

            // Check if SIP already received this call (INVITE arrived before push)
            let existingUUID = env.sipManager.existingUUID(forCallId: pushCallId)

            return (
                UIApplication.shared.applicationState == .active,
                env.sipManager.registrationState == .registered,
                env.callKitManager,
                name,
                existingUUID
            )
        }

        // If app is in foreground and SIP is already registered, the INVITE will arrive
        // directly via the SIP connection — skip CallKit to keep our own UI and multi-call
        // management. Audio activation is handled directly in CallService.answer().
        if isAppActive && isSIPRegistered {
            Log.pushKit.call("App is active and SIP registered — skipping CallKit report, SIP will handle incoming call")
            completion()
            return
        }

        // Reuse existing UUID if SIP already resolved this call, otherwise generate new one.
        // Also check if there's already a pending call with the same callId (duplicate push)
        // to avoid overwriting the pending UUID with a new one.
        let existingPendingUUID: UUID? = MainActor.assumeIsolated {
            let env = AppEnvironment.shared
            if let pushCallId, pushCallId == env.pendingIncomingCallId, let pending = env.pendingIncomingCallUUID {
                return pending
            }
            return nil
        }
        let callUUID = existingCallUUID ?? existingPendingUUID ?? UUID()
        if existingCallUUID != nil {
            Log.pushKit.call("SIP call already exists for callId — reusing UUID: \(callUUID)")
        } else if existingPendingUUID != nil {
            Log.pushKit.call("Duplicate push for same callId — reusing pending UUID: \(callUUID)")
        }

        // Set pending call UUID SYNCHRONOUSLY (we're on main thread) so it's available
        // when the SIP INVITE arrives — avoids race condition with Task scheduling
        if existingCallUUID == nil && existingPendingUUID == nil {
            MainActor.assumeIsolated {
                AppEnvironment.shared.setPendingIncomingCall(uuid: callUUID, callId: pushCallId)
            }
        }

        // Tell AppEnvironment that CallKit is handling the ringtone for this specific call,
        // so we don't play our own foreground ringtone on top of CallKit's.
        MainActor.assumeIsolated {
            AppEnvironment.shared.callKitHandlingIncomingUUID = callUUID
        }

        // Report to CallKit IMMEDIATELY (required for PushKit or app will be terminated)
        callKitManager.reportIncomingCallSync(
            uuid: callUUID,
            handle: callerHandle,
            hasVideo: false,
            callerName: displayName
        ) { error in
            // Call completion AFTER CallKit has been notified
            completion()

            if error == nil {
                // Continue setup in background
                Task { @MainActor in
                    await AppEnvironment.shared.wakeUpForIncomingCall()
                }
            } else {
                Log.pushKit.failure("Failed to report incoming call to CallKit", error: error!)
            }
        }
    }
}
#endif
