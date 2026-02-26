//
//  Theme.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - ippi Brand Colors

extension Color {
    /// Primary ippi blue - used for accents, buttons, and branding
    static let ippiBlue = Color(hex: "1A5F9E")
    
    /// Green for call button and online status
    static let ippiGreen = Color(hex: "4CAF50")
}

// MARK: - Cross-Platform System Colors

extension Color {
    #if os(iOS)
    static let appBackground = Color(.systemBackground)
    static let appGroupedBackground = Color(.systemGroupedBackground)
    static let appSecondaryBackground = Color(.secondarySystemBackground)
    static let appTertiaryBackground = Color(.tertiarySystemBackground)
    static let appTertiaryFill = Color(.tertiarySystemFill)
    /// For form cells/cards on a grouped background (proper contrast in dark mode)
    static let appSecondaryGroupedBackground = Color(.secondarySystemGroupedBackground)
    #elseif os(macOS)
    static let appBackground = Color(.windowBackgroundColor)
    static let appGroupedBackground = Color(.underPageBackgroundColor)
    static let appSecondaryBackground = Color(.controlBackgroundColor)
    static let appTertiaryBackground = Color(.controlBackgroundColor)
    static let appTertiaryFill = Color(.quaternaryLabelColor)
    static let appSecondaryGroupedBackground = Color(.controlBackgroundColor)
    #endif
}

// MARK: - App Background Gradient

/// Reusable app background
struct AppBackgroundGradient: View {
    var body: some View {
        Color.appGroupedBackground
            .ignoresSafeArea()
    }
}

// MARK: - Hex Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
