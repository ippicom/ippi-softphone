//
//  CreditsView.swift
//  ippi Softphone
//
//  Created by ippi on 25/02/2026.
//

import SwiftUI

struct CreditsView: View {
    var body: some View {
        List {
            // Licenses intro
            Section {
                Text("credits.licenses.intro")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            licenseSection(
                name: "linphone SDK",
                copyright: "Copyright © Belledonne Communications SARL",
                license: "GNU Affero General Public License v3.0 (AGPL-3.0)",
                url: "https://gitlab.linphone.org/BC/public/linphone-sdk"
            )

            licenseSection(
                name: "Firebase Crashlytics",
                copyright: "Copyright © Google LLC",
                license: "Apache License 2.0",
                url: "https://github.com/firebase/firebase-ios-sdk"
            )

            // Firebase transitive dependencies
            Section {
                Text("credits.firebase.transitive.intro")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                ForEach(Self.firebaseTransitiveDeps, id: \.name) { dep in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dep.name)
                            .font(.footnote)
                        Text(dep.license)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("credits.firebase.transitive.header")
            }

            licenseSection(
                name: "PhoneNumberKit",
                copyright: "Copyright © Roy Marmelstein",
                license: "MIT License",
                url: "https://github.com/marmelroy/PhoneNumberKit"
            )

            // Source code
            Section {
                Link(destination: URL(string: "https://github.com/ippicom/ippi-softphone")!) {
                    HStack {
                        Text("credits.source.code.description")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("credits.source.code")
            }
        }
        .navigationTitle(String(localized: "credits.title"))
    }

    // MARK: - Firebase transitive dependencies

    private struct TransitiveDep {
        let name: String
        let license: String
    }

    private static let firebaseTransitiveDeps: [TransitiveDep] = [
        TransitiveDep(name: "Abseil C++", license: "Apache 2.0"),
        TransitiveDep(name: "App Check", license: "Apache 2.0"),
        TransitiveDep(name: "Google App Measurement", license: "Apache 2.0"),
        TransitiveDep(name: "Google Data Transport", license: "Apache 2.0"),
        TransitiveDep(name: "Google Utilities", license: "Apache 2.0"),
        TransitiveDep(name: "gRPC", license: "Apache 2.0"),
        TransitiveDep(name: "GTM Session Fetcher", license: "Apache 2.0"),
        TransitiveDep(name: "Interop for Google SDKs", license: "Apache 2.0"),
        TransitiveDep(name: "LevelDB", license: "BSD 3-Clause"),
        TransitiveDep(name: "nanopb", license: "zlib"),
        TransitiveDep(name: "Google Ads On Device Conversion", license: "Apache 2.0"),
        TransitiveDep(name: "Promises", license: "Apache 2.0"),
    ]

    private func licenseSection(name: String, copyright: String, license: String, url: String) -> some View {
        Section(name) {
            Text(copyright)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(license)
                .font(.footnote)
            if let link = URL(string: url) {
                Link(destination: link) {
                    HStack {
                        Text(url)
                            .font(.footnote)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
