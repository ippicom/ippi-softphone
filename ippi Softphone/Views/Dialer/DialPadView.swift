//
//  DialPadView.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import SwiftUI

struct DialPadView: View {
    @Binding var phoneNumber: String
    let onDigitTapped: (String) -> Void
    let onCall: () -> Void
    let onDelete: () -> Void
    let canDial: Bool
    let isLoading: Bool
    let showDelete: Bool
    var isEnabled: Bool = true  // Controls whether digit buttons are enabled
    
    // Button size and spacing constants
    private let buttonSize: CGFloat = 80
    private let horizontalSpacing: CGFloat = 24
    private let verticalSpacing: CGFloat = 16
    
    private let buttons: [[DialPadButton.ButtonType]] = [
        [.digit("1", ""), .digit("2", "ABC"), .digit("3", "DEF")],
        [.digit("4", "GHI"), .digit("5", "JKL"), .digit("6", "MNO")],
        [.digit("7", "PQRS"), .digit("8", "TUV"), .digit("9", "WXYZ")],
        [.special("*"), .digit("0", "+"), .special("#")]
    ]
    
    var body: some View {
        VStack(spacing: verticalSpacing) {
            // Number pad rows
            ForEach(0..<buttons.count, id: \.self) { row in
                HStack(spacing: horizontalSpacing) {
                    ForEach(0..<buttons[row].count, id: \.self) { col in
                        DialPadButton(
                            type: buttons[row][col],
                            phoneNumber: $phoneNumber,
                            isEnabled: isEnabled,
                            action: { digit in
                                onDigitTapped(digit)
                            }
                        )
                    }
                }
            }
            
            // Call button row - same spacing as dial pad
            HStack(spacing: horizontalSpacing) {
                // Empty space for balance (same size as buttons)
                Color.clear
                    .frame(width: buttonSize, height: buttonSize)
                
                // Call button (same size as other buttons)
                Button(action: onCall) {
                    ZStack {
                        Circle()
                            .fill(canDial ? Color.ippiGreen : Color.ippiGreen.opacity(0.3))
                            .frame(width: buttonSize, height: buttonSize)
                        
                        if isLoading {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "phone.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .disabled(!canDial || isLoading)
                .accessibilityLabel(Text(String(localized: "call.answer")))
                .accessibilityHint(canDial ? Text(String(localized: "Double tap to call \(phoneNumber)")) : Text(""))
                
                // Delete button (same size as buttons)
                // Tap = delete one digit, Long press = clear all
                Button(action: onDelete) {
                    Image(systemName: "delete.left.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                        .frame(width: buttonSize, height: buttonSize)
                }
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .onEnded { _ in
                            phoneNumber = ""
                        }
                )
                .opacity(showDelete ? 1 : 0)
                .disabled(!showDelete)
                .accessibilityLabel(Text(String(localized: "common.delete")))
                .accessibilityHint(Text(String(localized: "dialpad.delete.hint")))
            }
        }
    }
}

// MARK: - Dial Pad Button

struct DialPadButton: View {
    enum ButtonType {
        case digit(String, String) // number, letters
        case special(String) // * or #
        
        var digit: String {
            switch self {
            case .digit(let num, _): return num
            case .special(let sym): return sym
            }
        }
    }
    
    let type: ButtonType
    @Binding var phoneNumber: String
    var isEnabled: Bool = true
    let action: (String) -> Void
    
    @State private var isLongPressing = false
    
    var body: some View {
        let isZero = type.digit == "0"
        
        Button(action: {
            guard isEnabled else { return }
            
            // Only handle tap if not long pressing
            guard !isLongPressing else {
                isLongPressing = false
                return
            }
            
            handleTap(digit: type.digit)
        }) {
            VStack(spacing: 2) {
                switch type {
                case .digit(let number, let letters):
                    Text(number)
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.primary)
                    
                    if !letters.isEmpty {
                        Text(letters)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .tracking(2)
                    } else {
                        Text(" ")
                            .font(.system(size: 10))
                    }
                    
                case .special(let symbol):
                    if symbol == "*" {
                        // Asterisk needs to be larger and shifted down to appear centered
                        Text(symbol)
                            .font(.system(size: 48, weight: .light))
                            .foregroundStyle(.primary)
                            .offset(y: 8)
                    } else {
                        Text(symbol)
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.primary)
                    }
                }
            }
            .frame(width: 80, height: 80) // Must match parent buttonSize
            .background(
                Circle()
                    .fill(Color.appBackground)
                    .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
            )
            .overlay(
                Circle()
                    .stroke(Color(.systemGray4), lineWidth: 0.5)
            )
        }
        .buttonStyle(DialPadPressStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.5)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    guard isEnabled else { return }
                    if isZero {
                        isLongPressing = true
                        handleTap(digit: "+")
                    }
                }
        )
        .accessibilityLabel(accessibilityLabelForType)
        .accessibilityHint(isZero ? Text(String(localized: "Long press for plus")) : Text(""))
    }
    
    private var accessibilityLabelForType: Text {
        switch type {
        case .digit(let number, let letters):
            if letters.isEmpty {
                return Text(number)
            } else {
                return Text("\(number), \(letters)")
            }
        case .special(let symbol):
            return symbol == "*" ? Text(String(localized: "Star")) : Text(String(localized: "Hash"))
        }
    }
    
    private func handleTap(digit: String) {
        // Note: Haptic feedback intentionally disabled on dialer — it causes input lag
        action(digit)
    }
}

// MARK: - Press Style

struct DialPadPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle()
                    .fill(configuration.isPressed ? Color(.systemGray5) : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

#Preview {
    @Previewable @State var number = ""
    DialPadView(
        phoneNumber: $number,
        onDigitTapped: { _ in },
        onCall: { },
        onDelete: { },
        canDial: true,
        isLoading: false,
        showDelete: false
    )
    .padding()
}
