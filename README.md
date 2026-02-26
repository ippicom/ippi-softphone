# ippi Softphone

Open-source iOS SIP softphone built with **liblinphone** and **SwiftUI**.

## Features

- SIP voice calls (outgoing and incoming)
- CallKit integration (native iOS call UI)
- PushKit VoIP push notifications (background call wake-up)
- SRTP media encryption (optional)
- TLS signaling
- Call history (SwiftData)
- Contact integration
- Multi-call support (hold, swap)
- DTMF
- STUN/ICE NAT traversal

## Requirements

- Xcode 15+
- iOS 17+
- Apple Developer account (for push notifications)

## Setup

1. Clone the repo
2. Copy `Secrets.example.swift` → `ippi Softphone/Utilities/Secrets.swift` and fill in your values
3. Copy `GoogleService-Info.example.plist` → `ippi Softphone/GoogleService-Info.plist` (from your Firebase project)
4. Open `ippi Softphone.xcodeproj`
5. Configure signing (Team + provisioning profiles)
6. Build & Run

## Architecture

MVVM + Services with a central `AppEnvironment` singleton.

```
Views → ViewModels → AppEnvironment → Managers/Services
                                       ├── SIPManager (liblinphone)
                                       ├── CallKitManager
                                       ├── AudioSessionManager
                                       ├── PushKitManager
                                       └── CallService
```

## License

This project is licensed under the **GNU Affero General Public License v3.0 (AGPL-3.0)** — see [LICENSE](LICENSE).

This license is required because the project uses [liblinphone](https://gitlab.linphone.org/BC/public/linphone-sdk), which is licensed under AGPL-3.0.
