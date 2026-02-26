//
//  CallKitManager.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import Foundation
import CallKit
import AVFoundation
#if os(iOS)
import UIKit
#endif

// MARK: - CallKit Action Delegate

protocol CallKitActionDelegate: AnyObject {
    func handleStartCall(uuid: UUID, handle: String) async -> Bool
    func handleAnswerCall(uuid: UUID) async -> Bool
    func handleEndCall(uuid: UUID) async -> Bool
    func handleSetHeld(uuid: UUID, onHold: Bool) async -> Bool
    func handleSetMuted(uuid: UUID, muted: Bool) async -> Bool
    func handlePlayDTMF(uuid: UUID, digits: String) async -> Bool
    func handleAudioSessionActivated()
    func handleAudioSessionDeactivated()
    func handleProviderReset()
}

// MARK: - CallKit Manager

@MainActor
final class CallKitManager: NSObject {
    // MARK: - Properties
    
    // nonisolated(unsafe): CXProvider.reportNewIncomingCall is thread-safe
    // and must be callable from PushKit's nonisolated callback
    nonisolated(unsafe) private let provider: CXProvider
    private let callController: CXCallController
    weak var delegate: CallKitActionDelegate?
    
    // MARK: - Initialization
    
    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = Constants.CallKit.supportsVideo
        config.supportedHandleTypes = [.phoneNumber, .generic]
        config.maximumCallsPerCallGroup = Constants.CallKit.maximumCallsPerCallGroup
        config.includesCallsInRecents = true
        // CallKit icon: disabled for now — template rendering causes dark background
        // on lock screen. Leaving iOS to use the default AppIcon instead.
        // #if os(iOS)
        // if let iconImage = UIImage(named: "CallKitIcon") {
        //     config.iconTemplateImageData = iconImage.pngData()
        // }
        // #endif
        
        provider = CXProvider(configuration: config)
        callController = CXCallController()
        
        super.init()
        
        provider.setDelegate(self, queue: nil)
        Log.callKit.success("CallKitManager initialized")
    }
    
    // MARK: - Public Methods

    /// Build a CXCallUpdate with correct capabilities for our audio-only VoIP calls
    private nonisolated static func makeCallUpdate(handle: String, hasVideo: Bool, callerName: String?) -> CXCallUpdate {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .phoneNumber, value: handle)
        update.hasVideo = hasVideo
        update.localizedCallerName = callerName
        update.supportsHolding = true      // Required for swap between calls
        update.supportsGrouping = false    // No conference/merge
        update.supportsUngrouping = false  // No ungroup
        update.supportsDTMF = true
        return update
    }

    /// Report an incoming call to the system (async version)
    func reportIncomingCall(uuid: UUID, handle: String, hasVideo: Bool, callerName: String? = nil) async throws {
        Log.callKit.call("Reporting incoming call: \(handle)")

        let update = Self.makeCallUpdate(handle: handle, hasVideo: hasVideo, callerName: callerName)

        try await provider.reportNewIncomingCall(with: uuid, update: update)
        Log.callKit.success("Incoming call reported successfully")
    }

    /// Report an incoming call to the system (synchronous version for PushKit)
    /// CRITICAL: PushKit requires this to be called synchronously before the push callback returns
    nonisolated func reportIncomingCallSync(
        uuid: UUID,
        handle: String,
        hasVideo: Bool,
        callerName: String? = nil,
        completion: @escaping (Error?) -> Void
    ) {
        Log.callKit.call("Reporting incoming call (sync): \(handle)")

        let update = Self.makeCallUpdate(handle: handle, hasVideo: hasVideo, callerName: callerName)

        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error = error {
                Log.callKit.failure("Failed to report incoming call", error: error)
            } else {
                Log.callKit.success("Incoming call reported successfully (sync)")
            }
            completion(error)
        }
    }
    
    /// Request to start an outgoing call
    func startOutgoingCall(uuid: UUID, handle: String, hasVideo: Bool = false) async throws {
        Log.callKit.call("Starting outgoing call to: \(handle)")
        
        let cxHandle = CXHandle(type: .phoneNumber, value: handle)
        let startCallAction = CXStartCallAction(call: uuid, handle: cxHandle)
        startCallAction.isVideo = hasVideo
        
        let transaction = CXTransaction(action: startCallAction)
        try await callController.request(transaction)
        
        Log.callKit.success("Outgoing call request sent")
    }
    
    /// Report that an outgoing call started connecting
    func reportOutgoingCallStarted(uuid: UUID) {
        Log.callKit.call("Reporting outgoing call started connecting")
        provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())

        // CXStartCallAction doesn't carry capabilities — update separately
        let update = Self.makeCallUpdate(handle: "", hasVideo: false, callerName: nil)
        provider.reportCall(with: uuid, updated: update)
    }
    
    /// Report that an outgoing call connected
    func reportOutgoingCallConnected(uuid: UUID) {
        Log.callKit.call("Reporting outgoing call connected")
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }
    
    /// Report that a call ended
    func reportCallEnded(uuid: UUID, reason: CXCallEndedReason) {
        Log.callKit.call("Reporting call ended with reason: \(reason.rawValue)")
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
    }
    
    /// Request to end a call
    func endCall(uuid: UUID) async throws {
        Log.callKit.call("Requesting to end call")
        let endCallAction = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: endCallAction)
        try await callController.request(transaction)
    }
    
    /// Request to hold/unhold a call
    func setHeld(uuid: UUID, onHold: Bool) async throws {
        Log.callKit.call("Requesting to set call hold: \(onHold)")
        let setHeldAction = CXSetHeldCallAction(call: uuid, onHold: onHold)
        let transaction = CXTransaction(action: setHeldAction)
        try await callController.request(transaction)
    }
    
    /// Request to mute/unmute a call
    func setMuted(uuid: UUID, muted: Bool) async throws {
        Log.callKit.call("Requesting to set call mute: \(muted)")
        let setMutedAction = CXSetMutedCallAction(call: uuid, muted: muted)
        let transaction = CXTransaction(action: setMutedAction)
        try await callController.request(transaction)
    }
    
    /// Send DTMF tones
    func sendDTMF(uuid: UUID, digits: String) async throws {
        Log.callKit.call("Requesting to send DTMF: \(digits)")
        let playDTMFAction = CXPlayDTMFCallAction(call: uuid, digits: digits, type: .singleTone)
        let transaction = CXTransaction(action: playDTMFAction)
        try await callController.request(transaction)
    }
}

// MARK: - CXProviderDelegate

extension CallKitManager: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Log.callKit.call("Provider did reset")
        Task { @MainActor in
            delegate?.handleProviderReset()
        }
    }
    
    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Log.callKit.call("Performing start call action")
        Task { @MainActor in
            let success = await delegate?.handleStartCall(uuid: action.callUUID, handle: action.handle.value) ?? false
            if success {
                action.fulfill()
            } else {
                action.fail()
            }
        }
    }
    
    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Log.callKit.call("Performing answer call action")
        Task { @MainActor in
            let success = await delegate?.handleAnswerCall(uuid: action.callUUID) ?? false
            if success {
                action.fulfill()
            } else {
                action.fail()
            }
        }
    }
    
    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Log.callKit.call("Performing end call action")
        Task { @MainActor in
            let success = await delegate?.handleEndCall(uuid: action.callUUID) ?? false
            if success {
                action.fulfill()
            } else {
                action.fail()
            }
        }
    }
    
    nonisolated func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        Log.callKit.call("Performing set held action: \(action.isOnHold)")
        Task { @MainActor in
            let success = await delegate?.handleSetHeld(uuid: action.callUUID, onHold: action.isOnHold) ?? false
            if success {
                action.fulfill()
            } else {
                action.fail()
            }
        }
    }
    
    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Log.callKit.call("Performing set muted action: \(action.isMuted)")
        Task { @MainActor in
            let success = await delegate?.handleSetMuted(uuid: action.callUUID, muted: action.isMuted) ?? false
            if success {
                action.fulfill()
            } else {
                action.fail()
            }
        }
    }
    
    nonisolated func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        Log.callKit.call("Performing play DTMF action: \(action.digits)")
        Task { @MainActor in
            let success = await delegate?.handlePlayDTMF(uuid: action.callUUID, digits: action.digits) ?? false
            if success {
                action.fulfill()
            } else {
                action.fail()
            }
        }
    }
    
    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Log.callKit.call("Audio session activated")
        Task { @MainActor in
            delegate?.handleAudioSessionActivated()
        }
    }
    
    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Log.callKit.call("Audio session deactivated")
        Task { @MainActor in
            delegate?.handleAudioSessionDeactivated()
        }
    }
}
