import AppKit
import Combine
import SwiftUI
import PortCore

/// Installed Mac ports as a home menu: a row of large tiles, the most recently played
/// first, with one focused game and its Play action; a top bar with the time, the Nextendo
/// account and friends online; a hint bar with the keys. Arrow keys move the focus, Return
/// plays, Option-Return opens the port's settings window, F and Escape enter and leave full
/// screen. The interaction follows console home menus; the look is Studio's own. The ports
/// never need Studio: it opens them as Finder or the Dock would.
struct LibraryView: View {
    @Bindable var model: StudioModel
    @FocusState private var focused: Bool
    private let workspace = NSWorkspace.shared.notificationCenter

    var body: some View {
        VStack(alignment: .leading, spacing: model.libraryFullScreen ? 0 : 22) {
            LibraryTopBar(model: model)
            if model.libraryFullScreen { Spacer(minLength: 24) }
            if model.isLoadingLibrary && model.libraryPorts.isEmpty {
                ProgressView(t("Finding installed ports…")).frame(maxWidth: .infinity, minHeight: 240)
            } else if model.libraryPorts.isEmpty {
                empty
            } else {
                LibraryRow(model: model)
                if let port = model.selectedLibraryPort { LibraryDetail(model: model, port: port).padding(.top, 18) }
            }
            if let message = model.libraryMessage {
                Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.orange).textSelection(.enabled).padding(.top, 12)
            }
            if model.libraryFullScreen { Spacer(minLength: 24) }
            LibraryHintBar(fullScreen: model.libraryFullScreen)
            if !model.libraryFullScreen {
                Text(t("Each port runs by itself, with its own Nextendo sign-in and online routes. Studio only opens it, as Finder or the Dock would. Hold Option while you click Play to open the settings window of a port built before Studio could ask for it."))
                    .font(.footnote).foregroundStyle(StudioStyle.muted)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in handle(press) }
        .onAppear { focused = true }
        .task { await model.reloadLibrary() }
        .task {
            while !Task.isCancelled {
                await model.refreshLibraryFriends()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onReceive(workspace.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in model.refreshRunningLibraryPorts() }
        // A port that quits has just been played: the row puts it first.
        .onReceive(workspace.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in Task { await model.reloadLibrary() } }
        .onChange(of: model.repositoryPath) { Task { await model.reloadLibrary() } }
    }

    private var empty: some View {
        StudioPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text(t("No native ports found in Applications. Install a Mac port first."))
                    .foregroundStyle(StudioStyle.muted)
                Button(t("New port")) { model.setLibraryFullScreen(false); model.page = .create }.buttonStyle(QuietButtonStyle())
            }
        }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .leftArrow: model.moveLibrarySelection(by: -1); return .handled
        case .rightArrow: model.moveLibrarySelection(by: 1); return .handled
        case .return:
            guard let port = model.selectedLibraryPort else { return .ignored }
            let settings = press.modifiers.contains(.option) && port.engine != nil && !model.libraryPortIsRunning(port)
            Task { await model.openLibraryPort(port, settings: settings) }
            return .handled
        case .escape:
            guard model.libraryFullScreen else { return .ignored }
            model.setLibraryFullScreen(false); return .handled
        default:
            guard press.characters.lowercased() == "f", press.modifiers.isEmpty else { return .ignored }
            model.setLibraryFullScreen(!model.libraryFullScreen); return .handled
        }
    }
}

private struct LibraryTopBar: View {
    @Bindable var model: StudioModel

    var body: some View {
        HStack(spacing: 18) {
            TimelineView(.everyMinute) { context in
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: 20, weight: .semibold)).monospacedDigit()
            }
            Spacer()
            if let online = model.libraryFriendsOnline {
                Label(String(format: t("%lld friends online"), online), systemImage: "person.2")
                    .font(.system(size: 13)).foregroundStyle(online > 0 ? .white : StudioStyle.muted)
            }
            Label(model.nextendoAccount?.identity?.username ?? (model.nextendoAccount == nil ? t("Not signed in to Nextendo") : t("Nextendo")),
                  systemImage: "person.crop.circle")
                .font(.system(size: 13)).foregroundStyle(model.nextendoAccount == nil ? StudioStyle.muted : .white)
            Button { model.setLibraryFullScreen(!model.libraryFullScreen) } label: {
                Image(systemName: model.libraryFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(QuietButtonStyle())
            .help(model.libraryFullScreen ? t("Exit full screen") : t("Full screen"))
            .accessibilityLabel(model.libraryFullScreen ? t("Exit full screen") : t("Full screen"))
        }
    }
}

private struct LibraryRow: View {
    @Bindable var model: StudioModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 22) {
                    ForEach(model.libraryPorts) { port in
                        LibraryTile(model: model, port: port, selected: port.id == model.selectedLibraryPort?.id).id(port.id)
                    }
                }
                .padding(.vertical, 16).padding(.horizontal, 6)
            }
            .onChange(of: model.librarySelection) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

private struct LibraryTile: View {
    @Bindable var model: StudioModel
    let port: InstalledMacPort
    let selected: Bool

    var body: some View {
        let size: CGFloat = model.libraryFullScreen ? 240 : 196
        VStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 26).fill(selected ? StudioStyle.raised : StudioStyle.surface)
                Image(nsImage: NSWorkspace.shared.icon(forFile: port.appURL.path))
                    .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .padding(size * 0.14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.libraryPortIsRunning(port) {
                    Circle().fill(.green).frame(width: 12, height: 12).padding(16)
                        .accessibilityLabel(t("Running"))
                }
            }
            .frame(width: size, height: size)
            .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(selected ? StudioStyle.signal : .white.opacity(0.06), lineWidth: selected ? 3 : 1))
            .shadow(color: .black.opacity(selected ? 0.5 : 0), radius: 18, y: 8)
            Text(verbatim: port.name)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .white : StudioStyle.muted)
                .lineLimit(1).frame(width: size)
        }
        .scaleEffect(selected ? 1.05 : 1)
        .opacity(selected ? 1 : 0.78)
        .animation(.easeOut(duration: 0.15), value: selected)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { Task { await model.openLibraryPort(port) } }
        .onTapGesture { model.librarySelection = port.id }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .contextMenu {
            let running = model.libraryPortIsRunning(port)
            Button(running ? t("Show") : t("Play")) { Task { await model.openLibraryPort(port) } }
            Button(t("Settings")) { Task { await model.openLibraryPort(port, settings: true) } }.disabled(running || port.engine == nil)
            Button(t("Show in Finder")) { model.showLibraryPortInFinder(port) }
        }
    }
}

/// The focused game: its name, version, title ID, state and actions, with a large Play.
private struct LibraryDetail: View {
    @Bindable var model: StudioModel
    let port: InstalledMacPort

    var body: some View {
        let running = model.libraryPortIsRunning(port)
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: port.name).font(.system(size: model.libraryFullScreen ? 30 : 24, weight: .semibold)).lineLimit(2)
                Text(verbatim: port.version.isEmpty ? port.titleID : "\(port.version) · \(port.titleID)")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(StudioStyle.muted).textSelection(.enabled)
                HStack(spacing: 14) {
                    if running {
                        Label(t("Running"), systemImage: "circle.fill").foregroundStyle(.green).imageScale(.small)
                    } else if let played = port.lastPlayed {
                        Text(String(format: t("Last played %@"), played.formatted(.relative(presentation: .named).locale(StudioLocalization.shared.locale))))
                            .foregroundStyle(StudioStyle.muted)
                    }
                }.font(.system(size: 12))
                engineNote.padding(.top, 2)
            }
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                Button { Task { await model.openLibraryPort(port) } } label: {
                    Label(running ? t("Show") : t("Play"), systemImage: running ? "macwindow" : "play.fill")
                        .font(.system(size: 17, weight: .semibold)).padding(.horizontal, 18).frame(minHeight: 46)
                }.buttonStyle(PrimaryButtonStyle())
                Button { Task { await model.openLibraryPort(port, settings: true) } } label: {
                    Label(t("Settings"), systemImage: "slider.horizontal.3")
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(running || port.engine == nil)
                .help(port.engine == nil ? t("This port was built before Studio could open its settings. Hold Option while you click Play.") : t("Open the port's settings window before the game."))
                Button { model.showLibraryPortInFinder(port) } label: { Image(systemName: "folder") }
                    .buttonStyle(QuietButtonStyle()).help(t("Show in Finder")).accessibilityLabel(t("Show in Finder"))
            }
        }
        .padding(22)
        .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder private var engineNote: some View {
        switch model.engineAge(of: port) {
        case .current:
            Label(t("Built with this Studio's engine"), systemImage: "checkmark.circle").font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
        case .older:
            rebuildNote(t("Built with an older engine. Rebuild it in New port to pick up the latest host fixes."))
        case .unstamped:
            rebuildNote(t("Built before ports recorded their engine. Rebuild it in New port to pick up the latest host fixes."))
        case .newer:
            Label(t("Built with a newer engine than this Studio"), systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
        case .different:
            Label(t("Built with another revision of the engine"), systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
        case .unknown:
            EmptyView()
        }
    }

    private func rebuildNote(_ text: String) -> some View {
        Button { model.setLibraryFullScreen(false); model.page = .create } label: {
            Label(text, systemImage: "arrow.triangle.2.circlepath").font(.system(size: 12)).multilineTextAlignment(.leading)
        }
        .buttonStyle(.plain).foregroundStyle(StudioStyle.signal)
    }
}

/// The keys the Library answers, drawn as Studio's own key caps.
private struct LibraryHintBar: View {
    let fullScreen: Bool

    var body: some View {
        HStack(spacing: 22) {
            hint(["←", "→"], t("Choose"))
            hint(["⏎"], t("Play"))
            hint(["⌥", "⏎"], t("Settings"))
            if fullScreen { hint(["esc"], t("Exit full screen")) } else { hint(["F"], t("Full screen")) }
            Spacer()
        }
        .font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
        .padding(.vertical, 12).padding(.horizontal, 16)
        .background(StudioStyle.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
    }

    private func hint(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: 6) {
            ForEach(keys, id: \.self) { key in
                Text(verbatim: key).font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 6).frame(minWidth: 22, minHeight: 20)
                    .background(StudioStyle.raised, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.12)))
                    .foregroundStyle(.white)
            }
            Text(label)
        }
        .accessibilityElement(children: .combine)
    }
}
