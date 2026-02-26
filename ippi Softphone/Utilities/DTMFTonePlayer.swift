//
//  DTMFTonePlayer.swift
//  ippi Softphone
//
//  Created by ippi on 17/02/2026.
//

import Foundation
import AVFoundation
import AudioToolbox

/// Plays DTMF tones locally for user feedback
/// Uses system sounds on iOS for reliable playback during calls
@MainActor
final class DTMFTonePlayer {
    static let shared = DTMFTonePlayer()
    
    #if os(iOS)
    // DTMF system sound IDs (iOS system DTMF tones)
    // These work reliably even during active calls
    private let dtmfSystemSounds: [Character: SystemSoundID] = [
        "0": 1200, "1": 1201, "2": 1202, "3": 1203,
        "4": 1204, "5": 1205, "6": 1206, "7": 1207,
        "8": 1208, "9": 1209, "*": 1210, "#": 1211,
        "+": 1200  // Use 0 tone for +
    ]
    #endif
    
    // Fallback: custom tone generator for when system sounds don't work
    private var audioEngine: AVAudioEngine?
    private var tonePlayer: AVAudioPlayerNode?
    private var isPlaying = false
    
    // DTMF frequency pairs (low, high) for each digit - ITU-T Q.23
    private let dtmfFrequencies: [Character: (low: Float, high: Float)] = [
        "1": (697, 1209), "2": (697, 1336), "3": (697, 1477),
        "4": (770, 1209), "5": (770, 1336), "6": (770, 1477),
        "7": (852, 1209), "8": (852, 1336), "9": (852, 1477),
        "*": (941, 1209), "0": (941, 1336), "#": (941, 1477),
        "+": (941, 1336)
    ]
    
    private let sampleRate: Double = 44100
    private let toneDuration: Double = 0.12  // 120ms tone duration
    private let amplitude: Float = 0.25      // Volume level
    
    private init() {}
    
    /// Play DTMF tone for the given digit
    /// - Parameter useSystemSound: If true, uses iOS system sounds (works during calls). 
    ///                             If false, generates tone (works without active audio session).
    func playTone(for digit: Character, useSystemSound: Bool = false) {
        #if os(iOS)
        // During calls, system sounds work best alongside the call audio
        if useSystemSound, let soundID = dtmfSystemSounds[digit] {
            AudioServicesPlaySystemSound(soundID)
            return
        }
        #endif
        
        // Generate tone - works regardless of audio session state
        Task { [weak self] in
            await self?.playGeneratedTone(for: digit)
        }
    }
    
    private func playGeneratedTone(for digit: Character) async {
        guard let frequencies = dtmfFrequencies[digit] else { return }
        guard !isPlaying else { return }
        isPlaying = true
        defer { isPlaying = false }
        
        do {
            // Create audio engine if needed
            if audioEngine == nil {
                audioEngine = AVAudioEngine()
                tonePlayer = AVAudioPlayerNode()
                
                guard let engine = audioEngine, let player = tonePlayer else { return }
                
                engine.attach(player)
                
                let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
                engine.connect(player, to: engine.mainMixerNode, format: format)
            }
            
            guard let engine = audioEngine, let player = tonePlayer else { return }
            
            // Generate the DTMF tone buffer
            let frameCount = AVAudioFrameCount(sampleRate * toneDuration)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!, frameCapacity: frameCount) else { return }
            
            buffer.frameLength = frameCount
            let data = buffer.floatChannelData![0]
            
            for frame in 0..<Int(frameCount) {
                let time = Float(frame) / Float(sampleRate)
                
                // DTMF is the sum of two sine waves
                let lowComponent = sin(2.0 * .pi * frequencies.low * time)
                let highComponent = sin(2.0 * .pi * frequencies.high * time)
                
                // Apply envelope to avoid clicks
                var envelope: Float = 1.0
                let fadeFrames = Int(sampleRate * 0.005) // 5ms fade
                if frame < fadeFrames {
                    envelope = Float(frame) / Float(fadeFrames)
                } else if frame > Int(frameCount) - fadeFrames {
                    envelope = Float(Int(frameCount) - frame) / Float(fadeFrames)
                }
                
                data[frame] = amplitude * envelope * (lowComponent + highComponent) / 2.0
            }
            
            // Configure audio session - try to mix with existing audio
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            if session.category != .playAndRecord {
                try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .duckOthers])
                try? session.setActive(true, options: [.notifyOthersOnDeactivation])
            }
            #endif
            
            // Start engine if not running
            if !engine.isRunning {
                try engine.start()
            }
            
            // Start playback BEFORE scheduling the buffer.
            // scheduleBuffer(_:) is async and waits for rendering completion,
            // so play() must be called first to avoid a deadlock.
            player.play()
            await player.scheduleBuffer(buffer)

            player.stop()
            
        } catch {
            Log.general.failure("Failed to play DTMF tone", error: error)
        }
    }
    
    /// Stop any playing tone and cleanup
    func stop() {
        tonePlayer?.stop()
        audioEngine?.stop()
        audioEngine = nil
        tonePlayer = nil
    }
}
