import Foundation
import XCTest
@testable import PortStudio

@MainActor
final class LocalizationTests: XCTestCase {
    func testSpanishDefaultAndIndependentPersistedChoice() throws {
        let name = "StudioLanguageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["en"], forKey: "AppleLanguages")
        let first = StudioLocalization(defaults: defaults)
        XCTAssertEqual(first.language, .spanish)
        XCTAssertEqual(first.string("New port"), "Nuevo port")
        first.language = .japanese
        XCTAssertEqual(StudioLocalization(defaults: defaults).language, .japanese)
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])
        defaults.set("unsupported", forKey: StudioLocalization.preferenceKey)
        XCTAssertEqual(StudioLocalization(defaults: defaults).language, .spanish)
    }

    func testEveryLanguageIsBundledAndUnknownKeysRemainReadable() throws {
        let name = "StudioLanguageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let localization = StudioLocalization(defaults: defaults)
        for language in StudioLanguage.allCases {
            localization.language = language
            let title = localization.string("New port")
            XCTAssertFalse(title.isEmpty)
            if language == .english { XCTAssertEqual(title, "New port") }
            else { XCTAssertNotEqual(title, "New port", "Missing bundled \(language.rawValue) translation") }
            XCTAssertEqual(localization.string("__unknown_fixture_key__"), "__unknown_fixture_key__")
        }
    }

    func testTranslationCoverageAndFormatArgumentsMatch() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resources = package.appendingPathComponent("Sources/PortStudio/Resources")
        func table(_ code: String) throws -> [String: String] {
            let data = try Data(contentsOf: resources.appendingPathComponent("\(code).lproj/Localizable.strings"))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }
        let english = try table("en")
        let pattern = try NSRegularExpression(pattern: #"%(?:[0-9]+\$)?(?:ll|l)?[@diufg]"#)
        func placeholders(_ value: String) -> [String] {
            pattern.matches(in: value, range: NSRange(value.startIndex..., in: value)).map { (value as NSString).substring(with: $0.range) }.sorted()
        }
        for language in StudioLanguage.allCases {
            let translated = try table(language.rawValue)
            XCTAssertEqual(Set(translated.keys), Set(english.keys), language.rawValue)
            for (key, value) in translated {
                XCTAssertFalse(value.isEmpty, key)
                XCTAssertEqual(placeholders(value), placeholders(english[key] ?? ""), "\(language.rawValue): \(key)")
            }
        }
    }
}
