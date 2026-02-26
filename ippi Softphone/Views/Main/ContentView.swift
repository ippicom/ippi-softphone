//
//  ContentView.swift
//  ippi Softphone
//
//  Created by Guillaume Lacroix on 16/02/2026.
//

import SwiftUI

struct ContentView: View {
    @Environment(\.appEnvironment) private var environment
    @AppStorage("appearanceMode") private var appearanceMode: Int = 0
    @State private var hasStartedInit = false

    private var colorScheme: ColorScheme? {
        AppearanceMode(rawValue: appearanceMode)?.colorScheme
    }

    var body: some View {
        Group {
            if environment.isInitializing {
                // Splash screen during initialization
                SplashView()
            } else if environment.isLoggedIn {
                if environment.needsOnboarding {
                    #if os(iOS)
                    OnboardingView()
                        .transition(.opacity)
                    #else
                    MainSidebarView()
                    #endif
                } else {
                    #if os(iOS)
                    MainTabView()
                        .transition(.opacity)
                    #else
                    MainSidebarView()
                    #endif
                }
            } else {
                LoginView()
            }
        }
        .animation(.easeInOut, value: environment.isInitializing)
        .animation(.easeInOut, value: environment.isLoggedIn)
        .animation(.easeInOut, value: environment.needsOnboarding)
        .preferredColorScheme(colorScheme)
        .task {
            // Start app initialization (includes minimum splash duration)
            guard !hasStartedInit else { return }
            hasStartedInit = true
            await environment.initializeApp()
        }
    }
}

// MARK: - Splash Screen

private struct SplashView: View {
    var body: some View {
        ZStack {
            AppBackgroundGradient()

            ProgressView()
        }
    }
}

#Preview {
    ContentView()
}
