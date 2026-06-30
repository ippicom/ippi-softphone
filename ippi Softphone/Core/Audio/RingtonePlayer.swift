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
    private var audioPlayer: AVAudioPlayer?
    private var ringtoneURL: URL?
    private var vibrationTask: Task<Void, Never>?

    /// System tri-tone sound (SMS received) — used as fallback when no bundled ringtone is available
    private static let systemTriToneSoundID: SystemSoundID = 1007

    init() {
        loadRingtoneSound()
    }

    // MARK: - Sound Loading

    private func loadRingtoneSound() {
        let extensions = ["caf", "wav", "m4r", "mp3", "m4a", "aiff"]
        for ext in extensions {
            if let url = Bundle.main.url(forResource: Constants.Audio.defaultRingtone, withExtension: ext) {
                ringtoneURL = url
                Log.audio.success("Loaded bundled ringtone: \(Constants.Audio.defaultRingtone).\(ext)")
                return
            }
        }
        Log.audio.call("No bundled ringtone found, using system tri-tone fallback")
    }

    // MARK: - Public API

    func startRinging() {
        guard !isRinging else { return }
        isRinging = true
        Log.audio.call("Starting foreground ringtone")
        startAudioPlayer()
        ringCycle()
    }

    func stopRinging() {
        guard isRinging else { return }
        isRinging = false
        audioPlayer?.stop()
        audioPlayer = nil
        vibrationTask?.cancel()
        vibrationTask = nil
        Log.audio.call("Stopping foreground ringtone")
    }

    // MARK: - Audio Player

    private func startAudioPlayer() {
        guard let url = ringtoneURL else { return }

        do {
            // Activate a lightweight audio session for ringtone playback.
            // This will be replaced by the VoIP session when the call is answered.
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)

            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1 // Loop indefinitely
            if !player.play() {
                Log.audio.failure("AVAudioPlayer.play() returned false — audio session may not be active")
            }
            audioPlayer = player
        } catch {
            Log.audio.failure("Failed to start ringtone audio player", error: error)
        }
    }

    // MARK: - Vibration Loop

    private func ringCycle() {
        guard isRinging else { return }

        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)

        // Play system tri-tone as fallback when no bundled ringtone is available
        if ringtoneURL == nil {
            AudioServicesPlaySystemSound(Self.systemTriToneSoundID)
        }

        vibrationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.ringCycle()
        }
    }
}
#endif
