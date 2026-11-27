import AppKit
import Combine
import SwiftUI
import PortCore

/// Installed Mac ports as tiles: Play, the port's own settings window, Show in Finder,
/// whether it runs and whether an older engine packed it. The ports never need Studio.
struct LibraryView: View {
    @Bindable var model: StudioModel
    private let workspace = NSWorkspace.shared.notificationCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(t("Installed Mac ports")).font(.headline)
                Spacer()
                Button(t("Refresh")) { Task { await model.reloadLibrary() } }
                    .buttonStyle(QuietButtonStyle()).disabled(model.isLoadingLibrary)
            }
            if model.isLoadingLibrary && model.libraryPorts.isEmpty {
                ProgressView(t("Finding installed ports…"))
            } else if model.libraryPorts.isEmpty {
                StudioPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(t("No native ports found in Applications. Install a Mac port first."))
                            .foregroundStyle(StudioStyle.muted)
                        Button(t("New port")) { model.page = .create }.buttonStyle(QuietButtonStyle())
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], alignment: .leading, spacing: 16) {
                    ForEach(model.libraryPorts) { port in LibraryTile(model: model, port: port) }
                }
            }
            if let message = model.libraryMessage {
                Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.orange).textSelection(.enabled)
            }
            Text(t("Each port runs by itself, with its own Nextendo sign-in and online routes. Studio only opens it, as Finder or the Dock would. Hold Option while you click Play to open the settings window of a port built before Studio could ask for it."))
                .font(.footnote).foregroundStyle(StudioStyle.muted)
        }
        .task { await model.reloadLibrary() }
        .onReceive(workspace.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in model.refreshRunningLibraryPorts() }
        .onReceive(workspace.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in model.refreshRunningLibraryPorts() }
        .onChange(of: model.repositoryPath) { Task { await model.reloadLibrary() } }
    }
}

private struct LibraryTile: View {
    @Bindable var model: StudioModel
    let port: InstalledMacPort

    var body: some View {
        let running = model.libraryPortIsRunning(port)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: port.appURL.path))
                    .resizable().interpolation(.high).frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: port.name).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    Text(verbatim: port.version.isEmpty ? port.titleID : "\(port.version) · \(port.titleID)")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(StudioStyle.muted).textSelection(.enabled)
                    if running {
                        Label(t("Running"), systemImage: "circle.fill").font(.system(size: 11)).foregroundStyle(.green)
                            .labelStyle(.titleAndIcon).imageScale(.small)
                    }
                }
                Spacer(minLength: 0)
            }
            engineNote
            HStack(spacing: 8) {
                Button { Task { await model.openLibraryPort(port) } } label: {
                    Label(running ? t("Show") : t("Play"), systemImage: running ? "macwindow" : "play.fill")
                }.buttonStyle(PrimaryButtonStyle())
                Button { Task { await model.openLibraryPort(port, settings: true) } } label: {
                    Label(t("Settings"), systemImage: "slider.horizontal.3")
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(running || port.engine == nil)
                .help(port.engine == nil ? t("This port was built before Studio could open its settings. Hold Option while you click Play.") : t("Open the port's settings window before the game."))
                Spacer(minLength: 0)
                Button { model.showLibraryPortInFinder(port) } label: { Image(systemName: "folder") }
                    .buttonStyle(QuietButtonStyle()).help(t("Show in Finder")).accessibilityLabel(t("Show in Finder"))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 16))
        .contextMenu {
            Button(running ? t("Show") : t("Play")) { Task { await model.openLibraryPort(port) } }
            Button(t("Settings")) { Task { await model.openLibraryPort(port, settings: true) } }.disabled(running || port.engine == nil)
            Button(t("Show in Finder")) { model.showLibraryPortInFinder(port) }
        }
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
        Button { model.page = .create } label: {
            Label(text, systemImage: "arrow.triangle.2.circlepath").font(.system(size: 12)).multilineTextAlignment(.leading)
        }
        .buttonStyle(.plain).foregroundStyle(StudioStyle.signal)
    }
}
