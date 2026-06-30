//
//  DialerView.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import SwiftUI

struct DialerView: View {
    @State private var viewModel = DialerViewModel()
    @FocusState private var isNumberFieldFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Logo at the very top of the screen (no padding)
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(height: 95)
            
            // Account status below logo - shows username, tappable to toggle online/offline
            Button(action: {
                Task { await viewModel.toggleConnection() }
            }) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.isRegistered ? Color.ippiGreen : Color.red)
                        .frame(width: 8, height: 8)
                    Text(viewModel.accountDisplay)
                        .font(.body)
                        .foregroundStyle(viewModel.isRegistered ? Color.ippiGreen : .red)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.appBackground)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            
            // Registration error message with SIP error code
            if let errorMessage = viewModel.registrationError {
                VStack(spacing: 2) {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                    if let errorDetails = viewModel.registrationErrorDetails {
                        Text(errorDetails)
                            .font(.caption2)
                            .foregroundStyle(.red.opacity(0.8))
                    }
                }
                .padding(.top, 4)
            }
            
            Spacer()
                .frame(maxHeight: 12)
            
            // Number display - clickable TextField for alphanumeric input
            // Disabled when offline to prevent input
            TextField(String(localized: "dialer.placeholder"), text: Binding(
                get: { viewModel.phoneNumber },
                set: { viewModel.setPhoneNumber($0) }
            ))
                .font(.system(size: 36, weight: .light))
                .multilineTextAlignment(.center)
                .keyboardType(.default)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .focused($isNumberFieldFocused)
                .padding(.horizontal, 32)
                .frame(height: 100)
                .disabled(!viewModel.isRegistered)
                .opacity(viewModel.isRegistered ? 1.0 : 0.5)
            
            Spacer()
                .frame(maxHeight: 12)
            
            // Dial pad with call button integrated
            // Disabled when offline
            DialPadView(
                phoneNumber: $viewModel.phoneNumber,
                onDigitTapped: { digit in
                    viewModel.appendDigit(digit)
                },
                onCall: {
                    Task { await viewModel.dial() }
                },
                onDelete: {
                    viewModel.deleteLastDigit()
                },
                canDial: viewModel.canDial,
                isLoading: viewModel.isLoading,
                showDelete: !viewModel.phoneNumber.isEmpty,
                isEnabled: viewModel.isRegistered
            )
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { AppBackgroundGradient() }
        .onTapGesture {
            isNumberFieldFocused = false
        }
        .alert(String(localized: "login.error.title"), isPresented: $viewModel.isShowingError) {
            if viewModel.isMicPermissionError {
                Button(String(localized: "contacts.permission.openSettings")) {
                    viewModel.clearError()
                    #if os(iOS)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                    #endif
                }
            }
            Button(String(localized: "common.ok"), role: .cancel) {
                viewModel.clearError()
            }
        } message: {
            Text(viewModel.errorMessage ?? String(localized: "login.error.generic"))
        }
    }
}

#Preview {
    NavigationStack {
        DialerView()
    }
}
