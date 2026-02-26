//
//  CallService.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import Foundation
import CallKit
import AVFoundation

// MARK: - Call Service Errors

enum CallServiceError: LocalizedError {
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return String(localized: "call.error.mic.denied")
        }
    }
}

@MainActor
final class CallService: CallKitActionDelegate {
    // MARK: - Properties
    
    private var sipManager: SIPManager { AppEnvironment.shared.sipManager }
    private var callKitManager: CallKitManager { AppEnvironment.shared.callKitManager }
    private var audioManager: AudioSessionManager { AppEnvironment.shared.audioManager }
    
    // Active call is stored in AppEnvironment
    private var activeCall: VoIPCall? { AppEnvironment.shared.activeCall }
    
    // Map CallKit UUIDs to calls
    private var pendingCalls: [UUID: String] = [:] // UUID to remote address

    // UUID remapping: CallKit UUID → SIP UUID.
    // When PushKit and SIP assign different UUIDs to the same call (race condition),
    // we answer using the SIP UUID and remap subsequent CallKit operations.
    private var callKitToSIPUUID: [UUID: UUID] = [:]

    /// Resolve CallKit UUID → SIP UUID (for incoming CallKit actions)
    private func resolveUUID(_ callKitUUID: UUID) -> UUID {
        callKitToSIPUUID[callKitUUID] ?? callKitUUID
    }

    /// Reverse lookup: SIP UUID → CallKit UUID (for outgoing CallKit requests)
    private func callKitUUID(for sipUUID: UUID) -> UUID {
        for (ckUUID, mappedSIPUUID) in callKitToSIPUUID where mappedSIPUUID == sipUUID {
            return ckUUID
        }
        return sipUUID // No remapping, UUIDs are the same
    }

    /// Format UUID resolution for logging (shows remapping only when it differs)
    private func uuidLogSuffix(_ original: UUID, _ resolved: UUID) -> String {
        resolved != original ? " → \(resolved)" : ""
    }
    
    // MARK: - Initialization
    
    init() {
        Log.general.success("CallService initialized")
    }
    
    // MARK: - Public Methods
    
    /// Dial a number and initiate an outgoing call
    func dial(_ number: String) async throws {
        Log.general.call("Dialing: \(number)")
        
        // Verify we're registered before attempting call
        guard sipManager.registrationState == .registered else {
            Log.general.failure("Cannot dial - not registered to SIP server")
            throw SIPError.notRegistered
        }
        
        // Check microphone permission before making call
        let micPermission = await checkMicrophonePermission()
        guard micPermission else {
            Log.general.failure("Microphone permission denied")
            throw CallServiceError.microphonePermissionDenied
        }
        
        // Generate UUID for this call
        let callUUID = UUID()
        
        // Store pending call info
        pendingCalls[callUUID] = number
        
        // Try to use CallKit for proper audio management
        do {
            Log.general.call("Starting outgoing call via CallKit")
            try await callKitManager.startOutgoingCall(uuid: callUUID, handle: number)
            // The actual SIP call will be made in handleStartCall delegate callback
        } catch {
            // CallKit failed (e.g., on simulator) - fallback to direct SIP call
            Log.callKit.failure("CallKit failed, falling back to direct SIP call", error: error)
            pendingCalls.removeValue(forKey: callUUID)
            
            // Configure and activate audio session manually
            try audioManager.configureForVoIP()
            try audioManager.activateSession()
            sipManager.configureAudioSession()
            sipManager.activateAudioSession(true)

            // Make SIP call directly
            _ = try sipManager.makeCall(to: number, uuid: callUUID)
        }
    }
    
    /// Check microphone permission
    private func checkMicrophonePermission() async -> Bool {
        #if os(iOS)
        let status = AVAudioApplication.shared.recordPermission
        
        switch status {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            return false
        }
        #else
        // macOS handles permissions differently
        return true
        #endif
    }
    
    /// Answer the current incoming call
    func answer() async throws {
        guard let call = AppEnvironment.shared.activeCall else {
            Log.general.failure("No active call to answer")
            return
        }

        Log.general.call("Answering call")

        // Stop foreground ringtone before activating audio
        #if os(iOS)
        AppEnvironment.shared.ringtonePlayer.stopRinging()
        #endif

        // Activate audio directly (foreground path, no CallKit)
        try audioManager.configureForVoIP()
        try audioManager.activateSession()
        sipManager.configureAudioSession()
        sipManager.activateAudioSession(true)
        try sipManager.answer(call: call)
    }
    
    /// Hang up the current call
    func hangup() async throws {
        guard let call = activeCall else {
            Log.general.failure("No active call to hang up")
            return
        }

        Log.general.call("Hanging up call")

        // Stop ringtone immediately if declining an incoming call
        #if os(iOS)
        if call.state == .incoming {
            AppEnvironment.shared.ringtonePlayer.stopRinging()
        }
        #endif

        // SIPManager will clear AppEnvironment.activeCall via callbacks
        try sipManager.hangup(call: call)
    }
    
    /// Toggle mute state
    func toggleMute() async throws {
        guard let call = activeCall else { return }
        
        let newMuteState = !call.isMuted
        Log.general.call("Toggling mute to: \(newMuteState)")
        sipManager.setMute(newMuteState, for: call)
    }
    
    /// Toggle hold state
    func toggleHold() async throws {
        guard let call = activeCall else { return }

        let newHoldState = !call.isOnHold
        Log.general.call("Toggling hold to: \(newHoldState)")

        do {
            try await callKitManager.setHeld(uuid: callKitUUID(for: call.uuid), onHold: newHoldState)
        } catch {
            try sipManager.setHold(newHoldState, for: call)
        }
    }
    
    /// Toggle speaker
    func toggleSpeaker() {
        audioManager.toggleSpeaker()
    }
    
    /// Send DTMF digit
    func sendDTMF(_ digit: Character) async throws {
        guard let call = activeCall else { return }
        
        Log.general.call("Sending DTMF: \(digit)")
        sipManager.sendDTMF(digit, for: call)
    }
    
    /// Transfer call to another number
    func transfer(to destination: String) throws {
        guard let call = activeCall else {
            throw SIPError.callNotFound
        }
        
        Log.general.call("Transferring call to: \(destination)")
        try sipManager.transfer(call: call, to: destination)
    }
    
    // MARK: - Multi-Call Support
    
    /// Swap between the current call and the held call (iOS-style call switching)
    func swapCalls() async throws {
        let environment = AppEnvironment.shared

        guard environment.activeCallCount >= 2 else {
            Log.general.failure("Cannot swap - need at least 2 active calls")
            return
        }

        guard let currentCall = environment.currentCall,
              let heldCall = environment.heldCall else {
            Log.general.failure("Cannot swap - missing current or held call")
            return
        }

        Log.general.call("Swapping calls: putting \(currentCall.uuid) on hold, resuming \(heldCall.uuid)")

        // Route through CallKit so both app UI and CallKit banner stay in sync.
        // Falls back to direct SIP for foreground-only calls (not managed by CallKit).
        do {
            try await callKitManager.setHeld(uuid: callKitUUID(for: currentCall.uuid), onHold: true)
            try await callKitManager.setHeld(uuid: callKitUUID(for: heldCall.uuid), onHold: false)
        } catch {
            Log.callKit.failure("CallKit swap failed, falling back to direct SIP", error: error)
            ensureAudioSessionActive()
            try sipManager.setHold(true, for: currentCall)
            try sipManager.setHold(false, for: heldCall)
        }
    }

    /// Hold a specific call by UUID
    func holdCall(uuid: UUID) async throws {
        guard let call = AppEnvironment.shared.call(for: uuid) else {
            throw SIPError.callNotFound
        }

        Log.general.call("Holding call: \(uuid)")

        do {
            try await callKitManager.setHeld(uuid: callKitUUID(for: uuid), onHold: true)
        } catch {
            try sipManager.setHold(true, for: call)
        }
    }

    /// Resume a specific call by UUID
    func resumeCall(uuid: UUID) async throws {
        guard let call = AppEnvironment.shared.call(for: uuid) else {
            throw SIPError.callNotFound
        }

        Log.general.call("Resuming call: \(uuid)")

        do {
            try await callKitManager.setHeld(uuid: callKitUUID(for: uuid), onHold: false)
        } catch {
            // CallKit failed — ensure audio session is active before resuming via direct SIP
            ensureAudioSessionActive()
            try sipManager.setHold(false, for: call)
        }
    }
    
    /// Hang up a specific call by UUID
    func hangup(uuid: UUID) async throws {
        guard let call = AppEnvironment.shared.call(for: uuid) else {
            Log.general.failure("No call found with UUID: \(uuid)")
            return
        }

        Log.general.call("Hanging up call: \(uuid)")

        // Stop ringtone immediately if declining an incoming call
        #if os(iOS)
        if call.state == .incoming {
            AppEnvironment.shared.ringtonePlayer.stopRinging()
        }
        #endif

        try sipManager.hangup(call: call)
    }
    
    /// Answer incoming call while holding current call
    func answerAndHoldCurrent() async throws {
        let environment = AppEnvironment.shared

        // Find incoming call
        guard let incomingCall = environment.activeCalls.first(where: { $0.state == .incoming }) else {
            Log.general.failure("No incoming call to answer")
            return
        }

        // Stop foreground ringtone
        #if os(iOS)
        environment.ringtonePlayer.stopRinging()
        #endif

        // Put current connected call on hold if exists
        if let currentCall = environment.activeCalls.first(where: { $0.state == .connected }) {
            Log.general.call("Putting current call on hold before answering")
            try sipManager.setHold(true, for: currentCall)
        }

        // Answer incoming call with direct audio activation (foreground path)
        Log.general.call("Answering incoming call")
        sipManager.configureAudioSession()
        sipManager.activateAudioSession(true)
        try sipManager.answer(call: incomingCall)
    }
    
    // MARK: - CallKitActionDelegate
    
    func handleStartCall(uuid: UUID, handle: String) async -> Bool {
        Log.callKit.call("Handling start call: \(handle)")
        
        defer {
            pendingCalls.removeValue(forKey: uuid)
        }
        
        do {
            // Configure audio for VoIP (CallKit will activate the session)
            try audioManager.configureForVoIP()
            sipManager.configureAudioSession()

            // Make the actual SIP call with the CallKit UUID
            _ = try sipManager.makeCall(to: handle, uuid: uuid)
            
            // Report that call started connecting
            callKitManager.reportOutgoingCallStarted(uuid: uuid)
            
            // Note: reportOutgoingCallConnected will be called when SIP reports Connected state
            // This is handled in AppEnvironment.handleCallStateChange
            return true
        } catch {
            Log.callKit.failure("Failed to start call", error: error)
            callKitManager.reportCallEnded(uuid: uuid, reason: .failed)
            return false
        }
    }
    
    func handleAnswerCall(uuid: UUID) async -> Bool {
        let environment = AppEnvironment.shared
        let resolvedUUID = resolveUUID(uuid)
        let existingCalls = environment.activeCalls.map { "(\($0.uuid.uuidString.prefix(8))…, state=\($0.state.displayText))" }.joined(separator: ", ")
        Log.callKit.call("Handling answer call: \(uuid)\(uuidLogSuffix(uuid, resolvedUUID)), activeCalls=[\(existingCalls)]")

        do {
            // 1. Try exact UUID match immediately
            var callToAnswer = environment.call(for: resolvedUUID)

            // 2. Immediate fallback: if UUID doesn't match (e.g. duplicate push created
            //    a different CallKit UUID), grab any single incoming call right away
            //    before waiting — the call could be destroyed by audio errors during the wait.
            if callToAnswer == nil {
                let incomingCalls = environment.activeCalls.filter { $0.state == .incoming }
                if incomingCalls.count == 1, let fallback = incomingCalls.first {
                    callToAnswer = fallback
                    if fallback.uuid != uuid {
                        callKitToSIPUUID[uuid] = fallback.uuid
                        Log.callKit.call("UUID fallback (immediate): CallKit \(uuid.uuidString.prefix(8))… → SIP \(fallback.uuid.uuidString.prefix(8))…")
                    }
                }
            }

            // 3. If no call yet, wait for SIP INVITE to arrive
            if callToAnswer == nil {
                callToAnswer = await environment.waitForCall(uuid: resolvedUUID)
            }

            // 4. Last resort fallback after wait
            if callToAnswer == nil {
                let incomingCalls = environment.activeCalls.filter { $0.state == .incoming }
                if incomingCalls.count == 1, let fallback = incomingCalls.first {
                    callToAnswer = fallback
                    if fallback.uuid != uuid {
                        callKitToSIPUUID[uuid] = fallback.uuid
                        Log.callKit.call("UUID fallback (post-wait): CallKit \(uuid.uuidString.prefix(8))… → SIP \(fallback.uuid.uuidString.prefix(8))…")
                    }
                }
            }

            guard let callToAnswer else {
                Log.callKit.failure("No call found for UUID after waiting: \(uuid)")
                return false
            }

            // If there's already a connected call, put it on hold first
            if let connectedCall = environment.activeCalls.first(where: { $0.state == .connected && $0.uuid != callToAnswer.uuid }) {
                Log.callKit.call("Putting existing call on hold before answering")
                try sipManager.setHold(true, for: connectedCall)
            }

            // Configure linphone audio proactively. The actual activateAudioSession
            // will be called later by handleAudioSessionActivated (CallKit's didActivate callback).
            sipManager.configureAudioSession()
            try sipManager.answer(call: callToAnswer)
            return true
        } catch {
            Log.callKit.failure("Failed to answer call", error: error)
            return false
        }
    }

    func handleEndCall(uuid: UUID) async -> Bool {
        let resolved = resolveUUID(uuid)
        let environment = AppEnvironment.shared
        let callList = environment.activeCalls.map { "(\($0.uuid.uuidString.prefix(8))…, state=\($0.state.displayText))" }.joined(separator: ", ")
        Log.callKit.call("Handling end call: \(uuid)\(uuidLogSuffix(uuid, resolved)), activeCalls=[\(callList)]")
        defer { callKitToSIPUUID.removeValue(forKey: uuid) }

        do {
            if let call = environment.call(for: resolved) {
                Log.callKit.call("Ending call: \(call.uuid.uuidString.prefix(8))… (state=\(call.state.displayText))")
                try sipManager.hangup(call: call)
                return true
            }
            Log.callKit.call("No call found for UUID \(resolved.uuidString.prefix(8))… — already ended or unknown")
            return true // No call to end is still a "success"
        } catch {
            Log.callKit.failure("Failed to end call", error: error)
            return false
        }
    }

    func handleSetHeld(uuid: UUID, onHold: Bool) async -> Bool {
        let resolved = resolveUUID(uuid)
        let environment = AppEnvironment.shared
        let callList = environment.activeCalls.map { "(\($0.uuid.uuidString.prefix(8))…, state=\($0.state.displayText))" }.joined(separator: ", ")
        Log.callKit.call("Handling set held: \(onHold) for \(uuid)\(uuidLogSuffix(uuid, resolved)), activeCalls=[\(callList)]")

        do {
            // 1. Try exact UUID match
            if let call = environment.call(for: resolved) {
                try sipManager.setHold(onHold, for: call)
                return true
            }

            // 2. Fallback: UUID mismatch (common with PushKit/SIP race conditions).
            //    Find the right call by its current state:
            //    - onHold=true → hold the connected call
            //    - onHold=false → resume the paused/held call
            let fallbackCall: VoIPCall?
            if onHold {
                fallbackCall = environment.activeCalls.first { $0.state == .connected }
            } else {
                fallbackCall = environment.activeCalls.first { $0.state == .paused || $0.isOnHold }
            }

            if let call = fallbackCall {
                callKitToSIPUUID[uuid] = call.uuid
                Log.callKit.call("UUID fallback for hold: CallKit \(uuid.uuidString.prefix(8))… → SIP \(call.uuid.uuidString.prefix(8))…")
                try sipManager.setHold(onHold, for: call)
                return true
            }

            Log.callKit.failure("No matching call found for set held (onHold=\(onHold))")
            return false
        } catch {
            Log.callKit.failure("Failed to set hold", error: error)
            return false
        }
    }

    func handleSetMuted(uuid: UUID, muted: Bool) async -> Bool {
        let resolved = resolveUUID(uuid)
        Log.callKit.call("Handling set muted: \(muted) for \(uuid)\(uuidLogSuffix(uuid, resolved))")

        if let call = AppEnvironment.shared.call(for: resolved) {
            sipManager.setMute(muted, for: call)
            return true
        }

        // Fallback: apply mute to the currently connected call
        if let call = AppEnvironment.shared.activeCalls.first(where: { $0.state == .connected }) {
            callKitToSIPUUID[uuid] = call.uuid
            Log.callKit.call("UUID fallback for mute: CallKit \(uuid.uuidString.prefix(8))… → SIP \(call.uuid.uuidString.prefix(8))…")
            sipManager.setMute(muted, for: call)
            return true
        }
        return false
    }

    func handlePlayDTMF(uuid: UUID, digits: String) async -> Bool {
        let resolved = resolveUUID(uuid)
        Log.callKit.call("Handling play DTMF: \(digits) for \(uuid)\(uuidLogSuffix(uuid, resolved))")

        if let call = AppEnvironment.shared.call(for: resolved) {
            for digit in digits {
                sipManager.sendDTMF(digit, for: call)
            }
            return true
        }
        return false
    }
    
    /// Ensure audio session is configured and active (for direct SIP fallback when CallKit is bypassed)
    private func ensureAudioSessionActive() {
        do {
            try audioManager.configureForVoIP()
            try audioManager.activateSession()
        } catch {
            Log.audio.failure("Failed to ensure audio session active", error: error)
        }
        sipManager.activateAudioSession(true)
    }

    func handleAudioSessionActivated() {
        Log.audio.call("Audio session activated by CallKit")

        do {
            try audioManager.configureForVoIP()
            try audioManager.activateSession()
        } catch {
            Log.audio.failure("Failed to configure audio", error: error)
        }

        // Notify linphone that audio is now available — this lets it start
        // the AudioUnit without !pri errors
        sipManager.activateAudioSession(true)
    }

    func handleAudioSessionDeactivated() {
        // Don't deactivate audio if there are still active calls (e.g. one ended but another is on hold)
        if AppEnvironment.shared.activeCallCount > 0 {
            Log.audio.call("Audio session deactivation skipped — still \(AppEnvironment.shared.activeCallCount) active call(s)")
            return
        }

        Log.audio.call("Audio session deactivated by CallKit")

        sipManager.activateAudioSession(false)

        do {
            try audioManager.deactivateSession()
        } catch {
            Log.audio.failure("Failed to deactivate audio", error: error)
        }
    }
    
    func handleProviderReset() {
        Log.callKit.call("Provider reset - ending all calls")

        let environment = AppEnvironment.shared

        #if os(iOS)
        environment.ringtonePlayer.stopRinging()
        #endif

        // Hang up all active SIP calls
        for call in environment.activeCalls {
            try? environment.sipManager.hangup(call: call)
        }
        environment.activeCalls.removeAll()

        // Deactivate audio session
        try? audioManager.deactivateSession()

        // Clear pending state
        pendingCalls.removeAll()
        callKitToSIPUUID.removeAll()
        #if os(iOS)
        environment.clearPendingIncomingCall()
        #endif
    }

}
