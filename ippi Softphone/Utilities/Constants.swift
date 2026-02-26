//
//  Constants.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import Foundation

enum Constants {
    // MARK: - SIP Configuration
    enum SIP {
        static let domain = "tls.ippi.com"
        static let srtpDomain = "sips.ippi.com"
        static let sipDomain = "sip.ippi.com"

        /// Returns `srtpDomain` when SRTP is enabled, otherwise `domain`
        static var effectiveDomain: String {
            UserDefaults.standard.bool(forKey: Constants.UserDefaultsKeys.srtpEnabled)
                ? srtpDomain
                : domain
        }
        static let transportType = "TLS"
        static let udpPort = 0   // Disabled
        static let tcpPort = 0   // Disabled
        static let tlsPort = -1  // -1 = random port for TLS
        static let registrationExpiry: Int32 = 300  // 5 minutes
        static let callTimeout: TimeInterval = 60   // Max time waiting for call to connect
        static let registrationTimeout: TimeInterval = 30  // Max time for registration
    }
    
    // MARK: - NAT / STUN Configuration
    enum NAT {
        static let stunServer = "stun.l.google.com"
        static let stunPort: Int32 = 19302
        static let stunServerURL = "stun:\(stunServer):\(stunPort)"
    }
    
    // MARK: - UserDefaults Keys
    enum UserDefaultsKeys {
        static let stunEnabled = "stunEnabled"
        static let srtpEnabled = "srtpEnabled"
    }
    
    // MARK: - Keychain
    enum Keychain {
        static let service = "com.ippi.softphone"
        static let accountKey = "sipAccount"
        static let passwordKey = "sipPassword"
    }
    
    // MARK: - App Info
    enum App {
        static let name = "ippi Softphone"
        static let bundleIdentifier = "com.ippi.softphone"
        static let userAgent = "ippi-softphone-ios/1.0"
    }
    
    // MARK: - CallKit
    enum CallKit {
        static let localizedName = "ippi"
        static let maximumCallsPerCallGroup = 2  // Supports call-waiting (hold + active)
        static let supportsVideo = false
    }
    
    // MARK: - Audio
    enum Audio {
        static let defaultRingtone = "ringtone"
        static let dtmfDuration: TimeInterval = 0.2
    }

    // MARK: - App Group
    enum AppGroup {
        static let identifier = "group.com.ippi.softphone"
    }
}
