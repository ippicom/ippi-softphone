//
//  ActiveCallView.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

struct ActiveCallView: View {
    @State private var viewModel = ActiveCallViewModel()
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            AppBackgroundGradient()

        VStack(spacing: 0) {
            // MARK: Top — Banners

            if viewModel.hasCallOnHold {
                HeldCallBanner(
                    callerDisplay: viewModel.heldCallDisplay,
                    onTap: {
                        playHaptic(.light)
                        Task { await viewModel.swapCalls() }
                    }
                )
                .padding(12)
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.orange.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(
                                    LinearGradient(colors: [.white.opacity(0.15), .clear], startPoint: .top, endPoint: .bottom)
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
                        )
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }

            if viewModel.hasIncomingWaiting {
                IncomingWaitingBanner(
                    callerDisplay: viewModel.incomingWaitingDisplay,
                    onAnswer: {
                        playHaptic(.success)
                        Task { await viewModel.answerAndHoldCurrent() }
                    },
                    onDecline: {
                        playHaptic(.error)
                        Task { await viewModel.declineIncomingWaiting() }
                    }
                )
                .padding(12)
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.ippiGreen.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(
                                    LinearGradient(colors: [.white.opacity(0.15), .clear], startPoint: .top, endPoint: .bottom)
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.ippiGreen.opacity(0.25), lineWidth: 1)
                        )
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }

            // MARK: Middle — Caller info (upper-middle area)

            Spacer().frame(maxHeight: 40)

            VStack(spacing: 16) {
                // Avatar with pulse animation
                ZStack {
                    if viewModel.isConnected {
                        PulseRing(delay: 0)
                        PulseRing(delay: 0.6)
                        PulseRing(delay: 1.2)
                    }

                    Circle()
                        .fill(Color.ippiBlue.opacity(0.15))
                        .frame(width: 100, height: 100)

                    Image(systemName: "person.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.ippiBlue)
                }

                // Name
                Text(viewModel.callerDisplay)
                    .font(.title)
                    .fontWeight(.semibold)

                // Phone number (shown when contact name is displayed)
                if let phoneNumber = viewModel.formattedPhoneNumber {
                    Text(phoneNumber)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Status
                HStack(spacing: 6) {
                    if viewModel.isOnHold {
                        Image(systemName: "pause.circle.fill")
                            .foregroundStyle(.orange)
                        Text("call.onhold")
                            .foregroundStyle(.orange)
                    } else if viewModel.isConnected {
                        Image(systemName: "phone.fill")
                            .foregroundStyle(Color.ippiGreen)
                        Text(viewModel.displayDuration)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "phone.arrow.up.right.fill")
                            .foregroundStyle(Color.ippiBlue)
                        Text(viewModel.callStateText)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
            }

            Spacer()

            // MARK: Bottom — Controls + Action buttons (fixed)

            VStack(spacing: 24) {
                if viewModel.showControls {
                    CallControlsView(viewModel: viewModel)
                        .padding(.vertical, 16)
                        .background {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.ippiBlue.opacity(0.18))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(
                                            LinearGradient(colors: [.white.opacity(0.12), .clear], startPoint: .top, endPoint: .bottom)
                                        )
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(Color.ippiBlue.opacity(0.3), lineWidth: 1)
                                )
                        }
                        .padding(.horizontal)
                }

                if viewModel.isIncoming {
                    // Incoming call: Decline and Answer
                    HStack {
                        Spacer()

                        // Decline
                        VStack(spacing: 8) {
                            Button(action: {
                                playHaptic(.error)
                                Task { await viewModel.hangup() }
                            }) {
                                Image(systemName: "phone.down.fill")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.white)
                                    .frame(width: 80, height: 80)
                                    .background(Color.red)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(String(localized: "Decline call")))
                            .accessibilityHint(Text(String(localized: "Double tap to decline incoming call")))

                            Text("call.decline")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                        Spacer()

                        // Answer
                        VStack(spacing: 8) {
                            Button(action: {
                                playHaptic(.success)
                                Task { await viewModel.answer() }
                            }) {
                                Image(systemName: "phone.fill")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.white)
                                    .frame(width: 80, height: 80)
                                    .background(Color.ippiGreen)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(String(localized: "Answer call")))
                            .accessibilityHint(Text(String(localized: "Double tap to answer incoming call")))

                            Text("call.answer")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                } else {
                    // Active call: Hangup button
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Button(action: {
                                playHaptic(.error)
                                Task { await viewModel.hangup() }
                            }) {
                                Image(systemName: "phone.down.fill")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.white)
                                    .frame(width: 80, height: 80)
                                    .background(Color.red)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(String(localized: "End call")))
                            .accessibilityHint(Text(String(localized: "Double tap to hang up")))

                            Text("call.hangup")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
            .padding(.bottom, 32)
        }
        } // ZStack
        .sheet(isPresented: $viewModel.showDTMFPad) {
            DTMFPadView(viewModel: viewModel)
                .presentationDetents([.medium])
        }
        .onChange(of: viewModel.hasActiveCall) { _, hasCall in
            if !hasCall {
                dismiss()
            }
        }
        .onDisappear {
            viewModel.cleanup()
        }
    }
}

// MARK: - Call Controls View

struct CallControlsView: View {
    @Bindable var viewModel: ActiveCallViewModel
    
    var body: some View {
        VStack(spacing: 20) {
            // First row: Mute, Hold, Speaker
            HStack {
                Spacer()
                
                // Mute
                CallControlButton(
                    icon: viewModel.isMuted ? "mic.slash.fill" : "mic.fill",
                    label: String(localized: "call.mute"),
                    isActive: viewModel.isMuted
                ) {
                    Task { await viewModel.toggleMute() }
                }
                
                Spacer()
                
                // Hold - disabled during multiple calls
                CallControlButton(
                    icon: viewModel.isOnHold ? "play.fill" : "pause.fill",
                    label: viewModel.isOnHold ? String(localized: "call.resume") : String(localized: "call.hold"),
                    isActive: viewModel.isOnHold,
                    isEnabled: !viewModel.hasMultipleCalls
                ) {
                    Task { await viewModel.toggleHold() }
                }
                
                Spacer()
                
                // Speaker
                CallControlButton(
                    icon: viewModel.isSpeakerEnabled ? "speaker.wave.3.fill" : "speaker.fill",
                    label: String(localized: "call.speaker"),
                    isActive: viewModel.isSpeakerEnabled
                ) {
                    viewModel.toggleSpeaker()
                }
                
                Spacer()
            }
            
            // Second row: Keypad (centered)
            HStack {
                Spacer()
                
                // Keypad
                CallControlButton(
                    icon: "circle.grid.3x3.fill",
                    label: String(localized: "call.keypad"),
                    isActive: false
                ) {
                    viewModel.showDTMFPad = true
                }
                
                Spacer()
            }
        }
    }
}

// MARK: - Call Control Button

struct CallControlButton: View {
    let icon: String
    let label: String
    let isActive: Bool
    var isEnabled: Bool = true
    let action: () -> Void
    
    var body: some View {
        Button(action: {
            playHaptic(.light)
            action()
        }) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(isActive ? .white : (isEnabled ? Color.primary : Color(.tertiaryLabel)))
                    .frame(width: 80, height: 80)
                    .background(
                        Circle()
                            .fill(isActive ? Color.ippiBlue : Color.appTertiaryFill)
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(Color.ippiBlue.opacity(isActive ? 0 : 0.3), lineWidth: 1)
                    )
                
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(isEnabled ? Color.primary : Color(.tertiaryLabel))
            }
            .frame(width: 70)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(Text(label))
        .accessibilityValue(isActive ? Text(String(localized: "On")) : Text(String(localized: "Off")))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// MARK: - Haptic Feedback

private enum HapticType {
    case success
    case error
    case light
}

#if os(iOS)
private let notificationGenerator = UINotificationFeedbackGenerator()
private let impactGenerator = UIImpactFeedbackGenerator(style: .light)
#endif

private func playHaptic(_ type: HapticType) {
    #if os(iOS)
    switch type {
    case .success:
        notificationGenerator.notificationOccurred(.success)
    case .error:
        notificationGenerator.notificationOccurred(.error)
    case .light:
        impactGenerator.impactOccurred()
    }
    #endif
}

// MARK: - Held Call Banner

struct HeldCallBanner: View {
    let callerDisplay: String
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "pause.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("call.onhold")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(callerDisplay)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                }
                
                Spacer()
                
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.footnote.weight(.semibold))
                    
                    Text("call.swap")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.ippiBlue)
                .clipShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: "Call on hold: \(callerDisplay)")))
        .accessibilityHint(Text(String(localized: "Double tap to swap calls")))
    }
}

// MARK: - Incoming Waiting Banner

struct IncomingWaitingBanner: View {
    let callerDisplay: String
    let onAnswer: () -> Void
    let onDecline: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "phone.arrow.down.left.fill")
                .font(.title2)
                .foregroundStyle(Color.ippiGreen)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("call.incoming")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(callerDisplay)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
            }
            
            Spacer()
            
            // Decline
            Button(action: onDecline) {
                Image(systemName: "xmark")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(Color.red)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(localized: "Decline incoming call")))
            
            // Answer
            Button(action: onAnswer) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(Color.ippiGreen)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(localized: "Answer incoming call and hold current")))
        }
    }
}

// MARK: - Pulse Ring Animation

private struct PulseRing: View {
    let delay: Double
    @State private var isAnimating = false

    var body: some View {
        Circle()
            .stroke(Color.ippiBlue.opacity(0.3), lineWidth: 2)
            .frame(width: 100, height: 100)
            .scaleEffect(isAnimating ? 1.6 : 1.0)
            .opacity(isAnimating ? 0 : 0.6)
            .animation(
                .easeOut(duration: 2.0)
                .repeatForever(autoreverses: false)
                .delay(delay),
                value: isAnimating
            )
            .onAppear { isAnimating = true }
    }
}

#Preview {
    ActiveCallView()
}
