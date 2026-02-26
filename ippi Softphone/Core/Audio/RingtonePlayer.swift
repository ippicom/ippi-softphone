//
//  RingtonePlayer.swift
//  ippi Softphone
//
//  Created by ippi on 26/02/2026.
//

#if os(iOS)
import AudioToolbox
import AVFoundation

/// Plays a ringtone + vibration for incoming calls in foreground (when CallKit is not handling it)
@MainActor
final class RingtonePlayer {
    private var isRinging = false

    // nonisolated(unsafe): written once in init, read-only thereafter.
    // Safe to access from deinit (which is nonisolated in Swift 6).
    private nonisolated(unsafe) var soundID: SystemSoundID = 0
    private nonisolated(unsafe) var usingBundledSound = false

    /// System tri-tone sound (SMS received) — used as fallback when no bundled ringtone is available
    private static let systemTriToneSoundID: SystemSoundID = 1007

    init() {
        loadRingtoneSound()
    }

    // MARK: - Sound Loading

    private func loadRingtoneSound() {
        // Try bundled ringtone file (Constants.Audio.defaultRingtone = "ringtone")
        let extensions = ["caf", "wav", "m4r", "mp3", "m4a", "aiff"]
        for ext in extensions {
            if let url = Bundle.main.url(forResource: Constants.Audio.defaultRingtone, withExtension: ext) {
                var id: SystemSoundID = 0
                let status = AudioServicesCreateSystemSoundID(url as CFURL, &id)
                if status == kAudioServicesNoError {
                    soundID = id
                    usingBundledSound = true
                    Log.audio.success("Loaded bundled ringtone: \(Constants.Audio.defaultRingtone).\(ext)")
                    return
                }
            }
        }
        Log.audio.call("No bundled ringtone found, using system alert fallback")
    }

    // MARK: - Public API

    func startRinging() {
        guard !isRinging else { return }
        isRinging = true
        Log.audio.call("Starting foreground ringtone")
        ringCycle()
    }

    func stopRinging() {
        guard isRinging else { return }
        isRinging = false
        Log.audio.call("Stopping foreground ringtone")
    }

    // MARK: - Ring Loop

    private func ringCycle() {
        guard isRinging else { return }

        // Vibrate
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)

        // Play sound: bundled ringtone or system tri-tone as fallback
        let playID = usingBundledSound ? soundID : Self.systemTriToneSoundID
        AudioServicesPlaySystemSoundWithCompletion(playID) { [weak self] in
            // Completion runs on an arbitrary AudioToolbox thread — bounce to MainActor safely
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                self?.ringCycle()
            }
        }
    }

    deinit {
        if usingBundledSound {
            AudioServicesDisposeSystemSoundID(soundID)
        }
    }
}
#endif
