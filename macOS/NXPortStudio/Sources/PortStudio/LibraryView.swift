import AppKit
import Combine
import SwiftUI
import PortCore

/// Installed Mac ports laid out as a console home menu, in Studio's own look: the player and
/// friends online at the top left, the time at the top right; the focused game's name over
/// a row of large tiles, the most recently played first; a row of round shortcuts under it;
/// the keys at the bottom. A friends screen (the friend list, received and sent requests)
/// opens from the avatar or the Friends shortcut. Arrow keys move between and along the rows,
/// Return opens, Option-Return opens a port's settings window, F toggles full screen and
/// Escape goes back. The ports never need Studio: it opens them as Finder or the Dock would.
struct LibraryView: View {
    @Bindable var model: StudioModel
    @FocusState private var focused: Bool
    private let workspace = NSWorkspace.shared.notificationCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LibraryTopBar(model: model)
            switch model.libraryScreen {
            case .home: LibraryHome(model: model)
            case .friends: LibraryFriendsScreen(model: model)
            }
            LibraryHintBar(model: model).padding(.top, model.libraryFullScreen ? 0 : 22)
            if !model.libraryFullScreen {
                Text(t("Each port runs by itself, with its own Nextendo sign-in and online routes. Studio only opens it, as Finder or the Dock would. Hold Option while you click Play to open the settings window of a port built before Studio could ask for it."))
                    .font(.footnote).foregroundStyle(StudioStyle.muted).padding(.top, 14)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in model.handleLibraryKey(press) ? .handled : .ignored }
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
}

private extension StudioModel {
    func handleLibraryKey(_ press: KeyPress) -> Bool {
        let key: LibraryKey? = switch press.key {
        case .leftArrow: .left
        case .rightArrow: .right
        case .upArrow: .up
        case .downArrow: .down
        case .return: press.modifiers.contains(.option) ? .alternate : .activate
        case .escape: .back
        default: press.characters.lowercased() == "f" && press.modifiers.isEmpty ? .fullScreen : nil
        }
        return key.map { handleLibraryKey($0) } ?? false
    }
}

// MARK: Top bar

/// A player's round badge: the initial on a colour taken from the account number. Original
/// to Studio; no console artwork.
struct LibraryAvatar: View {
    /// Nil before an account is linked: a person glyph instead of an initial.
    let name: String?
    let seed: UInt64
    var size: CGFloat = 40
    var status: Int? = nil
    /// The player's own picture and colour from the provider, when they chose them.
    var picture: URL? = nil
    var color: String? = nil
    var favorite = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(name == nil ? StudioStyle.raised : color.flatMap(Color.init(hex:)) ?? Color(hue: Double(seed % 360) / 360, saturation: 0.45, brightness: 0.62))
                .overlay {
                    if let name, let initial = name.first {
                        Text(verbatim: String(initial).uppercased())
                            .font(.system(size: size * 0.44, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    } else {
                        Image(systemName: "person.fill").font(.system(size: size * 0.42)).foregroundStyle(.white.opacity(0.85))
                    }
                }
                .overlay {
                    if let picture {
                        AsyncImage(url: picture) { image in image.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.clear }
                            .clipShape(Circle())
                    }
                }
                .frame(width: size, height: size)
            if favorite {
                Image(systemName: "star.fill").font(.system(size: size * 0.2)).foregroundStyle(StudioStyle.signal)
                    .padding(size * 0.05).background(StudioStyle.ground, in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            if let status, status > 0 {
                Circle().fill(status == 2 ? Color.green : Color.blue)
                    .frame(width: size * 0.28, height: size * 0.28)
                    .overlay(Circle().strokeBorder(StudioStyle.ground, lineWidth: 2))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension Color {
    /// `#rrggbb`, as the provider gives a profile colour.
    init?(hex: String) {
        guard hex.count == 7, hex.first == "#", let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

extension LibraryAvatar {
    init(friend: NextendoFriend, size: CGFloat, showsStatus: Bool = false) {
        self.init(name: friend.name, seed: friend.pid, size: size, status: showsStatus ? friend.status : nil,
                  picture: friend.avatarURL, color: friend.color, favorite: friend.favorite && showsStatus)
    }
}

private struct LibraryTopBar: View {
    @Bindable var model: StudioModel

    var body: some View {
        HStack(spacing: 14) {
            Button { model.libraryScreen = model.libraryScreen == .friends ? .home : .friends } label: {
                HStack(spacing: 10) {
                    ZStack(alignment: .topTrailing) {
                        LibraryAvatar(name: accountName, seed: model.nextendoAccount?.identity?.pid ?? 0, size: 42)
                            .overlay(Circle().strokeBorder(model.libraryScreen == .friends ? StudioStyle.signal : .white.opacity(0.15), lineWidth: 2))
                        if let pending = model.nextendoFriends?.requests.count, pending > 0 {
                            Text(verbatim: "\(pending)").font(.system(size: 10, weight: .bold)).foregroundStyle(.black)
                                .frame(minWidth: 16, minHeight: 16).background(StudioStyle.signal, in: Circle()).offset(x: 4, y: -4)
                        }
                    }
                    // Up to five friends online beside the player, as small badges.
                    HStack(spacing: -8) {
                        ForEach(model.libraryFriends.filter(\.isOnline).prefix(5)) { friend in
                            LibraryAvatar(friend: friend, size: 28)
                                .overlay(Circle().strokeBorder(StudioStyle.ground, lineWidth: 2))
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .help(t("Friends"))
            .accessibilityLabel(t("Friends"))
            if let online = model.libraryFriendsOnline {
                Text(String(format: t("%lld friends online"), online)).font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
            }
            Spacer()
            TimelineView(.everyMinute) { context in
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: 20, weight: .medium)).monospacedDigit()
            }
        }
    }

    private var accountName: String? { model.nextendoAccount?.identity?.username }
}

// MARK: Home

private struct LibraryHome: View {
    @Bindable var model: StudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.libraryFullScreen { Spacer(minLength: 20) }
            if model.isLoadingLibrary && model.libraryPorts.isEmpty {
                ProgressView(t("Finding installed ports…")).frame(maxWidth: .infinity, minHeight: 300)
            } else if model.libraryPorts.isEmpty {
                StudioPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(t("No native ports found in Applications. Install a Mac port first."))
                            .foregroundStyle(StudioStyle.muted)
                        Button(t("New port")) { model.leaveLibrary(to: .create) }.buttonStyle(QuietButtonStyle())
                    }
                }.padding(.vertical, 40)
            } else {
                LibraryTitle(model: model).padding(.top, 34)
                LibraryRowView(model: model)
            }
            LibraryShortcuts(model: model).padding(.top, 10)
            if model.libraryFullScreen { Spacer(minLength: 20) }
            if let message = model.libraryMessage {
                Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.orange).textSelection(.enabled).padding(.top, 12)
            }
        }
    }
}

/// The focused game's name over the row, with its version, title ID and state.
private struct LibraryTitle: View {
    @Bindable var model: StudioModel

    var body: some View {
        if let port = model.selectedLibraryPort {
            let running = model.libraryPortIsRunning(port)
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: port.name).font(.system(size: model.libraryFullScreen ? 26 : 22, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(model.libraryRow == .games ? .white : StudioStyle.muted)
                HStack(spacing: 12) {
                    Text(verbatim: port.version.isEmpty ? port.titleID : "\(port.version) · \(port.titleID)")
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    if running {
                        Label(t("Running"), systemImage: "circle.fill").foregroundStyle(.green).imageScale(.small)
                    } else if let played = port.lastPlayed {
                        Text(String(format: t("Last played %@"), played.formatted(.relative(presentation: .named).locale(StudioLocalization.shared.locale))))
                    }
                    engineNote(port)
                }
                .font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
            }
            .padding(.leading, 6)
        }
    }

    @ViewBuilder private func engineNote(_ port: InstalledMacPort) -> some View {
        switch model.engineAge(of: port) {
        case .older: rebuild(t("Built with an older engine. Rebuild it in New port to pick up the latest host fixes."))
        case .unstamped: rebuild(t("Built before ports recorded their engine. Rebuild it in New port to pick up the latest host fixes."))
        case .current: Label(t("Built with this Studio's engine"), systemImage: "checkmark.circle")
        case .newer: Label(t("Built with a newer engine than this Studio"), systemImage: "info.circle")
        case .different: Label(t("Built with another revision of the engine"), systemImage: "info.circle")
        case .unknown: EmptyView()
        }
    }

    private func rebuild(_ text: String) -> some View {
        Button { model.leaveLibrary(to: .create) } label: {
            Label(t("Rebuild to update its engine"), systemImage: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(.plain).foregroundStyle(StudioStyle.signal).help(text)
    }
}

private struct LibraryRowView: View {
    @Bindable var model: StudioModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(model.libraryPorts) { port in
                        LibraryTile(model: model, port: port,
                                    selected: port.id == model.selectedLibraryPort?.id,
                                    active: model.libraryRow == .games).id(port.id)
                    }
                }
                .padding(.vertical, 18).padding(.horizontal, 8)
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
    let active: Bool

    var body: some View {
        let size: CGFloat = model.libraryFullScreen ? 256 : 210
        let running = model.libraryPortIsRunning(port)
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 10).fill(StudioStyle.surface)
            Image(nsImage: NSWorkspace.shared.icon(forFile: port.appURL.path))
                .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .padding(size * 0.1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if running {
                Circle().fill(.green).frame(width: 12, height: 12).padding(12).accessibilityHidden(true)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        // The focus ring sits a little outside the tile; it dims while the shortcuts have the focus.
        .padding(5)
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(selected ? StudioStyle.signal.opacity(active ? 1 : 0.35) : .clear, lineWidth: 4))
        .shadow(color: .black.opacity(selected && active ? 0.55 : 0), radius: 16, y: 8)
        .animation(.easeOut(duration: 0.15), value: selected)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { Task { await model.openLibraryPort(port) } }
        .onTapGesture { model.libraryRow = .games; model.librarySelection = port.id }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: port.name))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .help(port.name)
        .contextMenu {
            Button(running ? t("Show") : t("Play")) { Task { await model.openLibraryPort(port) } }
            Button(t("Settings")) { Task { await model.openLibraryPort(port, settings: true) } }.disabled(running || port.engine == nil)
            Button(t("Show in Finder")) { model.showLibraryPortInFinder(port) }
        }
    }
}

/// The round shortcuts under the games; the focused one shows its name.
private struct LibraryShortcuts: View {
    @Bindable var model: StudioModel

    var body: some View {
        HStack(spacing: 26) {
            Spacer()
            ForEach(Array(LibraryShortcut.allCases.enumerated()), id: \.offset) { index, shortcut in
                let focused = model.libraryRow == .shortcuts && model.libraryShortcut == index
                VStack(spacing: 8) {
                    Button { model.runLibraryShortcut(shortcut) } label: {
                        Image(systemName: shortcut == .fullScreen && model.libraryFullScreen ? "arrow.down.right.and.arrow.up.left" : shortcut.icon)
                            .font(.system(size: 20, weight: .medium))
                            .frame(width: 58, height: 58)
                            .background(StudioStyle.raised, in: Circle())
                            .overlay(Circle().strokeBorder(focused ? StudioStyle.signal : .white.opacity(0.08), lineWidth: focused ? 3 : 1))
                            .overlay(alignment: .topTrailing) {
                                if shortcut == .friends, let pending = model.nextendoFriends?.requests.count, pending > 0 {
                                    Circle().fill(StudioStyle.signal).frame(width: 12, height: 12)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(title(shortcut))
                    .accessibilityLabel(title(shortcut))
                    Text(title(shortcut)).font(.system(size: 11)).foregroundStyle(focused ? .white : .clear).lineLimit(1).fixedSize()
                }
            }
            Spacer()
        }
    }

    private func title(_ shortcut: LibraryShortcut) -> String {
        switch shortcut {
        case .friends: t("Friends")
        case .newPort: t("New port")
        case .saves: t("Saved games")
        case .nextendo: t("Nextendo")
        case .fullScreen: model.libraryFullScreen ? t("Exit full screen") : t("Full screen")
        }
    }
}

// MARK: Friends

/// The friends screen: the player's card and the sections on the left, the section's
/// people on the right. Everything comes from the Nextendo agent's hub.
private struct LibraryFriendsScreen: View {
    @Bindable var model: StudioModel

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            sidebar.frame(width: 250)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.top, 28)
        .frame(minHeight: 420, maxHeight: model.libraryFullScreen ? .infinity : nil, alignment: .top)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 8) {
                LibraryAvatar(name: model.nextendoAccount?.identity?.username, seed: model.nextendoAccount?.identity?.pid ?? 0, size: 64)
                Text(verbatim: model.nextendoAccount?.identity?.username ?? t("Not signed in to Nextendo"))
                    .font(.system(size: 17, weight: .semibold)).lineLimit(1)
                if let code = model.nextendoAccount?.identity?.friendCode {
                    Text(String(format: t("Friend code %@"), code)).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(StudioStyle.muted).textSelection(.enabled)
                }
            }
            .padding(.bottom, 18)
            ForEach(LibraryFriendsSection.allCases, id: \.self) { section in
                let selected = model.libraryFriendsSection == section
                Button { model.libraryFriendsSection = section } label: {
                    HStack {
                        Text(title(section))
                        Spacer()
                        if section != .add { Text(verbatim: "\(count(section))").monospacedDigit()
                            .foregroundStyle(section == .received && count(section) > 0 ? StudioStyle.signal : StudioStyle.muted) }
                    }
                    .padding(.horizontal, 12).frame(height: 38)
                    .background(selected ? StudioStyle.raised : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .leading) {
                        if selected { RoundedRectangle(cornerRadius: 2).fill(StudioStyle.signal).frame(width: 3, height: 20) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fontWeight(selected ? .semibold : .regular)
            }
            Divider().padding(.vertical, 10)
            Toggle(t("Notify me when friends come online or send a request"), isOn: Binding(get: { model.nextendoNotifications },
                set: { value in Task { await model.setNextendoNotifications(value) } }))
                .font(.system(size: 12)).disabled(model.isChangingNextendoNotifications || model.nextendoAgentState != .on)
            Button(t("Refresh")) { Task { await model.refreshLibraryFriends() } }
                .buttonStyle(QuietButtonStyle()).disabled(model.isLoadingNextendoFriends).padding(.top, 8)
        }
    }

    @ViewBuilder private var content: some View {
        if model.nextendoAccount == nil {
            unavailable(t("Sign in to Nextendo to see your friends."), action: t("Open Nextendo"))
        } else if model.nextendoAgentState != .on {
            unavailable(t("Turn on Keep Nextendo connected to see your friends and answer their requests here."), action: t("Open Nextendo"))
        } else if model.nextendoFriends == nil {
            if model.isLoadingNextendoFriends { ProgressView() }
            else { unavailable(model.nextendoFriendsMessage ?? t("The background agent could not read your friends. Try again later."), action: nil) }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text(title(model.libraryFriendsSection)).font(.system(size: 20, weight: .semibold))
                switch model.libraryFriendsSection {
                case .friends: friendGrid
                case .received: requestList(model.nextendoFriends?.requests ?? [], received: true)
                case .sent: requestList(model.nextendoFriends?.sent ?? [], received: false)
                case .add: addFriend
                }
                if model.libraryFriendsSection != .add, let message = model.nextendoFriendsMessage {
                    Label(message, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder private var friendGrid: some View {
        let friends = model.libraryFriends
        if friends.isEmpty {
            Text(t("No friends yet.")).foregroundStyle(StudioStyle.muted)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], alignment: .leading, spacing: 14) {
                ForEach(friends) { friend in
                    VStack(spacing: 10) {
                        LibraryAvatar(friend: friend, size: 72, showsStatus: true)
                        Text(verbatim: friend.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(model.libraryFriendActivity(friend)).font(.system(size: 11))
                            .foregroundStyle(friend.isOnline ? .white.opacity(0.85) : StudioStyle.muted).lineLimit(2).multilineTextAlignment(.center)
                    }
                    .padding(16).frame(maxWidth: .infinity, minHeight: 170, alignment: .top)
                    .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                    .opacity(friend.isOnline ? 1 : 0.7)
                }
            }
        }
    }

    @ViewBuilder private func requestList(_ people: [NextendoFriend], received: Bool) -> some View {
        if people.isEmpty {
            Text(received ? t("No friend requests.") : t("No pending requests sent.")).foregroundStyle(StudioStyle.muted)
        } else {
            VStack(spacing: 10) {
                ForEach(people) { friend in
                    HStack(spacing: 14) {
                        LibraryAvatar(friend: friend, size: 44)
                        Text(verbatim: friend.name).font(.system(size: 14, weight: .medium))
                        Spacer()
                        if received {
                            Button(t("Decline")) { Task { await model.answerNextendoFriendRequest(friend, accept: false) } }
                                .buttonStyle(QuietButtonStyle())
                            Button(t("Accept")) { Task { await model.answerNextendoFriendRequest(friend, accept: true) } }
                                .buttonStyle(PrimaryButtonStyle())
                        } else {
                            Text(t("Waiting for an answer")).font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                        }
                    }
                    .padding(12).background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                    .disabled(model.nextendoFriendAnswers.contains(friend.pid))
                }
            }
        }
    }

    /// Add friend by friend code, with the player's own code to give out.
    private var addFriend: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let code = model.nextendoAccount?.identity?.friendCode {
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("Your friend code")).font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                    Text(verbatim: code).font(.system(size: 22, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                }
            }
            Text(t("Search with a friend code")).font(.system(size: 12)).foregroundStyle(StudioStyle.muted).padding(.top, 6)
            HStack(spacing: 10) {
                TextField("SW-0000-0000-0000", text: $model.libraryFriendCode)
                    .textFieldStyle(.plain).font(.system(size: 16, design: .monospaced))
                    .padding(10).frame(maxWidth: 260)
                    .background(StudioStyle.raised, in: RoundedRectangle(cornerRadius: 8))
                    .onSubmit { Task { await model.sendLibraryFriendRequest() } }
                Button(t("Send friend request")) { Task { await model.sendLibraryFriendRequest() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.isSendingFriendRequest || model.libraryFriendCode.isEmpty)
                if model.isSendingFriendRequest { ProgressView().controlSize(.small) }
            }
            if let result = model.libraryFriendRequestResult {
                Label(result.message, systemImage: result.sent ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(result.sent ? StudioStyle.signal : .orange)
            }
        }
    }

    private func unavailable(_ text: String, action: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text).foregroundStyle(StudioStyle.muted).fixedSize(horizontal: false, vertical: true)
            if let action { Button(action) { model.leaveLibrary(to: .nextendo) }.buttonStyle(QuietButtonStyle()) }
        }
        .padding(20).frame(maxWidth: 460, alignment: .leading)
        .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func title(_ section: LibraryFriendsSection) -> String {
        switch section {
        case .friends: t("Friend list")
        case .received: t("Received requests")
        case .sent: t("Sent requests")
        case .add: t("Add friend")
        }
    }

    private func count(_ section: LibraryFriendsSection) -> Int {
        switch section {
        case .friends: model.nextendoFriends?.friends.count ?? 0
        case .received: model.nextendoFriends?.requests.count ?? 0
        case .sent: model.nextendoFriends?.sent.count ?? 0
        case .add: 0
        }
    }
}

// MARK: Hints

/// The keys the current screen answers, as Studio's own key caps; each one can be clicked.
private struct LibraryHintBar: View {
    @Bindable var model: StudioModel

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            HStack(spacing: 20) {
                Image(systemName: "keyboard").foregroundStyle(StudioStyle.muted)
                Spacer()
                switch model.libraryScreen {
                case .home:
                    hint(["←", "→", "↑", "↓"], t("Choose"), nil)
                    if model.libraryRow == .games, let port = model.selectedLibraryPort {
                        let running = model.libraryPortIsRunning(port)
                        if port.engine != nil && !running { hint(["⌥", "⏎"], t("Settings"), .alternate) }
                        hint(["⏎"], running ? t("Show") : t("Play"), .activate)
                    } else if model.libraryRow == .shortcuts {
                        hint(["⏎"], t("Open"), .activate)
                    }
                    if model.libraryFullScreen { hint(["esc"], t("Exit full screen"), .back) }
                    else { hint(["F"], t("Full screen"), .fullScreen) }
                case .friends:
                    hint(["↑", "↓"], t("Choose"), nil)
                    hint(["esc"], t("Back"), .back)
                }
            }
            .padding(.vertical, 14)
        }
        .font(.system(size: 12))
    }

    @ViewBuilder private func hint(_ keys: [String], _ label: String, _ key: LibraryKey?) -> some View {
        let content = HStack(spacing: 6) {
            ForEach(keys, id: \.self) { key in
                Text(verbatim: key).font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 6).frame(minWidth: 22, minHeight: 20)
                    .background(StudioStyle.raised, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.12)))
            }
            Text(label).foregroundStyle(StudioStyle.muted)
        }
        if let key {
            Button { model.handleLibraryKey(key) } label: { content }.buttonStyle(.plain).accessibilityLabel(label)
        } else {
            content.accessibilityElement(children: .combine)
        }
    }
}
