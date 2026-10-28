import Foundation

enum LauncherUILanguage: String, CaseIterable, Identifiable {
    case spanish = "es", english = "en", french = "fr", japanese = "ja", simplifiedChinese = "zh-Hans"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .spanish: "Español"
        case .english: "English"
        case .french: "Français"
        case .japanese: "日本語"
        case .simplifiedChinese: "简体中文"
        }
    }
    var locale: Locale { Locale(identifier: rawValue) }
}

func launcherText(_ key: String, language: LauncherUILanguage) -> String {
    guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
          let localized = Bundle(path: path) else { return key }
    return localized.localizedString(forKey: key, value: key, table: nil)
}
