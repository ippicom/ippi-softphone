//
//  Secrets.example.swift
//  ippi Softphone
//
//  Copy this file to Secrets.swift and fill in your values.
//  Secrets.swift is gitignored and will not be committed.
//

import Foundation
import CryptoKit

enum Secrets {
    // MARK: - Push API Configuration

    enum PushAPI {
        /// Base URL for the push notification registration API
        static let baseURL = "https://your-api-server.example.com/app-device"
        /// Path to enable push notifications
        static let enablePath = "/enable-apn"
        /// Path to disable push notifications
        static let disablePath = "/disable-apn"
        /// Value sent in the X-APP header for API requests
        static let appHeader = "your-app-name"
        /// SIP authentication realm
        static let sipRealm = "your-sip-realm.example.com"
    }

    // MARK: - Push API Authentication

    /// Compute authentication hash for push API requests.
    /// Replace with your server's expected hash algorithm.
    static func computePushHash(voipToken: String, login: String, password: String) -> String {
        // Example implementation — replace with your server's auth scheme
        let input = "\(voipToken)-\(login)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
