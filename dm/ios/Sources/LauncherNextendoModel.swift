import Foundation
import Combine

@_silgen_name("dm_mobile_nextendo_routes_state") private func mobileNextendoRoutesState() -> Int32
@_silgen_name("dm_mobile_nextendo_apply_service_profile") private func mobileNextendoApplyServiceProfile(_ path: UnsafePointer<CChar>) -> Int32

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
    @Published private(set) var isPreparingServices = false
    @Published private(set) var servicePreparationFailed = false
    @Published var clientID: String

    let titleID: String
    let installedVersion: String
    let hasCertificateStore: Bool
    let browser: any MobileNextendoBrowsing
    private let accountService: NextendoAccountService
    private let catalogService: NextendoCatalogService
    private let callbacks: MobileNextendoCallbackPool
    private let preferences: UserDefaults
    private let serviceProfiles: NextendoServiceProfileService
    private let bundle: Bundle
    private var requestTask: Task<Void, Never>?
    private var cancellationTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var renewalTask: Task<Void, Never>?
    private var operationID = UUID()

    init(bundle: Bundle = .main, preferences: UserDefaults = .standard,
         accountService: NextendoAccountService? = nil,
         catalogService: NextendoCatalogService = NextendoCatalogService(),
         serviceProfiles: NextendoServiceProfileService = NextendoServiceProfileService(),
         callbacks: MobileNextendoCallbackPool = MobileNextendoCallbackPool(),
         browser: any MobileNextendoBrowsing) {
        self.preferences = preferences
        self.serviceProfiles = serviceProfiles
        self.bundle = bundle
        self.callbacks = callbacks
        self.browser = browser
        self.accountService = accountService ?? NextendoAccountService(store: MobileNextendoCredentialStore(preferences: preferences), makeReceiver: { try callbacks.make() })
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
            let renewed = try await accountService.prepareGameAccount()
            if operation == operationID, !Task.isCancelled { account = renewed; accountError = nil; scheduleRenewal() }
        } catch {
            if operation == operationID {
                accountError = (error as? NextendoError) ?? .requestFailed
                if accountError?.permitsBackgroundRetry == true { scheduleRenewal(retry: true) }
            }
        }
        isLoading = false
        catalog = await catalogService.snapshot()
        routesState = mobileNextendoRoutesState()
        if catalog?.freshness() != .fresh { await refreshCatalog() }
        await prepareServices()
    }
    private func scheduleRenewal(retry: Bool = false) {
        renewalTask?.cancel(); renewalTask = nil
        guard let check = account?.renewalCheckAt else { return }
        let delay = retry ? 300 : max(30,check.timeIntervalSinceNow)
        renewalTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            await self.cancellationTask?.value
            guard !Task.isCancelled else { return }
            await self.load()
        }
    }
    func prepareServices() async {
        guard !isPreparingServices, routesState != 0 else { return }
        isPreparingServices = true; servicePreparationFailed = false
        defer { isPreparingServices = false }
        do {
            guard let resource = bundle.resourceURL?.appendingPathComponent("dm/nextendo-services.json"),
                  let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            else { throw NextendoServiceProfileError.unavailable }
            let contract = try NextendoServiceContract(data: Data(contentsOf: resource))
            let policy = catalog?.catalog?.games.first { $0.titleIDs.contains(titleID) }
            let ca = bundle.resourceURL.flatMap { try? Data(contentsOf: $0.appendingPathComponent("dm/nextendo/provider-ca.der")) }
            let profile = try await serviceProfiles.prepare(contract: contract, titleID: titleID, protocolName: policy?.protocolName,
                root: root.appendingPathComponent("Nextendo/Services", isDirectory: true), includedCertificate: ca)
            try Task.checkCancellation()
            routesState = profile.path.withCString { mobileNextendoApplyServiceProfile($0) }
            servicePreparationFailed = routesState != 0
        } catch is CancellationError { }
        catch { servicePreparationFailed = true }
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
        renewalTask?.cancel(); renewalTask = nil
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
                let summary = try await accountService.finishSignIn(request.id, forGames: true)
                guard operation == operationID, !Task.isCancelled else { return }
                account = summary
                scheduleRenewal()
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
        renewalTask?.cancel(); renewalTask = nil
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
        try NextendoOAuthConfiguration(clientID: clientID, scopes: ["identity", "friends", "game.matchmaking"])
    }
}
