import SwiftUI
import UIKit

struct MobileNextendoSetupView: View {
    @ObservedObject var model: MobileNextendoModel
    @ObservedObject var launcher: LauncherModel
    let checkServices: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var applicationSettings = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Set up your account on this iPhone").font(.headline)
                    Text("Sign in through Nextendo’s website. Your password stays there; the app keeps its credential in this iPhone’s Keychain.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Label("Native online play has not been verified.", systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                accountSection
                gameSection
                serviceSection
                Section {
                    DisclosureGroup("Application settings", isExpanded: $applicationSettings) {
                        Text("This port can include its publisher’s registered application ID. If it is missing, you can register your own application from this phone.")
                            .font(.footnote).foregroundStyle(.secondary)
                        TextField("Registered application ID", text: $model.clientID)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .disabled(model.accountBusy)
                        Text("Register the callback nxnative-nextendo://callback for a public application using PKCE. Never enter a client secret or account token here.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Link("Open developer portal", destination: URL(string: "https://nextendo.network/developers.html#/espace")!)
                    }
                }
            }
            .navigationTitle("Nextendo")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { model.cancel(); dismiss() } }
            }
            .background(MobileNextendoWindow { (model.browser as? MobileNextendoBrowser)?.window = $0 })
            .task { await model.load(); if !model.hasClientID { applicationSettings = true } }
        }
        .environment(\.locale, launcher.uiLanguage.locale)
    }

    private var accountSection: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 8) {
                    if model.isLoading { ProgressView().accessibilityLabel(Text("Account")) }
                    else if let account = model.account {
                        let expired = account.isExpired || (account.expiresAt.map { $0 <= context.date } ?? false)
                        Label(text(expired ? "Sign-in expired" : account.hasNEXCredential ? "Game credential saved" : "Account access saved"),
                              systemImage: expired ? "exclamationmark.circle" : "person.crop.circle.badge.checkmark")
                        if let username = account.identity?.username { Text(verbatim: username).font(.subheadline).foregroundStyle(.secondary) }
                        if let expiry = account.expiresAt { Text(expiry, style: .date).font(.footnote).foregroundStyle(.secondary) }
                    } else { Text("No account linked to this app.").foregroundStyle(.secondary) }
                }
            }
            if let error = model.accountError { notice(accountMessage(error)) }
            if model.isAuthorizing || model.isRequestingCredential {
                HStack {
                    ProgressView()
                    Text(model.isAuthorizing ? text("Finish sign-in in the system browser.") : text("Getting game credential…"))
                }
                Button("Cancel request") { model.cancel() }
            } else {
                Button(model.account == nil ? text("Sign in with Nextendo") : text("Sign in again")) { model.signIn() }
                    .disabled(model.accountBusy || !model.hasClientID)
                if model.account?.tokenKind == .oauth {
                    Button("Get game credential") { model.requestGameCredential() }
                        .disabled(model.accountBusy || !model.canRequestGameCredential)
                }
                if model.account != nil {
                    Button("Disconnect this account", role: .destructive) { Task { await model.signOut() } }
                        .disabled(model.accountBusy)
                }
            }
            if !model.hasClientID {
                Button("Set application ID") { applicationSettings = true }
                Text("No registered application ID is included in this port. Set one below before signing in.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text("Account") } footer: {
            Text("Account access and a game credential are separate. Saving either does not certify that a game can connect online.")
        }
    }

    private var gameSection: some View {
        Section {
            LabeledContent("Installed game version", value: model.installedVersion.isEmpty ? text("Unknown") : model.installedVersion)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Label(eligibilityMessage(model.eligibility(at: context.date)), systemImage: "list.bullet.clipboard")
                    .font(.subheadline)
            }
            if let error = model.catalogError { notice(catalogMessage(error)) }
            if model.isRefreshing { HStack { ProgressView(); Text("Refreshing signed catalog…") } }
            Button("Refresh signed catalog") { Task { await model.refreshCatalog() } }.disabled(model.isRefreshing)
            if let catalog = model.catalog?.catalog {
                Text(String(format: text("Signature verified · revision %lld"), catalog.revision)).font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text("Game requirements") } footer: {
            Text("Accepted versions come from Nextendo’s signed catalog. This app’s publisher must provide a port built from a supported game update.")
        }
    }

    private var serviceSection: some View {
        Section {
            Label(text(model.routesState == 0 ? "Connection profile present" : model.routesState == -1 ? "Service check pending" : "Game-service integration pending"), systemImage: "network")
            Text("The game’s native service connection remains under integration. Current checks have certificate and authentication blockers; TLS verification stays enabled.")
                .font(.footnote).foregroundStyle(.secondary)
            if model.routesState != 0 && model.routesState != -1 {
                Text("Account setup works on this iPhone. Compatible game services must be supplied by the app publisher and Nextendo; no IP address or file changes are required from you.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Label(text(model.hasCertificateStore ? "Certificate resources included" : "Certificate resources not included"), systemImage: "doc.text.magnifyingglass")
            Text("Certificate resources are packaged by the app’s publisher. Their presence does not bypass Apple’s TLS verification.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Check game requirements") { checkServices(); Task { await model.load() } }
            Link("Nextendo service information", destination: URL(string: "https://nextendo.network")!)
            Button("Choose Offline mode") { launcher.networkMode = .offline; model.cancel(); dismiss() }
                .disabled(launcher.fromFile.contains("DM_NETWORK"))
            Button("Choose LAN mode") { launcher.networkMode = .lan; model.cancel(); dismiss() }
                .disabled(launcher.fromFile.contains("DM_NETWORK"))
        } header: { Text("Game service") } footer: {
            Text("A saved credential, an accepted version and a connection profile are requirements. A successful native online match is a separate result.")
        }
    }

    private func text(_ key: String) -> String { launcherText(key, language: launcher.uiLanguage) }
    private func notice(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func eligibilityMessage(_ value: NextendoGameEligibility) -> String {
        switch value {
        case .accepted: return text("This version meets the catalog policy; online play is still unverified.")
        case .versionNotAccepted(let versions): return String(format: text("This version is not accepted. Required versions: %@."), versions.joined(separator: ", "))
        case .disabled: return text("The catalog marks this game’s service as disabled.")
        case .notListed: return text("This game is not listed in the signed catalog.")
        case .catalogExpired: return text("The catalog has expired. Refresh it to check this game.")
        case .catalogUnavailable: return text("Refresh the signed catalog to check this game.")
        case .versionUnknown: return text("This app does not report its original game version.")
        case .unsupportedCapabilities, .unsupportedPolicy: return text("The catalog requires a policy this port does not support.")
        }
    }
    private func accountMessage(_ error: NextendoError) -> String {
        switch error {
        case .registrationRequired, .invalidConfiguration: return text("Set a valid registered application ID in Application settings.")
        case .authorizationDenied: return text("Sign-in was cancelled or access was declined. You can try again.")
        case .authorizationExpired: return text("Sign-in expired. Start a new request.")
        case .callbackRejected, .invalidResponse: return text("Nextendo’s response could not be verified. Your previous credential was kept.")
        case .httpStatus(let code): return String(format: text("Nextendo returned HTTP %d. Try again later."), code)
        case .keychain: return text("This app could not access its Keychain. Unlock the iPhone and try again.")
        default: return text("Nextendo could not complete the request. Check your connection and try again.")
        }
    }
    private func catalogMessage(_ error: NextendoCatalogError) -> String {
        switch error {
        case .httpStatus(let code): return String(format: text("The catalog returned HTTP %d. The previous verified copy was kept."), code)
        case .invalidSignature, .invalidDocument: return text("The catalog could not be verified. The previous verified copy was kept.")
        case .expired, .rollback: return text("The catalog is expired or older than the saved copy. Refresh it later.")
        default: return text("The signed catalog is unavailable. Check your connection and try again.")
        }
    }
}

private struct MobileNextendoWindow: UIViewRepresentable {
    let didAttach: (UIWindow?) -> Void
    func makeUIView(context: Context) -> WindowReader {
        let view = WindowReader(); view.isUserInteractionEnabled = false; view.accessibilityElementsHidden = true
        view.didAttach = didAttach; return view
    }
    func updateUIView(_ view: WindowReader, context: Context) { view.didAttach = didAttach }
    final class WindowReader: UIView {
        var didAttach: ((UIWindow?) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); didAttach?(window) }
    }
}
