//
//  ActiveCallViewModel.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import Foundation

@MainActor
@Observable
final class ActiveCallViewModel {
    // MARK: - Properties
    
    var showDTMFPad: Bool = false
    
    private let environment: AppEnvironment
    private var durationTask: Task<Void, Never>?
    private(set) var displayDuration: String = "00:00"

    // MARK: - Computed Properties

    var activeCall: VoIPCall? {
        environment.currentCall
    }

    var hasActiveCall: Bool {
        environment.activeCallCount > 0
    }

    /// Resolve display name for a call: contact name if found, otherwise formatted number
    private func displayName(for call: VoIPCall) -> String {
        let phone = call.cleanPhoneNumber
        return environment.contactsService.findContactName(for: phone)
            ?? PhoneNumberFormatter.format(phone)
    }

    /// Returns the contact name if found, or the formatted phone number
    var callerDisplay: String {
        guard let call = activeCall else { return "Unknown" }
        return displayName(for: call)
    }

    /// Returns the formatted phone number (shown below name when contact is found)
    var formattedPhoneNumber: String? {
        guard let call = activeCall else { return nil }
        let phoneNumber = call.cleanPhoneNumber
        // Only return formatted number if we found a contact (to show name + number)
        guard environment.contactsService.findContactName(for: phoneNumber) != nil else { return nil }
        return PhoneNumberFormatter.format(phoneNumber)
    }
    
    var callState: CallState {
        activeCall?.state ?? .idle
    }
    
    var callStateText: String {
        callState.displayText
    }
    
    var isMuted: Bool {
        activeCall?.isMuted ?? false
    }
    
    var isOnHold: Bool {
        activeCall?.isOnHold ?? false
    }
    
    var isSpeakerEnabled: Bool {
        environment.audioManager.isSpeakerEnabled
    }
    
    var isConnected: Bool {
        callState == .connected
    }
    
    var showControls: Bool {
        // Show controls when connected or on hold
        callState == .connected || callState == .paused || isOnHold
    }
    
    var isIncoming: Bool {
        callState == .incoming
    }
    
    // MARK: - Multi-Call Properties
    
    /// True if there are multiple active calls
    var hasMultipleCalls: Bool {
        environment.activeCallCount >= 2
    }
    
    /// True if there's a call on hold AND there are multiple calls (for swap banner)
    var hasCallOnHold: Bool {
        environment.activeCallCount >= 2 && environment.hasCallOnHold
    }
    
    /// The call that's currently on hold
    var heldCall: VoIPCall? {
        environment.heldCall
    }
    
    /// Display text for the held call (contact name or formatted number)
    var heldCallDisplay: String {
        guard let call = heldCall else { return "" }
        return displayName(for: call)
    }
    
    /// True if there's an incoming call waiting
    var hasIncomingWaiting: Bool {
        environment.activeCalls.contains { $0.state == .incoming && $0.uuid != activeCall?.uuid }
    }
    
    /// The waiting incoming call (if any)
    var incomingWaitingCall: VoIPCall? {
        environment.activeCalls.first { $0.state == .incoming && $0.uuid != activeCall?.uuid }
    }
    
    /// Display text for incoming waiting call (contact name or formatted number)
    var incomingWaitingDisplay: String {
        guard let call = incomingWaitingCall else { return "" }
        return displayName(for: call)
    }
    
    // MARK: - Initialization
    
    init() {
        self.environment = .shared
        startDurationTimer()
    }

    init(environment: AppEnvironment) {
        self.environment = environment
        startDurationTimer()
    }
    
    func cleanup() {
        durationTask?.cancel()
        durationTask = nil
    }
    
    // MARK: - Actions
    
    func toggleMute() async {
        do {
            try await environment.callService.toggleMute()
        } catch {
            Log.general.failure("Failed to toggle mute", error: error)
        }
    }
    
    func toggleHold() async {
        do {
            try await environment.callService.toggleHold()
        } catch {
            Log.general.failure("Failed to toggle hold", error: error)
        }
    }
    
    func toggleSpeaker() {
        environment.callService.toggleSpeaker()
    }
    
    func hangup() async {
        do {
            try await environment.callService.hangup()
        } catch {
            Log.general.failure("Failed to hang up", error: error)
        }
    }
    
    func answer() async {
        do {
            try await environment.callService.answer()
        } catch {
            Log.general.failure("Failed to answer", error: error)
        }
    }
    
    func sendDTMF(_ digit: Character) async {
        do {
            try await environment.callService.sendDTMF(digit)
        } catch {
            Log.general.failure("Failed to send DTMF", error: error)
        }
    }
    
    // MARK: - Multi-Call Actions
    
    /// Swap between current call and held call
    func swapCalls() async {
        do {
            try await environment.callService.swapCalls()
        } catch {
            Log.general.failure("Failed to swap calls", error: error)
        }
    }
    
    /// Answer incoming call and hold current
    func answerAndHoldCurrent() async {
        do {
            try await environment.callService.answerAndHoldCurrent()
        } catch {
            Log.general.failure("Failed to answer and hold", error: error)
        }
    }
    
    /// End current call and switch to held call
    func endAndSwitchToHeld() async {
        guard let currentCall = activeCall, let heldCall = heldCall else { return }
        
        do {
            // End current call
            try await environment.callService.hangup(uuid: currentCall.uuid)
            // Resume held call
            try await environment.callService.resumeCall(uuid: heldCall.uuid)
        } catch {
            Log.general.failure("Failed to end and switch", error: error)
        }
    }
    
    /// Decline incoming waiting call
    func declineIncomingWaiting() async {
        guard let incomingCall = incomingWaitingCall else { return }
        
        do {
            try await environment.callService.hangup(uuid: incomingCall.uuid)
        } catch {
            Log.general.failure("Failed to decline incoming", error: error)
        }
    }
    
    // MARK: - Private Methods
    
    private func startDurationTimer() {
        durationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                self?.updateDuration()
            }
        }
    }
    
    private func updateDuration() {
        guard let call = activeCall, call.state == .connected else {
            displayDuration = "00:00"
            return
        }
        
        displayDuration = call.formattedDuration
    }
}
