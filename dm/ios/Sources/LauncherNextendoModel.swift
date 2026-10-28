import Foundation
import Combine

@_silgen_name("dm_mobile_nextendo_routes_state") private func mobileNextendoRoutesState() -> Int32

/// Account authorization, catalog policy and game transport remain separate states.
@MainActor final class MobileNextendoModel: ObservableObject {
    @Published private(set) var account: NextendoAccountSummary?
    @Published private(set) var catalog: NextendoCatalogSnapshot?
    @Published private(set) var accountError: NextendoError?
    @Published private(set) var catalogError: NextendoCatalogError?
    @Published private(set) var isLoading = false
    @Published private(set) var isAuthorizing = false
    @Published private(set) var isRequestingCredential = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSigningOut = false
    @Published private(set) var authorizationExpiresAt: Date?
    @Published private(set) var routesState: Int32 = -1
    @Published var clientID: String

    let titleID: String
    let installedVersion: String
    let hasCertificateStore: Bool
    let browser: any MobileNextendoBrowsing
    private let accountService: NextendoAccountService
    private let catalogService: NextendoCatalogService
    private let callbacks: MobileNextendoCallbackPool
    private let preferences: UserDefaults
    private var requestTask: Task<Void, Never>?
    private var cancellationTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var operationID = UUID()

    init(bundle: Bundle = .main, preferences: UserDefaults = .standard,
         accountService: NextendoAccountService? = nil,
         catalogService: NextendoCatalogService = NextendoCatalogService(),
         callbacks: MobileNextendoCallbackPool = MobileNextendoCallbackPool(),
         browser: any MobileNextendoBrowsing) {
        self.preferences = preferences
        self.callbacks = callbacks
        self.browser = browser
        self.accountService = accountService ?? NextendoAccountService(store: MobileNextendoCredentialStore(preferences: preferences), makeReceiver: { callbacks.make() })
        self.catalogService = catalogService
        self.clientID = preferences.string(forKey: "launcher.nextendoClientID") ?? (bundle.object(forInfoDictionaryKey: "DMNextendoClientID") as? String ?? "")
        self.titleID = (bundle.object(forInfoDictionaryKey: "DMGameTitleID") as? String ?? "").lowercased()
        self.installedVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let roots = [FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first, bundle.resourceURL].compactMap { $0 }
        let configuredRoot = ProcessInfo.processInfo.environment["DM_SYSTEM_DATA_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let effectiveRoot = configuredRoot ?? roots.map { $0.appendingPathComponent("system_data") }.first {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &directory) && directory.boolValue
        }
        self.hasCertificateStore = effectiveRoot.map {
            FileManager.default.isReadableFile(atPath: $0.appendingPathComponent("0100000000000800/files/ssl_TrustedCerts.bdf").path)
        } ?? false
    }

    var accountBusy: Bool { isLoading || isAuthorizing || isRequestingCredential || isSigningOut }
    var hasClientID: Bool { (try? configuration()) != nil }
    var hasGameCredential: Bool { account?.hasNEXCredential == true && (account?.expiresAt.map { $0 > Date() } ?? true) }
    var canRequestGameCredential: Bool { account?.tokenKind == .oauth && account?.isExpired == false && (account?.expiresAt.map { $0 > Date() } ?? true) }
    func eligibility(at date: Date = Date()) -> NextendoGameEligibility {
        catalog?.catalog?.evaluate(titleID: titleID, installedVersion: installedVersion, at: date) ?? .catalogUnavailable
    }
    var mayAttemptGame: Bool { hasGameCredential && eligibility() == .accepted && routesState == 0 }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        let operation = operationID
        do {
            let summary = try await accountService.currentAccount()
            if operation == operationID, !Task.isCancelled { account = summary }
        } catch {
            if operation == operationID { accountError = (error as? NextendoError) ?? .requestFailed }
        }
        isLoading = false
        catalog = await catalogService.snapshot()
        routesState = mobileNextendoRoutesState()
        if catalog?.freshness() != .fresh { await refreshCatalog() }
    }
    func refreshCatalog() async {
        guard !isRefreshing else { return }
        isRefreshing = true; catalogError = nil
        defer { isRefreshing = false }
        do { catalog = try await catalogService.refresh() }
        catch is CancellationError { }
        catch {
            catalogError = (error as? NextendoCatalogError) ?? .unavailable
            catalog = await catalogService.snapshot()
        }
    }
    func signIn() {
        guard !accountBusy else { return }
        let configuration: NextendoOAuthConfiguration
        do { configuration = try self.configuration() }
        catch { accountError = (error as? NextendoError) ?? .invalidConfiguration; return }
        preferences.set(configuration.clientID, forKey: "launcher.nextendoClientID")
        isAuthorizing = true; accountError = nil
        operationID = UUID(); let operation = operationID, barrier = cancellationTask
        requestTask = Task { [weak self] in
            guard let self else { return }
            await barrier?.value
            guard operation == operationID, !Task.isCancelled else { return }
            do {
                let request = try await accountService.beginSignIn(configuration: configuration)
                guard operation == operationID, !Task.isCancelled else { return }
                authorizationExpiresAt = request.expiresAt
                guard let receiver = callbacks.latest, browser.open(request, receiver: receiver) else { throw NextendoError.authorizationUnavailable }
                expiryTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(max(0, request.expiresAt.timeIntervalSinceNow))) } catch { return }
                    guard let self, operation == operationID else { return }
                    cancel(); accountError = .authorizationExpired
                }
                let summary = try await accountService.finishSignIn(request.id)
                guard operation == operationID, !Task.isCancelled else { return }
                account = summary
            } catch is CancellationError { }
            catch { if operation == operationID { accountError = (error as? NextendoError) ?? .requestFailed } }
            guard operation == operationID else { return }
            expiryTask?.cancel(); expiryTask = nil
            browser.cancel(); authorizationExpiresAt = nil
            let cleanup = queueCancellation()
            await cleanup.value
            guard operation == operationID else { return }
            isAuthorizing = false; requestTask = nil
        }
    }
    func requestGameCredential() {
        guard !accountBusy, canRequestGameCredential else { return }
        isRequestingCredential = true; accountError = nil
        operationID = UUID(); let operation = operationID, barrier = cancellationTask
        requestTask = Task { [weak self] in
            guard let self else { return }
            await barrier?.value
            guard operation == operationID, !Task.isCancelled else { return }
            do {
                let summary = try await accountService.upgradeGameCredential()
                guard operation == operationID, !Task.isCancelled else { return }
                account = summary
            } catch is CancellationError { }
            catch { if operation == operationID { accountError = (error as? NextendoError) ?? .requestFailed } }
            guard operation == operationID else { return }
            isRequestingCredential = false; requestTask = nil
        }
    }
    func cancel() {
        operationID = UUID()
        requestTask?.cancel(); requestTask = nil
        expiryTask?.cancel(); expiryTask = nil
        browser.cancel()
        isAuthorizing = false; isRequestingCredential = false; authorizationExpiresAt = nil
        _ = queueCancellation()
    }
    @discardableResult private func queueCancellation() -> Task<Void, Never> {
        let previous = cancellationTask, service = accountService
        let task = Task { await previous?.value; await service.cancelSignIn() }
        cancellationTask = task
        return task
    }
    func updateRoutes(_ value: Int) { routesState = Int32(value) }
    func signOut() async {
        guard !isSigningOut else { return }
        cancel(); isSigningOut = true; accountError = nil
        await cancellationTask?.value
        do { try await accountService.signOut(); account = nil }
        catch {
            account = try? await accountService.currentAccount()
            accountError = (error as? NextendoError) ?? .requestFailed
        }
        isSigningOut = false
    }
    private func configuration() throws -> NextendoOAuthConfiguration {
        // Match the publisher's registered grant used by the verified desktop flow.
        // Consent remains on Nextendo's own website; this app never adds a secret.
        try NextendoOAuthConfiguration(clientID: clientID, scopes: ["identity", "friends", "presence", "game.matchmaking", "emulator.status"])
    }
}
