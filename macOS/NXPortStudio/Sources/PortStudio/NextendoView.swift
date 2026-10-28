import SwiftUI
import PortCore

struct NextendoView: View {
    @Bindable var model: StudioModel
    @State private var search = ""
    @State private var showingApplicationSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            TimelineView(.periodic(from: .now, by: 30)) { context in accountPanel(at: context.date) }
            applicationPanel
            TimelineView(.periodic(from: .now, by: 30)) { context in catalogPanel(at: context.date) }
        }.task { await model.loadNextendoPage() }
    }

    private func accountPanel(at date: Date) -> some View {
        StudioPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label(t("Nextendo account"), systemImage: "person.crop.circle").font(.system(size: 17, weight: .medium))
                    Spacer()
                    if model.isLoadingNextendoAccount || model.isSigningOutNextendo { ProgressView().controlSize(.small) }
                    Button(t("Check saved account")) { Task { await model.reloadNextendoAccount() } }
                        .buttonStyle(QuietButtonStyle()).disabled(accountActionsDisabled)
                }
                if let account = model.nextendoAccount {
                    NextendoAccountDetails(account: account, date: date)
                } else if model.isLoadingNextendoAccount {
                    Text(t("Reading the account saved on this Mac…")).foregroundStyle(StudioStyle.muted)
                } else {
                    Text(t("Link your own Nextendo account to this Mac.")).foregroundStyle(StudioStyle.muted)
                }
                if let error = model.nextendoAccountError { notice(error) }
                if model.isAuthorizingNextendo {
                    HStack(alignment: .top, spacing: 12) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(t("Finish sign-in in your browser")).fontWeight(.medium)
                            Text(t("Return here after approving access. This request can be cancelled at any time."))
                                .font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                            if let expiry = model.nextendoAuthorizationExpiresAt {
                                Text(String(format: t("Request expires at %@."), expiry.formatted(date: .omitted, time: .shortened)))
                                    .font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                            }
                        }
                        Spacer()
                        Button(t("Cancel sign-in")) { model.cancelNextendoSignIn() }.buttonStyle(QuietButtonStyle())
                    }
                } else if model.isRequestingNextendoGameCredential {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text(t("Requesting a game credential…")).fontWeight(.medium)
                        Spacer()
                        Button(t("Cancel request")) { model.cancelNextendoSignIn() }.buttonStyle(QuietButtonStyle())
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { accountButtons }
                        VStack(alignment: .leading, spacing: 10) { accountButtons }
                    }
                }
                if model.nextendoClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(alignment: .top) {
                        Text(t("Set your registered application's client ID before linking an account."))
                            .font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                        Spacer()
                        Button(t("Application settings")) { showingApplicationSettings = true }.buttonStyle(.plain)
                    }
                }
                Text(t("Credentials stay in this Mac's Keychain. Signing in does not verify that a game can play online."))
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var accountButtons: some View {
        if model.nextendoAccount?.tokenKind == .oauth {
            Button(t("Get game credential")) { model.requestNextendoGameCredential() }
                .buttonStyle(PrimaryButtonStyle()).disabled(accountActionsDisabled || !model.canRequestNextendoGameCredential())
                .help(t("Request a NEX credential using your existing authorized account access."))
        }
        Button(t(model.nextendoAccount == nil ? "Link account" : "Link again")) { model.beginNextendoSignIn() }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(accountActionsDisabled || model.nextendoClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if model.nextendoAccount != nil {
            Button(t("Disconnect account"), role: .destructive) { Task { await model.signOutNextendo() } }
                .buttonStyle(QuietButtonStyle()).disabled(accountActionsDisabled)
                .help(t("Remove the saved Nextendo credential from this Mac."))
        }
    }

    private var accountActionsDisabled: Bool { model.isLoadingNextendoAccount || model.isAuthorizingNextendo || model.isRequestingNextendoGameCredential || model.isSigningOutNextendo }

    private var applicationPanel: some View {
        StudioPanel {
            DisclosureGroup(t("Application settings"), isExpanded: $showingApplicationSettings) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(t("Use the client ID of your own registered Nextendo application. No client secret is required for this desktop sign-in."))
                        .font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                    TextField(t("Nextendo application client ID"), text: $model.nextendoClientID)
                        .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                        .padding(10).background(StudioStyle.raised, in: RoundedRectangle(cornerRadius: 7))
                        .disabled(accountActionsDisabled)
                    HStack {
                        Button(t("Open developer portal")) { model.openURL("https://nextendo.network/developers.html#/espace") }
                            .buttonStyle(QuietButtonStyle())
                        Button(t("Developer documentation")) { model.openURL("https://wiki.nextendo.network/developers") }
                            .buttonStyle(.plain)
                    }
                    Text(t("Requested permissions: identity, friends, presence, matchmaking and emulator status."))
                        .font(.system(size: 12)).foregroundStyle(StudioStyle.muted).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 12)
            }.fontWeight(.medium)
        }
    }

    private func catalogPanel(at date: Date) -> some View {
        StudioPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label(t("Signed service catalog"), systemImage: "checkmark.seal").font(.system(size: 17, weight: .medium))
                    Spacer()
                    if model.isRefreshingNextendoCatalog { ProgressView().controlSize(.small) }
                    Button(t("Refresh catalog")) { Task { await model.refreshNextendoCatalog() } }
                        .buttonStyle(QuietButtonStyle()).disabled(model.isRefreshingNextendoCatalog)
                }
                Text(t("Accepted versions and server policy are published by Nextendo. They do not establish native online playability."))
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.muted).fixedSize(horizontal: false, vertical: true)
                if let error = model.nextendoCatalogError ?? model.nextendoCatalog?.refreshError.map({ t($0.localizedDescription) }) { notice(error) }
                if let snapshot = model.nextendoCatalog, let catalog = snapshot.catalog {
                    let expired = snapshot.freshness(at: date) != .fresh
                    if expired { notice(t("This verified catalog has expired. Refresh it before relying on its service requirements.")) }
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(format: t("Signature verified · revision %lld"), catalog.revision)).font(.system(size: 12))
                            Text(String(format: t("Catalog expires %@."), catalog.expiresAt.formatted(date: .abbreviated, time: .shortened)))
                                .font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                            if let fetched = snapshot.fetchedAt {
                                Text(String(format: t("Last refreshed %@."), fetched.formatted(date: .abbreviated, time: .shortened)))
                                    .font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                            }
                        }
                        Spacer()
                        Text(String(format: t("%d games"), catalog.games.count)).font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(StudioStyle.muted)
                        TextField(t("Search games or title IDs"), text: $search).textFieldStyle(.plain)
                        if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel(t("Clear search")) }
                    }.padding(10).background(StudioStyle.raised, in: RoundedRectangle(cornerRadius: 7))
                    let games = filtered(catalog.games)
                    if games.isEmpty {
                        Text(t("No games match your search.")).foregroundStyle(StudioStyle.muted).padding(.vertical, 16)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(games) { policy in
                                NextendoGameRow(policy: policy).opacity(expired ? 0.65 : 1)
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(t(model.isRefreshingNextendoCatalog ? "Retrieving the signed catalog…" : "No verified catalog available")).fontWeight(.medium)
                        Text(t("Refresh to retrieve the service's current game and version policies."))
                            .font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                    }.padding(.vertical, 14)
                }
            }
        }
    }

    private func filtered(_ policies: [NextendoGamePolicy]) -> [NextendoGamePolicy] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return policies.filter { query.isEmpty || $0.name.localizedStandardContains(query) || $0.titleIDs.contains(where: { $0.localizedStandardContains(query) }) }
            .sorted { left, right in left.name == right.name ? left.id < right.id : left.name.localizedStandardCompare(right.name) == .orderedAscending }
    }

    private func notice(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.system(size: 12)).foregroundStyle(StudioStyle.signal).fixedSize(horizontal: false, vertical: true)
    }
}

private struct NextendoAccountDetails: View {
    let account: NextendoAccountSummary
    let date: Date
    private var expired: Bool { account.isExpired || account.expiresAt.map { $0 <= date } == true }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let name = account.identity?.username { Text(name).font(.system(size: 19, weight: .medium)).textSelection(.enabled) }
            if let friendCode = account.identity?.friendCode { Text(friendCode).font(.system(size: 12, design: .monospaced)).foregroundStyle(StudioStyle.muted).textSelection(.enabled) }
            Text(t(expired ? "Sign-in expired" : account.tokenKind == .nex ? "NEX credential saved" : "Scoped account access"))
                .fontWeight(.medium).foregroundStyle(expired ? StudioStyle.signal : .white)
            Text(t(expired ? "Link your account again to renew access." : account.tokenKind == .nex ? "Nextendo issued a game credential. Compatible services and a tested native game connection are still required." : "The approved account permissions are available. A game credential has not been issued."))
                .font(.system(size: 12)).foregroundStyle(StudioStyle.muted).fixedSize(horizontal: false, vertical: true)
            if let expiry = account.expiresAt {
                Text(String(format: t("Account access expires %@."), expiry.formatted(date: .abbreviated, time: .shortened)))
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
            }
        }
    }
}

private struct NextendoGameRow: View {
    let policy: NextendoGamePolicy
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(policy.name).fontWeight(.medium).frame(maxWidth: .infinity, alignment: .leading)
                Text(t(policy.enabled ? "Server enabled in catalog" : "Server disabled in catalog"))
                    .font(.system(size: 11)).foregroundStyle(StudioStyle.muted)
            }
            Text(policy.titleIDs.joined(separator: " · ")).font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(StudioStyle.muted).textSelection(.enabled)
            Text(versions).font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
            if case .unsupported = policy.versionPolicy {
                Text(t("This service policy needs a newer app implementation.")).font(.system(size: 12)).foregroundStyle(StudioStyle.signal)
            } else if policy.requiredCapabilities.contains(where: { !NextendoCatalogVerifier.capabilities.contains($0) }) {
                Text(t("This service policy needs a newer app implementation.")).font(.system(size: 12)).foregroundStyle(StudioStyle.signal)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }
            .accessibilityElement(children: .combine)
    }
    private var versions: String {
        switch policy.versionPolicy {
        case .exact(let accepted): String(format: t("Accepted versions: %@"), accepted.joined(separator: ", "))
        case .any: t("Version policy: any version")
        case .unsupported: t("Version policy unavailable")
        }
    }
}
