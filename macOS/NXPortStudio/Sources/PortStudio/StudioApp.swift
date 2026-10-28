import SwiftUI
import AppKit

@main
struct StudioApp: App {
    @State private var model = StudioModel()
    @State private var localization = StudioLocalization.shared
    var body: some Scene {
        Window("NX Port Studio", id: "main") {
            StudioView(model: model)
                .environment(\.locale, localization.locale)
                .preferredColorScheme(.dark)
                .frame(minWidth: 900, minHeight: 660)
                .task { await model.initialize() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.runner.cancelImmediately() }
        }
        .defaultSize(width: 1160, height: 810)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu(t("Language")) {
                Picker(t("Interface language"), selection: $localization.language) {
                    ForEach(StudioLanguage.allCases) { language in
                        Text(verbatim: language.nativeName).tag(language)
                    }
                }
            }
            CommandGroup(after: .help) {
                Button(t("NX Port Studio documentation")) { model.openURL("https://github.com/RobiiAragon/NX-Port-Studio") }
                Button(t("nxnative documentation")) { model.openURL("https://github.com/seedds/nxnative") }
                Button(t("Mac guide")) { model.openURL("https://www.applegamingwiki.com/wiki/Nxnative_Switch_to_Mac_conversion") }
            }
        }
    }
}
