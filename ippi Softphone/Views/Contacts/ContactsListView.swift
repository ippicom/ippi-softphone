//
//  ContactsListView.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import SwiftUI

struct ContactsListView: View {
    @State private var viewModel = ContactsViewModel()
    
    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !viewModel.hasPermission {
                ContentUnavailableView {
                    Label(String(localized: "contacts.permission.title"), systemImage: "person.crop.circle.badge.exclamationmark")
                } description: {
                    Text(viewModel.isPermissionDenied
                         ? "contacts.permission.denied"
                         : "contacts.permission.description")
                } actions: {
                    Button(String(localized: viewModel.isPermissionDenied
                                  ? "contacts.permission.openSettings"
                                  : "contacts.permission.button")) {
                        Task {
                            await viewModel.requestPermission()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.ippiBlue)
                }
            } else if viewModel.filteredContacts.isEmpty {
                if viewModel.searchText.isEmpty {
                    ContentUnavailableView(
                        String(localized: "contacts.empty.title"),
                        systemImage: "person.crop.circle",
                        description: Text("contacts.empty.description")
                    )
                } else {
                    ContentUnavailableView.search(text: viewModel.searchText)
                }
            } else {
                List {
                    ForEach(viewModel.groupedContacts, id: \.0) { section, contacts in
                        Section(header: Text(section)) {
                            ForEach(contacts) { contact in
                                ContactRowView(contact: contact) { phoneNumber in
                                    Task {
                                        await viewModel.call(contact, phoneNumber: phoneNumber)
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .background { AppBackgroundGradient() }
        .navigationTitle(String(localized: "contacts.title"))
        #if os(iOS)
        .searchable(text: $viewModel.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: String(localized: "contacts.search"))
        #else
        .searchable(text: $viewModel.searchText, prompt: String(localized: "contacts.search"))
        #endif
        .task {
            await viewModel.loadContacts()
        }
        .refreshable {
            await viewModel.refreshContacts()
        }
    }
}

// MARK: - Contact Row

struct ContactRowView: View {
    let contact: Contact
    let onCall: (PhoneNumber) -> Void
    
    @State private var showPhoneNumbers = false
    
    var body: some View {
        Button(action: {
            if contact.phoneNumbers.count == 1 {
                if let number = contact.phoneNumbers.first {
                    onCall(number)
                }
            } else {
                showPhoneNumbers = true
            }
        }) {
            HStack(spacing: 12) {
                // Avatar
                ContactAvatarView(contact: contact, size: 44)
                
                // Name only - no phone number displayed
                Text(contact.fullName)
                    .font(.body)
                    .foregroundStyle(.primary)
                
                Spacer()
                
                // Phone icon indicates it's callable
                Image(systemName: "phone.fill")
                    .foregroundStyle(Color.ippiBlue)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .confirmationDialog(
            contact.fullName,
            isPresented: $showPhoneNumbers,
            titleVisibility: .visible
        ) {
            ForEach(contact.phoneNumbers) { number in
                Button {
                    onCall(number)
                } label: {
                    Text("\(number.displayLabel): \(PhoneNumberFormatter.format(number.value))")
                }
            }
            Button(String(localized: "common.cancel"), role: .cancel) {}
        }
    }
}

// MARK: - Contact Avatar

struct ContactAvatarView: View {
    let contact: Contact
    let size: CGFloat
    
    var body: some View {
        Group {
            if let imageData = contact.thumbnailImageData,
               let uiImage = platformImage(from: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(contact.initials)
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Color.ippiBlue)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
    
    #if os(iOS)
    private func platformImage(from data: Data) -> UIImage? {
        UIImage(data: data)
    }
    #else
    private func platformImage(from data: Data) -> NSImage? {
        NSImage(data: data)
    }
    #endif
}

#Preview {
    ContactsListView()
}
