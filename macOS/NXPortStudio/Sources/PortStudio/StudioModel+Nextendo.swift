import AppKit
import PortCore

extension StudioModel {
    static let nextendoScopes = ["identity", "friends", "presence", "game.matchmaking", "emulator.status"]

    func loadNextendoPage() async {
        await reloadNextendoAccount()
        guard !Task.isCancelled else { return }
        nextendoCatalog = await nextendoCatalogService.snapshot()
        if nextendoCatalog?.freshness() != .fresh { await refreshNextendoCatalog() }
    }

    func reloadNextendoAccount() async {
        guard !isLoadingNextendoAccount, !isAuthorizingNextendo, !isRequestingNextendoGameCredential, !isSigningOutNextendo else { return }
        isLoadingNextendoAccount = true
        defer { isLoadingNextendoAccount = false }
        do {
            let summary = try await nextendoAccountService.currentAccount()
            try Task.checkCancellation()
            nextendoAccount = summary; nextendoAccountError = nil
        } catch is CancellationError {} catch { nextendoAccountError = nextendoAccountMessage(error) }
    }

    func beginNextendoSignIn() {
        guard !isAuthorizingNextendo, !isRequestingNextendoGameCredential, !isLoadingNextendoAccount, !isSigningOutNextendo else { return }
        let configuration: NextendoOAuthConfiguration
        do { configuration = try NextendoOAuthConfiguration(clientID: nextendoClientID, scopes: Self.nextendoScopes) }
        catch { nextendoAccountError = nextendoAccountMessage(error); return }
        let id = UUID(), cancellation = nextendoCancellationTask
        nextendoAuthorizationID = id; isAuthorizingNextendo = true; nextendoAccountError = nil
        nextendoAuthorizationExpiresAt = nil
        nextendoAuthorizationTask = Task { [weak self, nextendoAccountService] in
            await cancellation?.value
            guard let self, !Task.isCancelled, self.nextendoAuthorizationID == id else { return }
            defer {
                if self.nextendoAuthorizationID == id {
                    self.isAuthorizingNextendo = false; self.nextendoAuthorizationExpiresAt = nil
                    self.nextendoAuthorizationTask = nil
                }
            }
            do {
                let request = try await nextendoAccountService.beginSignIn(configuration: configuration)
                try Task.checkCancellation()
                guard self.nextendoAuthorizationID == id else { return }
                self.nextendoAuthorizationExpiresAt = request.expiresAt
                // The authorization URL is transient and never enters observed
                // state, preferences or Activity. Only this user action opens it.
                guard self.nextendoBrowserOpener(request.authorizationURL) else {
                    await nextendoAccountService.cancelSignIn()
                    guard self.nextendoAuthorizationID == id else { return }
                    self.nextendoAccountError = t("The sign-in page could not be opened. Check your default browser and try again.")
                    return
                }
                let summary = try await nextendoAccountService.finishSignIn(request.id)
                try Task.checkCancellation()
                guard self.nextendoAuthorizationID == id else { return }
                self.nextendoAccount = summary
            } catch is CancellationError {} catch {
                guard self.nextendoAuthorizationID == id else { return }
                self.nextendoAccountError = self.nextendoAccountMessage(error)
            }
        }
    }

    func cancelNextendoSignIn() {
        guard isAuthorizingNextendo || isRequestingNextendoGameCredential else { return }
        let authorization = nextendoAuthorizationTask, gameCredential = nextendoGameCredentialTask
        let previousCancellation = nextendoCancellationTask
        nextendoAuthorizationID = UUID(); authorization?.cancel(); nextendoAuthorizationTask = nil
        nextendoGameCredentialID = UUID(); gameCredential?.cancel(); nextendoGameCredentialTask = nil
        isRequestingNextendoGameCredential = false
        isAuthorizingNextendo = false; nextendoAuthorizationExpiresAt = nil; nextendoAccountError = nil
        // A rapid cancel/retry must not let a delayed cancellation close the
        // new listener. The next attempt waits for this complete cleanup.
        nextendoCancellationTask = Task { [nextendoAccountService] in
            await previousCancellation?.value
            await nextendoAccountService.cancelSignIn()
            await authorization?.value
            await gameCredential?.value
        }
    }

    func canRequestNextendoGameCredential(at date: Date = Date()) -> Bool {
        guard let account = nextendoAccount, account.tokenKind == .oauth, !account.isExpired,
              account.expiresAt.map({ $0 > date }) ?? true else { return false }
        return account.scopes.contains("identity")
    }

    func requestNextendoGameCredential() {
        guard canRequestNextendoGameCredential(), !isAuthorizingNextendo, !isRequestingNextendoGameCredential,
              !isLoadingNextendoAccount, !isSigningOutNextendo else { return }
        let id = UUID(), cancellation = nextendoCancellationTask
        nextendoGameCredentialID = id; isRequestingNextendoGameCredential = true; nextendoAccountError = nil
        nextendoGameCredentialTask = Task { [weak self, nextendoAccountService] in
            await cancellation?.value
            guard let self, !Task.isCancelled, self.nextendoGameCredentialID == id else { return }
            defer {
                if self.nextendoGameCredentialID == id {
                    self.isRequestingNextendoGameCredential = false; self.nextendoGameCredentialTask = nil
                }
            }
            do {
                let summary = try await nextendoAccountService.upgradeGameCredential()
                try Task.checkCancellation()
                guard self.nextendoGameCredentialID == id else { return }
                self.nextendoAccount = summary
            } catch is CancellationError {} catch {
                guard self.nextendoGameCredentialID == id else { return }
                self.nextendoAccountError = self.nextendoAccountMessage(error)
            }
        }
    }

    func signOutNextendo() async {
        guard !isSigningOutNextendo, !isLoadingNextendoAccount else { return }
        cancelNextendoSignIn(); isSigningOutNextendo = true; nextendoAccountError = nil
        defer { isSigningOutNextendo = false }
        await nextendoCancellationTask?.value
        do { try await nextendoAccountService.signOut(); nextendoAccount = nil }
        catch { nextendoAccountError = nextendoAccountMessage(error) }
    }

    func refreshNextendoCatalog() async {
        guard !isRefreshingNextendoCatalog else { return }
        isRefreshingNextendoCatalog = true; nextendoCatalogError = nil
        defer { isRefreshingNextendoCatalog = false }
        do { nextendoCatalog = try await nextendoCatalogService.refresh() }
        catch is CancellationError {} catch {
            nextendoCatalog = await nextendoCatalogService.snapshot()
            if let error = error as? NextendoCatalogError {
                switch error {
                case .httpStatus(let status): nextendoCatalogError = String(format: t("Nextendo's service catalog returned HTTP %d."), status)
                default: nextendoCatalogError = t(error.localizedDescription)
                }
            } else { nextendoCatalogError = t("Nextendo's service catalog is unavailable.") }
        }
    }

    private func nextendoAccountMessage(_ error: Error) -> String {
        // Do not display arbitrary transport errors: they can contain request
        // URLs. The account service's typed errors contain no credentials.
        guard let error = error as? NextendoError else { return t("Nextendo sign-in could not be completed. Try again.") }
        switch error {
        case .httpStatus(let code): return String(format: t("Nextendo returned HTTP %d."), code)
        case .keychain(let code): return String(format: t("The Nextendo credential could not be accessed in Keychain (%d)."), code)
        default: return t(error.localizedDescription)
        }
    }
}
