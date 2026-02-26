//
//  DTMFPadView.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import SwiftUI

struct DTMFPadView: View {
    @Bindable var viewModel: ActiveCallViewModel
    @Environment(\.dismiss) private var dismiss
    
    private let buttons: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["*", "0", "#"]
    ]
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // DTMF pad
                ForEach(0..<buttons.count, id: \.self) { row in
                    HStack(spacing: 32) {
                        ForEach(buttons[row], id: \.self) { digit in
                            Button(action: {
                                // Play local DTMF tone for user feedback
                                // Use system sound during calls (audio session is active)
                                DTMFTonePlayer.shared.playTone(for: Character(digit), useSystemSound: true)
                                
                                // Send DTMF to remote party
                                Task {
                                    await viewModel.sendDTMF(Character(digit))
                                }
                            }) {
                                Text(digit)
                                    .font(.system(size: 32, weight: .light))
                                    .frame(width: 80, height: 80)
                                    .background(Color(.tertiarySystemBackground))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding()
            .navigationTitle("Keypad")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    DTMFPadView(viewModel: ActiveCallViewModel())
}
