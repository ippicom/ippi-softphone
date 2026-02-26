//
//  AudioSessionManager.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import Foundation
import AVFoundation

// MARK: - Audio Route

enum AudioRoute: String {
    case earpiece
    case speaker
    case bluetooth
    case headphones
    
    var icon: String {
        switch self {
        case .earpiece: return "ear"
        case .speaker: return "speaker.wave.3.fill"
        case .bluetooth: return "airpods"
        case .headphones: return "headphones"
        }
    }
}

// MARK: - Audio Session Manager

@MainActor
@Observable
final class AudioSessionManager {
    // MARK: - Properties
    
    private let audioSession = AVAudioSession.sharedInstance()
    private(set) var currentRoute: AudioRoute = .earpiece {
        didSet {
            if currentRoute != oldValue {
                onRouteChanged?(currentRoute)
            }
        }
    }
    private(set) var isConfigured: Bool = false

    /// Called when audio route changes (for crash reporting context)
    var onRouteChanged: ((AudioRoute) -> Void)?

    // Track user's explicit speaker preference (not system state)
    private var userWantsSpeaker: Bool = false

    private var notificationObservers: [Any] = []
    
    // MARK: - Initialization
    
    init() {
        setupNotifications()
        Log.audio.success("AudioSessionManager initialized")
    }
    
    // MARK: - Configuration
    
    func configureForVoIP() throws {
        Log.audio.call("Configuring audio session for VoIP")
        
        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetoothHFP, .allowBluetoothA2DP, .duckOthers]
            )
            
            try audioSession.setPreferredSampleRate(48000)
            try audioSession.setPreferredIOBufferDuration(0.02)
            
            isConfigured = true
            Log.audio.success("Audio session configured for VoIP")
        } catch {
            Log.audio.failure("Failed to configure audio session", error: error)
            throw error
        }
    }
    
    func activateSession() throws {
        Log.audio.call("Activating audio session")
        
        do {
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            updateCurrentRoute()
            Log.audio.success("Audio session activated")
        } catch {
            Log.audio.failure("Failed to activate audio session", error: error)
            throw error
        }
    }
    
    func deactivateSession() throws {
        Log.audio.call("Deactivating audio session")

        userWantsSpeaker = false
        currentRoute = .earpiece

        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            Log.audio.success("Audio session deactivated")
        } catch {
            Log.audio.failure("Failed to deactivate audio session", error: error)
            throw error
        }
    }
    
    // MARK: - Audio Routing
    
    func setAudioRoute(_ route: AudioRoute) {
        Log.audio.call("Setting audio route to: \(route.rawValue)")
        
        do {
            switch route {
            case .speaker:
                try audioSession.overrideOutputAudioPort(.speaker)
                userWantsSpeaker = true
            case .earpiece:
                try audioSession.overrideOutputAudioPort(.none)
                userWantsSpeaker = false
            case .bluetooth, .headphones:
                // These are handled automatically based on connected devices
                try audioSession.overrideOutputAudioPort(.none)
                userWantsSpeaker = false
            }
            
            currentRoute = route
            Log.audio.success("Audio route set to: \(route.rawValue)")
        } catch {
            Log.audio.failure("Failed to set audio route", error: error)
        }
    }
    
    func toggleSpeaker() {
        if userWantsSpeaker {
            setAudioRoute(.earpiece)
        } else {
            setAudioRoute(.speaker)
        }
    }
    
    var isSpeakerEnabled: Bool {
        userWantsSpeaker
    }
    
    // MARK: - Permissions
    
    func requestMicrophonePermission() async -> Bool {
        Log.audio.call("Requesting microphone permission")
        
        #if os(iOS)
        let granted = await AVAudioApplication.requestRecordPermission()
        if granted {
            Log.audio.success("Microphone permission granted")
        } else {
            Log.audio.failure("Microphone permission denied")
        }
        return granted
        #else
        // macOS doesn't require explicit permission request for microphone in the same way
        return true
        #endif
    }
    
    var hasMicrophonePermission: Bool {
        #if os(iOS)
        return AVAudioApplication.shared.recordPermission == .granted
        #else
        return true
        #endif
    }
    
    // MARK: - Available Inputs
    
    var availableInputs: [AVAudioSessionPortDescription] {
        audioSession.availableInputs ?? []
    }
    
    var availableRoutes: [AudioRoute] {
        var routes: [AudioRoute] = [.earpiece, .speaker]
        
        for input in availableInputs {
            switch input.portType {
            case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE:
                if !routes.contains(.bluetooth) {
                    routes.append(.bluetooth)
                }
            case .headphones, .headsetMic:
                if !routes.contains(.headphones) {
                    routes.append(.headphones)
                }
            default:
                break
            }
        }
        
        return routes
    }
    
    // MARK: - Private Methods
    
    private func setupNotifications() {
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.handleRouteChange(notification)
                }
            }
        )

        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.handleInterruption(notification)
                }
            }
        )
    }
    
    private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        Log.audio.call("Audio route changed: \(reason.rawValue)")
        updateCurrentRoute()
    }
    
    private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            Log.audio.call("Audio session interruption began")
        case .ended:
            Log.audio.call("Audio session interruption ended")
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    try? activateSession()
                }
            }
        @unknown default:
            break
        }
    }
    
    private func updateCurrentRoute() {
        let currentOutput = audioSession.currentRoute.outputs.first
        
        // Determine the actual system route
        let systemRoute: AudioRoute
        switch currentOutput?.portType {
        case .builtInSpeaker:
            systemRoute = .speaker
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE:
            systemRoute = .bluetooth
        case .headphones, .headsetMic:
            systemRoute = .headphones
        default:
            systemRoute = .earpiece
        }
        
        Log.audio.call("System route detected: \(systemRoute.rawValue), userWantsSpeaker: \(userWantsSpeaker)")
        
        // If user wants speaker but system switched away (e.g., during call swap),
        // reapply the speaker override
        if userWantsSpeaker && systemRoute != .speaker && systemRoute == .earpiece {
            Log.audio.call("Reapplying speaker override after route change")
            try? audioSession.overrideOutputAudioPort(.speaker)
            currentRoute = .speaker
        } else if !userWantsSpeaker && systemRoute == .speaker {
            // System somehow switched to speaker but user didn't want it
            Log.audio.call("System switched to speaker unexpectedly, reverting to earpiece")
            try? audioSession.overrideOutputAudioPort(.none)
            currentRoute = .earpiece
        } else {
            // Accept the system route (handles bluetooth/headphones correctly)
            currentRoute = systemRoute
        }
        
        Log.audio.call("Current route updated to: \(currentRoute.rawValue)")
    }
}
