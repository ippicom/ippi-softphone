//
//  LoginView.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import SwiftUI

struct LoginView: View {
    @State private var viewModel = LoginViewModel()
    
    private var currentYear: String {
        String(Calendar.current.component(.year, from: Date()))
    }
    
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    // Top spacing
                    Spacer()
                        .frame(height: geometry.size.height * 0.08)
                    
                    // Logo - 25% bigger (125 instead of 100)
                    Image("Logo")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 125)
                    
                    Spacer()
                        .frame(height: geometry.size.height * 0.08)
                    
                    // Login form - iOS native grouped style
                    VStack(spacing: 16) {
                        // Username and password fields grouped
                        VStack(spacing: 0) {
                            TextField(String(localized: "login.username.placeholder"), text: $viewModel.username)
                                .textContentType(.username)
                                .autocorrectionDisabled()
                                .scrollDismissesKeyboard(.interactively)
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.asciiCapable)
                                #endif
                                .padding()
                            
                            Divider()
                                .padding(.leading, 16)
                            
                            SecureField(String(localized: "login.password.placeholder"), text: $viewModel.password)
                                .textContentType(.password)
                                .scrollDismissesKeyboard(.interactively)
                                .padding()
                        }
                        .background(Color.appSecondaryGroupedBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        
                        // Login button
                        Button {
                            Task { await viewModel.login() }
                        } label: {
                            HStack {
                                Spacer()
                                if viewModel.isLoading {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Text("login.button")
                                        .fontWeight(.semibold)
                                }
                                Spacer()
                            }
                            .padding()
                            .background(viewModel.isFormValid || viewModel.isLoading ? Color.ippiBlue : Color(.systemGray4))
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(viewModel.isFormValid && !viewModel.isLoading)
                        .opacity(viewModel.isFormValid || viewModel.isLoading ? 1 : 0.6)
                        .padding(.top, 8)
                    }
                    .padding(.horizontal, 24)
                    
                    Spacer()
                    
                    // Footer - www.ippi.com above copyright, aligned to bottom
                    VStack(spacing: 4) {
                        Link("www.ippi.com", destination: URL(string: "https://www.ippi.com")!)
                            .font(.caption)
                            .foregroundStyle(Color.ippiBlue)
                        
                        Text(String(format: String(localized: "footer.copyright"), currentYear))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 16)
                }
            }
            .background { AppBackgroundGradient() }
            .navigationTitle(String(localized: "login.title"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .alert(String(localized: "login.error.title"), isPresented: $viewModel.showError) {
            Button("OK") {
                viewModel.clearError()
            }
        } message: {
            Text(viewModel.errorMessage ?? String(localized: "login.error.generic"))
        }
    }
}

#Preview {
    LoginView()
}
