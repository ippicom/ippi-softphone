//
//  LanguageService.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case french = "fr"
    case english = "en"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .system: return String(localized: "settings.language.system")
        case .french: return String(localized: "settings.language.french")
        case .english: return String(localized: "settings.language.english")
        }
    }
    
    var locale: Locale? {
        switch self {
        case .system: return nil
        case .french: return Locale(identifier: "fr")
        case .english: return Locale(identifier: "en")
        }
    }
}

@MainActor
@Observable
final class LanguageService {
    static let shared = LanguageService()
    
    private let userDefaultsKey = "AppLanguage"
    
    var currentLanguage: AppLanguage {
        didSet {
            saveLanguage()
            applyLanguage()
        }
    }
    
    private init() {
        if let savedValue = UserDefaults.standard.string(forKey: userDefaultsKey),
           let language = AppLanguage(rawValue: savedValue) {
            currentLanguage = language
        } else {
            currentLanguage = .system
        }
    }
    
    private func saveLanguage() {
        UserDefaults.standard.set(currentLanguage.rawValue, forKey: userDefaultsKey)
    }
    
    private func applyLanguage() {
        let languageCode: String?
        switch currentLanguage {
        case .system:
            languageCode = nil
        case .french:
            languageCode = "fr"
        case .english:
            languageCode = "en"
        }
        
        if let code = languageCode {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }
    
    var effectiveLanguageCode: String {
        switch currentLanguage {
        case .system:
            return Locale.current.language.languageCode?.identifier ?? "en"
        case .french:
            return "fr"
        case .english:
            return "en"
        }
    }
}
