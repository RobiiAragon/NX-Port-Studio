import Foundation
import Observation

enum StudioLanguage: String, CaseIterable, Identifiable, Sendable {
    case spanish = "es", english = "en", french = "fr", japanese = "ja", simplifiedChinese = "zh-Hans"

    var id: String { rawValue }
    var nativeName: String {
        switch self {
        case .spanish: "Español"
        case .english: "English"
        case .french: "Français"
        case .japanese: "日本語"
        case .simplifiedChinese: "简体中文"
        }
    }
}

@MainActor @Observable
final class StudioLocalization {
    static let shared = StudioLocalization()
    static let preferenceKey = "appInterfaceLanguage"
    private static let resources: Bundle? = {
        #if DEBUG
        return Bundle.module
        #else
        // SwiftPM's development fallback embeds an absolute checkout path.
        // A release app resolves the copied resource bundle beside itself.
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("NXPortStudio_PortStudio.bundle") else { return nil }
        return Bundle(url: url)
        #endif
    }()
    @ObservationIgnored private let defaults: UserDefaults

    var language: StudioLanguage {
        didSet { defaults.set(language.rawValue, forKey: Self.preferenceKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = defaults.string(forKey: Self.preferenceKey).flatMap(StudioLanguage.init(rawValue:)) ?? .spanish
    }

    var locale: Locale { Locale(identifier: language.rawValue) }

    func string(_ key: String) -> String {
        // Reading the observable preference here invalidates the views that
        // resolve text. Switching language keeps their models and tasks alive.
        guard let url = Self.resources?.url(forResource: language.rawValue, withExtension: "lproj", subdirectory: "Resources"),
              let bundle = Bundle(url: url) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}

@MainActor
func t(_ key: String) -> String { StudioLocalization.shared.string(key) }
