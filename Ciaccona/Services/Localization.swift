import Foundation
import Synchronization

enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    func displayName(language: AppLanguage? = nil) -> String {
        switch self {
        case .system:
            return L10n.tr("settings.language.system", defaultValue: "Follow System", language: language)
        case .english:
            return "English"
        case .simplifiedChinese:
            return "简体中文"
        }
    }
}

enum L10n {
    private final class BundleToken {}

    static let supportedLocalizationCodes = ["en", "zh-Hans"]
    private static let currentLanguageLock = Mutex<AppLanguage>(.system)

    static var currentLanguage: AppLanguage {
        get { currentLanguageLock.withLock { $0 } }
        set { currentLanguageLock.withLock { $0 = newValue } }
    }

    static func syncFromDiskIfNeeded() {
        let language = RuleStore().preferences.language
        currentLanguage = language
        applySystemLanguageOverride(language)
    }

    static func applySystemLanguageOverride(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        switch language {
        case .system:
            defaults.removeObject(forKey: "AppleLanguages")
        case .english:
            defaults.set(["en"], forKey: "AppleLanguages")
        case .simplifiedChinese:
            defaults.set(["zh-Hans"], forKey: "AppleLanguages")
        }
    }

    static func resolvedLanguageCode(
        for language: AppLanguage,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        switch language {
        case .english:
            return "en"
        case .simplifiedChinese:
            return "zh-Hans"
        case .system:
            let matched = Bundle.preferredLocalizations(
                from: supportedLocalizationCodes,
                forPreferences: preferredLanguages
            )
            return matched.first ?? "en"
        }
    }

    static func locale(
        for language: AppLanguage,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> Locale {
        Locale(identifier: resolvedLanguageCode(for: language, preferredLanguages: preferredLanguages))
    }

    static func bundle(
        for language: AppLanguage,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> Bundle {
        let base = Bundle(for: BundleToken.self)
        let code = resolvedLanguageCode(for: language, preferredLanguages: preferredLanguages)
        if let path = base.path(forResource: code, ofType: "lproj"),
           let lproj = Bundle(path: path) {
            return lproj
        }
        if let fallbackPath = base.path(forResource: "en", ofType: "lproj"),
           let enBundle = Bundle(path: fallbackPath) {
            return enBundle
        }
        return base
    }

    static func tr(
        _ key: String,
        defaultValue: String,
        language: AppLanguage? = nil,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        let lang = language ?? currentLanguage
        let targetBundle = bundle(for: lang, preferredLanguages: preferredLanguages)
        return targetBundle.localizedString(forKey: key, value: defaultValue, table: nil)
    }

    static func trFormat(
        _ key: String,
        defaultValue: String,
        language: AppLanguage? = nil,
        preferredLanguages: [String] = Locale.preferredLanguages,
        _ args: CVarArg...
    ) -> String {
        let lang = language ?? currentLanguage
        let format = tr(key, defaultValue: defaultValue, language: lang, preferredLanguages: preferredLanguages)
        return String(format: format, locale: locale(for: lang, preferredLanguages: preferredLanguages), arguments: args)
    }
}
