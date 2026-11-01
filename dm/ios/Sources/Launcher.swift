// Launcher: the settings screen shown before the game starts (front_ios.m dm_show_launcher). Its settings come from the app's dm/launcher.json, which build_ipa.sh writes for this game
// from dm/games/settings.tsv (dm/games/settings.py): each sets an environment variable the host reads when the game starts. A variable an env file set (Documents/env.txt, the bundle's
// dm/env.txt; main.m lists them in DM_ENV_FILE_KEYS) is shown but kept. All settings share one screen, grouped by section (rows: LauncherRow.swift). Choices that differ from the game's default are kept
// in UserDefaults; Reset to tested defaults shows the defaults, and Play then forgets them. DM_LAUNCHER=0 in Documents/env.txt starts the game at once with the saved choices; DM_SAVED_CHOICES=0 ignores them (and keeps them)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os

private func info(_ key: String) -> Any? { Bundle.main.object(forInfoDictionaryKey: key) }
@_silgen_name("dm_launcher_nextendo_preflight") private func nextendoPreflight() -> UInt32
@_silgen_name("dm_mobile_nextendo_use_keychain") private func installMobileNextendoKeychain()


/// Cloud saves: an iCloud Drive folder shared with the Mac app (chosen in its settings window's
/// Cloud saves too). The host brings the save in from there when the game starts and
/// sends it there after each save (dm/host/save_sync.h); the folder is a bookmark (CloudSaves.m).
private struct CloudSavesSection: View {
    @State private var folder: String = ""
    @State private var note: String = ""
    @State private var picking = false

    var body: some View {
        Section {
            HStack {
                Text("Cloud saves")
                Spacer()
                Text(folder.isEmpty ? "Off" : (folder as NSString).lastPathComponent)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Button(folder.isEmpty ? "Choose a folder in iCloud Drive…" : "Choose a different folder…") { picking = true }
            if !folder.isEmpty {
                Button("Turn off cloud saves", role: .destructive) {
                    dm_clear_cloud_saves(); refresh(); note = ""
                }
            }
        } footer: {
            Text(note.isEmpty
                 ? "Choose a folder in iCloud Drive, and the same one in the Mac app's Cloud saves. The save comes in when the game starts and goes out after each save; a save that is replaced is kept in save-backups."
                 : note)
        }
        .sheet(isPresented: $picking) {
            DocumentPicker(types: [.folder]) { url in
                picking = false
                if dm_store_cloud_saves(url) {
                    note = "Saved. The game uses this folder when you press Play."
                    refresh()
                } else {
                    note = "That folder could not be remembered — try a different one."
                }
            } onCancel: { picking = false }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        var stale: ObjCBool = false
        folder = dm_cloud_saves_path(&stale) ?? ""
        if stale.boolValue && folder.isEmpty {
            note = "The folder you chose before is no longer readable (the app was signed differently). Please choose it again."
        }
    }
}

/// UIDocumentPickerViewController for a folder, in the two callbacks a SwiftUI sheet wants.
private struct DocumentPicker: UIViewControllerRepresentable {
    var types: [UTType] = [.folder]
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // .open (not .import): the folder stays where it is and the bookmark keeps pointing at it.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick; self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) } else { onCancel() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onCancel() }
    }
}

private struct LauncherNetworkSection: View {
    @ObservedObject var model: LauncherModel
    let openNextendo: () -> Void
    @FocusState private var peerFocused: Bool
    @State private var showingAdvanced = false

    var body: some View {
        Section {
            Label(LocalizedStringKey(model.networkMode.title), systemImage: model.networkMode == .offline ? "network.slash" : "network")
            Text(LocalizedStringKey(explanation)).font(.footnote).foregroundStyle(.secondary)
            if model.fromFile.contains("DM_NETWORK") { Text("Mode is set by an env file.").font(.footnote).foregroundStyle(.secondary) }
            DisclosureGroup("Advanced connection settings", isExpanded: $showingAdvanced) {
                Toggle("Disable network services", isOn: Binding(get: { model.networkMode == .offline }, set: { model.networkMode = $0 ? .offline : .automatic }))
                    .disabled(model.fromFile.contains("DM_NETWORK"))
                if model.networkMode.usesLocalDiscovery {
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
                    if let error = model.networkValidationError {
                        Label(LocalizedStringKey(error), systemImage: "exclamationmark.circle")
                            .font(.footnote).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if model.networkMode.supportsNextendo {
                Button("Set up Nextendo") { openNextendo() }
                Text("Link your account and check this game’s requirements on this iPhone.").font(.footnote).foregroundStyle(.secondary)
            }
            if model.networkMode.supportsNextendo, let status = model.nextendoStatus {
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
        case .automatic: "Choose Online, Local wireless or LAN inside the game. Nextendo, LDN and LAN are available together; no restart is needed to switch between them."
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
    @State private var isStartingGame = false
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
                            ForEach(m.rows(in: section)) { SettingRow(s: $0, m: m) }
                        }
                    }
                    Section {
                        Button("Reset to tested defaults") { m.reset() }
                            .disabled(!m.changed)
                    } footer: {
                        Text("Brings back all settings this game was tested with.")
                    }
                    CloudSavesSection()
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
            .controlSize(.large).disabled(m.networkValidationError != nil || isStartingGame ||
                (m.networkMode == .nextendo && (nextendo.isPreparingServices || nextendo.isLoading)))
        if #available(iOS 26.0, *) { button.buttonStyle(.glassProminent) } else { button.buttonStyle(.borderedProminent) }
    }

    private func checkNextendoServices() {
        guard m.apply() else { return }
        let status = LauncherNextendoStatus(rawValue: nextendoPreflight())
        m.nextendoStatus = status
        nextendo.updateRoutes(status.routesStatus)
    }

    private func attemptPlay() {
        guard !isStartingGame, m.apply() else { return }
        isStartingGame = true
        if m.networkMode == .nextendo {
            Task {
                defer { isStartingGame = false }
                await nextendo.load()
                guard m.networkMode == .nextendo else { return }
                checkNextendoServices()
                guard m.nextendoStatus?.canStart == true, nextendo.mayAttemptGame else {
                    showingNextendo = true
                    return
                }
                play()
            }
            return
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
    guard let url = Bundle.main.resourceURL?.appendingPathComponent("dm/launcher.json"), let data = try? Data(contentsOf: url) else { return false }
    guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else { fputs("[RED] launcher: dm/launcher.json cannot be read; starting the game\n", stderr); return false }
    if ProcessInfo.processInfo.environment["DM_LAUNCHER"] == "0" { LauncherModel(file.settings).applySaved(); fputs("launcher: off (DM_LAUNCHER=0)\n", stderr); return false }
    let parent = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
    let model = LauncherModel(file.settings, maximumFramesPerSecond: parent.view.window?.windowScene?.screen.maximumFramesPerSecond ?? 0)
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
