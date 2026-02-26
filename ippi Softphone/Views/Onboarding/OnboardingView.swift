//
//  OnboardingView.swift
//  ippi Softphone
//
//  Created by ippi on 21/02/2026.
//

#if os(iOS)
import SwiftUI

struct OnboardingView: View {
    @Environment(\.appEnvironment) private var environment

    @State private var micStatus: PermissionStatus = .pending
    @State private var contactsStatus: PermissionStatus = .pending
    @State private var pushStatus: PermissionStatus = .pending
    @State private var isPushLoading = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()
                    .frame(height: 40)

                // Logo
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 100)

                // Title & subtitle
                VStack(spacing: 8) {
                    Text("onboarding.title")
                        .font(.title.bold())

                    Text("onboarding.subtitle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)
                .padding(.horizontal, 24)

                Spacer()
                    .frame(height: 40)

                // Permission rows
                VStack(spacing: 0) {
                    permissionRow(
                        icon: "mic.fill",
                        title: "onboarding.mic.title",
                        description: "onboarding.mic.description",
                        status: micStatus
                    )

                    Divider()
                        .padding(.leading, 56)

                    permissionRow(
                        icon: "person.crop.rectangle.stack.fill",
                        title: "onboarding.contacts.title",
                        description: "onboarding.contacts.description",
                        status: contactsStatus
                    )

                    Divider()
                        .padding(.leading, 56)

                    pushRow
                }
                .background(Color.appSecondaryGroupedBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 24)

                Spacer()

                // Continue button
                Button {
                    environment.completeOnboarding()
                } label: {
                    HStack {
                        Spacer()
                        Text("onboarding.continue")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                    .padding()
                    .background(Color.ippiBlue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            .background { AppBackgroundGradient() }
            .navigationTitle(String(localized: "onboarding.title"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            // Request permissions one by one for a clean UX
            await requestMicPermission()
            await requestContactsPermission()
            // Push requires SIP registration — wait for it
            await waitForRegistrationAndEnablePush()
        }
    }

    // MARK: - Permission Rows

    private func permissionRow(
        icon: String,
        title: LocalizedStringKey,
        description: LocalizedStringKey,
        status: PermissionStatus
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.ippiBlue)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            statusIcon(for: status)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var pushRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.fill")
                .font(.title3)
                .foregroundStyle(Color.ippiBlue)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text("onboarding.push.title")
                    .font(.body)
                Text("onboarding.push.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if pushStatus == .pending {
                if isPushLoading {
                    ProgressView()
                } else {
                    Button("onboarding.push.enable") {
                        Task { await enablePush() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.ippiBlue)
                    .controlSize(.small)
                    .disabled(!isRegistered)
                }
            } else {
                statusIcon(for: pushStatus)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func statusIcon(for status: PermissionStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .denied:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    // MARK: - Permission Requests

    private var isRegistered: Bool {
        environment.currentAccount?.registrationState == .registered
    }

    private func requestMicPermission() async {
        let granted = await environment.audioManager.requestMicrophonePermission()
        micStatus = granted ? .granted : .denied
    }

    private func requestContactsPermission() async {
        do {
            let granted = try await environment.contactsService.requestAccess()
            contactsStatus = granted ? .granted : .denied
            if granted {
                _ = try? await environment.contactsService.fetchAllContacts()
            }
        } catch {
            contactsStatus = .denied
        }
    }

    private func waitForRegistrationAndEnablePush() async {
        // Wait for SIP registration (needed for push credentials)
        for _ in 0..<50 { // 200ms × 50 = 10s max
            if isRegistered { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard isRegistered, pushStatus == .pending else { return }
        await enablePush()
    }

    private func enablePush() async {
        isPushLoading = true
        defer { isPushLoading = false }

        let result = await environment.enablePushNotifications()
        switch result {
        case .success:
            pushStatus = .granted
        case .notificationsDenied:
            pushStatus = .denied
        case .failed:
            pushStatus = .denied
        }
    }
}

// MARK: - Permission Status

private enum PermissionStatus {
    case pending, granted, denied
}

#Preview {
    OnboardingView()
}
#endif
