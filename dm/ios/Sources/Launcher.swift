// Launcher: the settings screen shown before the game starts (front_ios.m dm_show_launcher). Its settings come from the app's dm/launcher.json, which build_ipa.sh writes for this game
// from dm/games/settings.tsv (dm/games/settings.py): each sets an environment variable the host reads when the game starts. A variable an env file set (Documents/env.txt, the bundle's
// dm/env.txt; main.m lists them in DM_ENV_FILE_KEYS) is shown but kept. All settings share one screen, grouped by section. Choices that differ from the game's default are kept
// in UserDefaults; Reset to tested defaults forgets them. DM_LAUNCHER=0 in Documents/env.txt starts the game at once, as an app without launcher.json does
import SwiftUI
import UIKit
import os

private func info(_ key: String) -> Any? { Bundle.main.object(forInfoDictionaryKey: key) }
@_silgen_name("dm_launcher_nextendo_preflight") private func nextendoPreflight() -> UInt32
@_silgen_name("dm_mobile_nextendo_use_keychain") private func installMobileNextendoKeychain()

private extension LauncherModel {
    func binding(_ s: Setting) -> Binding<String> { Binding(get: { self.values[s.env] ?? s.def }, set: { self.values[s.env] = $0 }) }
}

private struct SettingRow: View {
    let s: Setting
    @ObservedObject var m: LauncherModel

    private var locked: Bool { m.fromFile.contains(s.env) }
    private var note: String {
        let base = launcherText(s.note, language: m.uiLanguage)
        return locked ? (base.isEmpty ? "" : base + " · ") + launcherText("Set by an env file", language: m.uiLanguage) : base
    }
    private var rangeValue: Binding<Double> {
        Binding(get: { Double(m.values[s.env] ?? s.def) ?? s.max ?? 1 },
                set: { m.values[s.env] = String(format: "%.2f", $0) })
    }
    private var percentage: String { "\(Int((rangeValue.wrappedValue * 100).rounded())) %" }

    private var settingLabel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(s.label))
            if !note.isEmpty { Text(note).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    var body: some View {
        Group {
            switch s.kind {
            case "choice":
                Picker(selection: m.binding(s)) {
                    ForEach(s.options ?? [], id: \.[0]) { Text(LocalizedStringKey($0[1])).tag($0[0]) }
                } label: {
                    settingLabel
                }
                .pickerStyle(.menu)
            case "range":
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        settingLabel
                        Spacer()
                        Text(percentage).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: rangeValue, in: (s.min ?? 0)...(s.max ?? 1), step: s.step ?? 0.05)
                        .accessibilityLabel(s.label)
                        .accessibilityValue(percentage)
                }
            default:
                Toggle(isOn: Binding(get: { (m.values[s.env] ?? s.def) == s.onValue }, set: { m.values[s.env] = $0 ? s.onValue : s.offValue })) {
                    settingLabel
                }
            }
        }
        .disabled(locked)
    }
}

private struct LauncherNetworkSection: View {
    @ObservedObject var model: LauncherModel
    let openNextendo: () -> Void
    @FocusState private var peerFocused: Bool
    @State private var showingAdvanced = false

    var body: some View {
        Section {
            Picker(selection: $model.networkMode) {
                ForEach(LauncherNetworkMode.allCases) { mode in
                    Text(LocalizedStringKey(mode.title)).tag(mode)
                }
            } label: { Text("Mode") }
            .pickerStyle(.menu)
            .disabled(model.fromFile.contains("DM_NETWORK"))
            if model.fromFile.contains("DM_NETWORK") { Text("Mode is set by an env file.").font(.footnote).foregroundStyle(.secondary) }
            if model.networkMode.usesLocalDiscovery {
                Label(LocalizedStringKey(model.discoveryPeer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Automatic discovery" : "Manual discovery address"), systemImage: "network")
                DisclosureGroup("Advanced connection settings", isExpanded: $showingAdvanced) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Discovery IPv4 (optional)")
                        TextField("Automatic", text: $model.discoveryPeer)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .focused($peerFocused)
                            .onSubmit { peerFocused = false }
                            .accessibilityLabel(Text("Discovery IPv4 (optional)"))
                            .disabled(model.fromFile.contains("DM_NET_DISCOVERY_PEER"))
                        Text("Leave this empty to discover nearby games automatically.").font(.footnote).foregroundStyle(.secondary)
                        if model.fromFile.contains("DM_NET_DISCOVERY_PEER") {
                            Text("Address is set by an env file.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
                if let error = model.networkValidationError {
                    Label(LocalizedStringKey(error), systemImage: "exclamationmark.circle")
                        .font(.footnote).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(LocalizedStringKey(explanation)).font(.footnote).foregroundStyle(.secondary)
            if model.networkMode == .nextendo {
                Button("Set up Nextendo") { openNextendo() }
                Text("Link your account and check this game’s requirements on this iPhone.").font(.footnote).foregroundStyle(.secondary)
            }
            if model.networkMode == .nextendo, let status = model.nextendoStatus {
                Label(LocalizedStringKey(status.hasValidCredential ? "Game credential validated" : "Game credential needs attention"), systemImage: status.hasValidCredential ? "checkmark.shield" : "exclamationmark.shield")
                    .font(.footnote)
                if let message = status.blockingMessage {
                    Label(LocalizedStringKey(message), systemImage: "exclamationmark.circle")
                        .font(.footnote).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: { Text("Network") } footer: {
            if model.networkMode.usesLocalDiscovery {
                Text("Use the same local network and matching game versions. Allow Local Network access when iOS asks.")
            }
        }
        .onChange(of: model.networkMode) { model.nextendoStatus = nil }
    }

    private var explanation: String {
        switch model.networkMode {
        case .offline: "Network services are disabled."
        case .lan: "Use the game's LAN mode to find other players on your local network."
        case .ldn: "Uses a LAN bridge for local wireless. The Switch needs a compatible ldn_mitm module and a matching game version."
        case .nextendo: "Nextendo requires a private game credential on this iPhone and a server-accepted game version. Native online play has not been verified."
        }
    }
}

private struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    @ObservedObject var nextendo: MobileNextendoModel
    let play: () -> Void
    @State private var showingNextendo = false
    @State private var memory = os_proc_available_memory()

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(spacing: 16) {
                    if let icon = appIcon() {
                        Image(uiImage: icon).resizable().frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                            .accessibilityHidden(true)
                    }
                    Text((info("CFBundleDisplayName") as? String) ?? "Game")
                        .font(.title.weight(.bold)).multilineTextAlignment(.center)
                    Text("Version \((info("CFBundleShortVersionString") as? String) ?? "")")
                        .font(.callout).foregroundStyle(.secondary)
                    playButton
                }
                .padding(16)
                .frame(width: geometry.size.width / 3, height: geometry.size.height)
                List {
                    Section {
                        Picker("App language", selection: $m.uiLanguage) {
                            ForEach(LauncherUILanguage.allCases) { language in Text(verbatim: language.title).tag(language) }
                        }
                        Text("Changes the app interface only. The game language is kept separately.").font(.footnote).foregroundStyle(.secondary)
                    }
                    LauncherNetworkSection(model: m, openNextendo: { showingNextendo = true })
                    ForEach(m.sections, id: \.self) { section in
                        Section(LocalizedStringKey(section)) {
                            ForEach(m.settings.filter { $0.sectionTitle == section }) { SettingRow(s: $0, m: m) }
                        }
                    }
                    Section {
                        Button("Reset to tested defaults") { m.reset() }
                            .disabled(!m.changed)
                    } footer: {
                        Text("Brings back all settings this game was tested with.")
                    }
                    Section {
                        HStack {
                            Text("Memory available")
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .contentMargins(.horizontal, 12, for: .scrollContent)
                .frame(width: geometry.size.width * 2 / 3)
            }
        }
        .preferredColorScheme(.dark)
        .environment(\.locale, m.uiLanguage.locale)
        .sheet(isPresented: $showingNextendo, onDismiss: { nextendo.cancel() }) {
            MobileNextendoSetupView(model: nextendo, launcher: m, checkServices: checkNextendoServices)
        }
        .task {
            while !Task.isCancelled {
                memory = os_proc_available_memory()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder var playButton: some View {
        let button = Button(action: attemptPlay) { Text("Play").font(.title3.weight(.semibold)).frame(maxWidth: 220) }
            .controlSize(.large).disabled(m.networkValidationError != nil)
        if #available(iOS 26.0, *) { button.buttonStyle(.glassProminent) } else { button.buttonStyle(.borderedProminent) }
    }

    private func checkNextendoServices() {
        guard m.apply() else { return }
        let status = LauncherNextendoStatus(rawValue: nextendoPreflight())
        m.nextendoStatus = status
        nextendo.updateRoutes(status.routesStatus)
    }

    private func attemptPlay() {
        guard m.apply() else { return }
        if m.networkMode == .nextendo {
            checkNextendoServices()
            guard m.nextendoStatus?.canStart == true, nextendo.mayAttemptGame else {
                showingNextendo = true
                return
            }
        }
        play()
    }

    private func appIcon() -> UIImage? {
        if let i = UIImage(named: "AppIcon") { return i }
        guard let icons = info("CFBundleIcons") as? [String: Any], let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String], let last = files.last else { return nil }
        return UIImage(named: last)
    }
}

// Shows the launcher over the root view controller and calls done once the settings are in the environment; false (done is not called) when there is no launcher
@MainActor @_cdecl("dm_show_launcher")
public func dmShowLauncher(_ viewController: UnsafeMutableRawPointer, _ done: @convention(c) () -> Void) -> Bool {
    // Keychain stays authoritative even when the user disables the launcher.
    installMobileNextendoKeychain()
    if ProcessInfo.processInfo.environment["DM_LAUNCHER"] == "0" { fputs("launcher: off (DM_LAUNCHER=0)\n", stderr); return false }
    guard let url = Bundle.main.resourceURL?.appendingPathComponent("dm/launcher.json"), let data = try? Data(contentsOf: url) else { return false }
    guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else { fputs("[RED] launcher: dm/launcher.json cannot be read; starting the game\n", stderr); return false }
    let parent = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
    let model = LauncherModel(file.settings)
    let nextendo = MobileNextendoModel(browser: MobileNextendoBrowser())
    var host: UIViewController?
    let view = LauncherView(m: model, nextendo: nextendo) {
        guard let h = host else { return }
        host = nil
        h.dismiss(animated: false) { done() }
    }
    let h = UIHostingController(rootView: view)
    h.modalPresentationStyle = .fullScreen
    host = h
    parent.present(h, animated: false)
    fputs("launcher: \(file.settings.count) settings shown\n", stderr)
    return true
}
