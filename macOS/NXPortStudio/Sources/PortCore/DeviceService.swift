import Foundation
import Security
import Darwin

/// A physical iPhone or iPad known to Xcode, rather than an arbitrary nearby device.
public struct AppleDevice: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let udid: String
    public let name: String
    public let model: String
    public let osVersion: String
    public let transport: String
    public let isPaired: Bool
    public let isConnected: Bool
    public let developerModeEnabled: Bool?

    public init(id: String, udid: String, name: String, model: String, osVersion: String,
                transport: String, isPaired: Bool, isConnected: Bool, developerModeEnabled: Bool?) {
        self.id = id
        self.udid = udid
        self.name = name
        self.model = model
        self.osVersion = osVersion
        self.transport = transport
        self.isPaired = isPaired
        self.isConnected = isConnected
        self.developerModeEnabled = developerModeEnabled
    }

    public var connectionLabel: String {
        switch transport.lowercased() {
        case "usb", "wired": return "USB"
        case "wifi", "wi-fi", "network", "localnetwork": return "Wi-Fi"
        default: return transport.isEmpty ? "Unknown" : transport
        }
    }

    public var supportsRequiredOS: Bool {
        guard let major = Int(osVersion.split(separator: ".").first ?? "") else { return false }
        return major >= 26
    }

    /// Unknown Developer Mode is left to CoreDevice to validate at installation time.
    public var canInstall: Bool {
        isPaired && isConnected && developerModeEnabled != false && supportsRequiredOS
    }
}

public enum DeviceServiceError: LocalizedError, Sendable {
    case invalidResponse
    case invalidTeamID
    case missingProject
    case unavailableDevice
    case missingSignedApplication
    case missingPreparedScheme
    case ambiguousPreparedScheme
    case invalidSignedApplication(String)
    case invalidIPAOutput
    case freeDeveloperAppLimit
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Xcode returned an unrecognized device response."
        case .invalidTeamID: return "Enter the 10-character Apple Developer Team ID from Xcode."
        case .missingProject: return "Prepare the game's Xcode project before installing it."
        case .unavailableDevice: return "Connect and pair a supported iPhone or iPad, unlock it, and enable Developer Mode."
        case .missingSignedApplication: return "Xcode completed without producing a signed application."
        case .missingPreparedScheme: return "The project has no shared scheme that builds DmIOS. Prepare the game project again with nxnative."
        case .ambiguousPreparedScheme: return "The project has several shared schemes that build DmIOS. Prepare a fresh game project or select its scheme in Xcode."
        case .invalidSignedApplication(let reason): return "The iOS application is not ready for installation: \(reason)"
        case .invalidIPAOutput: return "Choose a new .ipa filename in a writable folder. Existing files are never replaced."
        case .freeDeveloperAppLimit: return "Apple's free developer account app limit has been reached. Remove another app installed with that account from this iPhone or iPad, then try again."
        case .commandFailed(let message): return message
        }
    }
}

public enum DeviceService {
    public static func discover(using runner: ProcessRunner = ProcessRunner()) async throws -> [AppleDevice] {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nxport-devices-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let jsonURL = temporary.appendingPathComponent("devices.json")
        let result = try await runner.run(ProcessCommand(executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["devicectl", "list", "devices", "--timeout", "20", "--json-output", jsonURL.path],
            environment: ToolEnvironment.values,
            redactedDescription: "xcrun devicectl list devices"))
        guard result.exitCode == 0 else { throw DeviceServiceError.commandFailed(String(result.output.suffix(4000))) }
        return try parseDevices(Data(contentsOf: jsonURL))
    }

    public static func deploymentPlan(projectURL: URL, teamID: String, device: AppleDevice,
                                      derivedDataURL: URL) throws -> DeploymentPlan {
        let team = teamID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
            throw DeviceServiceError.invalidTeamID
        }
        guard projectURL.pathExtension == "xcodeproj",
              FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("project.pbxproj").path) else {
            throw DeviceServiceError.missingProject
        }
        guard device.canInstall else { throw DeviceServiceError.unavailableDevice }
        let scheme = try preparedScheme(in: projectURL)
        let deploymentRoot = derivedDataURL.resolvingSymlinksInPath().standardizedFileURL
        let products = deploymentRoot.appendingPathComponent("Build/Products/Release-iphoneos", isDirectory: true)
        let signedApp = products.appendingPathComponent("DmIOS.app", isDirectory: true)
        var buildArguments = [
            "xcodebuild", "-project", projectURL.path, "-scheme", scheme, "-configuration", "Release",
            "-destination", "platform=iOS,id=\(device.udid)", "-derivedDataPath", deploymentRoot.path,
            "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration",
            "DEVELOPMENT_TEAM=\(team)", "CODE_SIGN_STYLE=Automatic", "CODE_SIGN_IDENTITY=Apple Development",
            "CODE_SIGNING_ALLOWED=YES", "CODE_SIGNING_REQUIRED=YES", "DM_COPY_GAME_RESOURCES=YES",
            // Prepared projects pin OBJROOT, SYMROOT and CONFIGURATION_TEMP_DIR
            // through this variable. Override it as well as -derivedDataPath so
            // Swift dependency caches and compile records belong to one build.
            "DM_XCODE_OUTPUT_ROOT=\(deploymentRoot.path)",
            "CONFIGURATION_BUILD_DIR=\(products.path)"
        ]
        if let identifier = defaultBundleIdentifierOverride(in: projectURL, teamID: team) {
            buildArguments.append("PRODUCT_BUNDLE_IDENTIFIER=\(identifier)")
        }
        buildArguments.append("build")
        let build = ProcessCommand(executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: buildArguments,
            workingDirectoryURL: projectURL.deletingLastPathComponent(), environment: ToolEnvironment.values,
            redactedDescription: "xcodebuild DmIOS — sign for the selected device with the configured Xcode team")
        let install = ProcessCommand(executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: [
            "devicectl", "device", "install", "app", "--device", device.id, signedApp.path
        ], environment: ToolEnvironment.values,
            redactedDescription: "xcrun devicectl device install app — selected device")
        return DeploymentPlan(buildCommand: build, installCommand: install, signedApplicationURL: signedApp,
                              deviceUDID: device.udid)
    }

    /// Give nxnative's shared default ID a stable per-team namespace. Custom IDs,
    /// modified Info.plists and multi-target projects retain their existing settings.
    static func defaultBundleIdentifierOverride(in projectURL: URL, teamID: String) -> String? {
        guard teamID.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              let data = try? Data(contentsOf: projectURL.appendingPathComponent("project.pbxproj")),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let objects = plist["objects"] as? [String: [String: Any]],
              let rootID = plist["rootObject"] as? String,
              let project = objects[rootID], project["isa"] as? String == "PBXProject",
              let targets = project["targets"] as? [String], targets.count == 1,
              let target = objects[targets[0]], target["isa"] as? String == "PBXNativeTarget",
              target["name"] as? String == "DmIOS",
              target["productType"] as? String == "com.apple.product-type.application",
              let listID = target["buildConfigurationList"] as? String,
              let list = objects[listID], list["isa"] as? String == "XCConfigurationList",
              let configurationIDs = list["buildConfigurations"] as? [String] else { return nil }
        let releases = configurationIDs.compactMap { objects[$0] }.filter {
            $0["isa"] as? String == "XCBuildConfiguration" && $0["name"] as? String == "Release"
        }
        guard releases.count == 1,
              let settings = releases[0]["buildSettings"] as? [String: Any],
              let identifier = settings["PRODUCT_BUNDLE_IDENTIFIER"] as? String,
              identifier.range(of: "^org\\.nxnative\\.[0-9a-f]{16}$", options: .regularExpression) != nil,
              settings["INFOPLIST_FILE"] as? String == "Gen/Info.plist" else { return nil }
        let infoURL = projectURL.deletingLastPathComponent().appendingPathComponent("Gen/Info.plist")
        guard let infoData = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "$(PRODUCT_BUNDLE_IDENTIFIER)" else { return nil }
        let titleID = identifier.dropFirst("org.nxnative.".count)
        return "org.nxnative.\(teamID.lowercased()).\(titleID)"
    }

    /// `--prepare-xcode` names schemes after the game and title ID, not the DmIOS target.
    /// Read the generated shared scheme files without invoking Xcode or contacting a service.
    public static func preparedScheme(in projectURL: URL) throws -> String {
        let directory = projectURL.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        let matching = entries.filter { url in
            guard url.pathExtension == "xcscheme",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let data = try? Data(contentsOf: url) else { return false }
            let target = SchemeTargetParser()
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.delegate = target
            return parser.parse() && target.buildsDmIOS
        }
        guard !matching.isEmpty else { throw DeviceServiceError.missingPreparedScheme }
        guard matching.count == 1 else { throw DeviceServiceError.ambiguousPreparedScheme }
        return matching[0].deletingPathExtension().lastPathComponent
    }

    /// Xcode manages signing using its existing account. A successful build must produce
    /// a certificate-signed app and a matching, current provisioning profile.
    public static func buildSignedApplication(_ plan: DeploymentPlan, using runner: ProcessRunner,
                                              onLine: @Sendable @escaping (String) -> Void = { _ in }) async throws -> URL {
        try Task.checkCancellation()
        let build = try await runner.run(plan.buildCommand, onLine: onLine)
        guard build.exitCode == 0 else { throw DeviceServiceError.commandFailed(String(build.output.suffix(6000))) }
        try await verifySignedApplication(plan.signedApplicationURL, deviceUDID: plan.deviceUDID,
                                          using: runner, onLine: onLine)
        return plan.signedApplicationURL
    }

    public static func installSignedApplication(_ plan: DeploymentPlan, using runner: ProcessRunner,
                                                onLine: @Sendable @escaping (String) -> Void = { _ in }) async throws {
        try await verifySignedApplication(plan.signedApplicationURL, deviceUDID: plan.deviceUDID,
                                          using: runner, onLine: onLine)
        try Task.checkCancellation()
        let install = try await runner.run(plan.installCommand, onLine: onLine)
        guard install.exitCode == 0 else { throw installationError(output: install.output) }
    }

    static func installationError(output: String) -> DeviceServiceError {
        let message = output.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        if message.contains("maximum number of installed apps using a free developer profile") {
            return .freeDeveloperAppLimit
        }
        return .commandFailed(String(output.suffix(6000)))
    }

    public static func buildAndInstall(_ plan: DeploymentPlan, using runner: ProcessRunner,
                                       onLine: @Sendable @escaping (String) -> Void = { _ in }) async throws -> URL {
        let app = try await buildSignedApplication(plan, using: runner, onLine: onLine)
        try await installSignedApplication(plan, using: runner, onLine: onLine)
        return app
    }

    /// Keep the signed bundle intact under Payload. Staging lives on the destination
    /// volume, allowing an atomic, exclusive publication even if another export races us.
    public static func exportSignedIPA(applicationURL: URL, outputURL: URL, using runner: ProcessRunner,
                                       onLine: @Sendable @escaping (String) -> Void = { _ in }) async throws -> URL {
        try validateIPAOutput(outputURL)
        let sourcePath = applicationURL.resolvingSymlinksInPath().standardizedFileURL.path
        let destinationPath = outputURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        guard destinationPath != sourcePath, !destinationPath.hasPrefix(sourcePath + "/") else {
            throw DeviceServiceError.invalidIPAOutput
        }
        try await verifySignedApplication(applicationURL, using: runner, onLine: onLine)
        let staging = outputURL.deletingLastPathComponent().appendingPathComponent(".nxport-export-\(UUID().uuidString)", isDirectory: true)
        let payload = staging.appendingPathComponent("Payload", isDirectory: true)
        let app = payload.appendingPathComponent(applicationURL.lastPathComponent, isDirectory: true)
        let archive = staging.appendingPathComponent("signed.ipa.partial")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        // ditto preserves executable permissions and bundle contents, while omitting
        // Finder metadata that is unnecessary in an iOS installation archive.
        try await runChecked(ProcessCommand(executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["--norsrc", "--noextattr", "--noacl", applicationURL.path, app.path],
            redactedDescription: "Copy signed iOS application for export"), using: runner, onLine: onLine)
        try await verifySignedApplication(app, using: runner, onLine: onLine)
        try await runChecked(ProcessCommand(executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", payload.path, archive.path],
            redactedDescription: "Package signed IPA with provisioning profile"), using: runner, onLine: onLine)
        try Task.checkCancellation()
        try publishIPA(archive, to: outputURL)
        return outputURL
    }

    static func validateIPAOutput(_ outputURL: URL) throws {
        let parent = outputURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard outputURL.isFileURL, outputURL.pathExtension.lowercased() == "ipa",
              FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isWritableFile(atPath: parent.path),
              !FileManager.default.fileExists(atPath: outputURL.path),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: outputURL.path)) == nil else {
            throw DeviceServiceError.invalidIPAOutput
        }
    }

    static func publishIPA(_ archive: URL, to output: URL) throws {
        // An exclusive rename publishes atomically without replacing a winner,
        // including dangling symlinks, and also works on volumes without hard links.
        guard Darwin.renamex_np(archive.path, output.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw DeviceServiceError.invalidIPAOutput }
            throw DeviceServiceError.commandFailed("Could not publish the signed IPA: \(String(cString: strerror(errno)))")
        }
    }

    private static func runChecked(_ command: ProcessCommand, using runner: ProcessRunner,
                                   onLine: @Sendable @escaping (String) -> Void) async throws {
        try Task.checkCancellation()
        let result = try await runner.run(command, onLine: onLine)
        guard result.exitCode == 0 else { throw DeviceServiceError.commandFailed(String(result.output.suffix(6000))) }
        try Task.checkCancellation()
    }

    static func verifySignedApplication(_ applicationURL: URL, deviceUDID: String? = nil, using runner: ProcessRunner,
                                         onLine: @Sendable @escaping (String) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        guard applicationURL.pathExtension == "app",
              FileManager.default.fileExists(atPath: applicationURL.appendingPathComponent("Info.plist").path) else {
            throw DeviceServiceError.missingSignedApplication
        }
        // Checking only codesign --verify accepts ad-hoc signatures. Require an Apple
        // certificate chain and then compare its actual certificate with the profile.
        try await runChecked(signedApplicationVerificationCommand(applicationURL), using: runner, onLine: onLine)
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(applicationURL as CFURL, [], &code) == errSecSuccess, let code else {
            throw DeviceServiceError.invalidSignedApplication("the code signature could not be read.")
        }
        var rawInformation: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &rawInformation) == errSecSuccess,
              let information = rawInformation as? [String: Any],
              let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let certificate = certificates.first,
              let identifier = information[kSecCodeInfoIdentifier as String] as? String,
              let team = information[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty else {
            throw DeviceServiceError.invalidSignedApplication("a real Apple development or distribution signature is required.")
        }
        let infoData = try Data(contentsOf: applicationURL.appendingPathComponent("Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String, bundleID == identifier,
              (info["CFBundleSupportedPlatforms"] as? [String])?.contains("iPhoneOS") == true else {
            throw DeviceServiceError.invalidSignedApplication("the signed identifier or iOS platform does not match Info.plist.")
        }
        let profileURL = applicationURL.appendingPathComponent("embedded.mobileprovision")
        guard FileManager.default.isReadableFile(atPath: profileURL.path) else {
            throw DeviceServiceError.invalidSignedApplication("the embedded provisioning profile is missing.")
        }
        let profile = try decodeProvisioningProfile(Data(contentsOf: profileURL))
        try validateProvisioning(profile: profile, bundleID: bundleID, teamID: team,
            certificate: SecCertificateCopyData(certificate) as Data,
            entitlements: information[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:],
            deviceUDID: deviceUDID)
        try Task.checkCancellation()
    }

    static func signedApplicationVerificationCommand(_ applicationURL: URL) -> ProcessCommand {
        ProcessCommand(executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--strict", "-R", "=anchor apple generic", applicationURL.path],
            redactedDescription: "Verify Apple-signed iOS application")
    }

    /// A provisioning profile is signed CMS, rather than an arbitrary plist with a
    /// familiar extension. Validate the CMS signature and its trust before reading it.
    static func decodeProvisioningProfile(_ data: Data) throws -> [String: Any] {
        func invalid() -> DeviceServiceError { .invalidSignedApplication("the embedded provisioning profile has no valid trusted CMS signature.") }
        var possibleDecoder: CMSDecoder?
        guard CMSDecoderCreate(&possibleDecoder) == errSecSuccess, let decoder = possibleDecoder else { throw invalid() }
        let updated = data.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return errSecParam }
            return CMSDecoderUpdateMessage(decoder, address, bytes.count)
        }
        guard updated == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess else { throw invalid() }
        var signerCount = 0
        guard CMSDecoderGetNumSigners(decoder, &signerCount) == errSecSuccess, signerCount == 1 else { throw invalid() }
        var status = CMSSignerStatus.unsigned
        var trust: SecTrust?
        var trustStatus: OSStatus = errSecSuccess
        guard CMSDecoderCopySignerStatus(decoder, 0, SecPolicyCreateBasicX509(), true, &status, &trust, &trustStatus) == errSecSuccess,
              status == .valid, trustStatus == errSecSuccess else { throw invalid() }
        var content: CFData?
        guard CMSDecoderCopyContent(decoder, &content) == errSecSuccess, let content,
              let profile = try PropertyListSerialization.propertyList(from: content as Data, options: [], format: nil) as? [String: Any] else {
            throw invalid()
        }
        return profile
    }

    /// Pure metadata validation is separate from Security's cryptographic verification
    /// so mismatches can be tested without an Apple account or a connected device.
    static func validateProvisioning(profile: [String: Any], bundleID: String, teamID: String, certificate: Data,
                                     entitlements: [String: Any], deviceUDID: String? = nil, now: Date = Date()) throws {
        func reject(_ reason: String) throws { throw DeviceServiceError.invalidSignedApplication(reason) }
        let signedEntitlements = try canonicalEntitlements(entitlements)
        guard let expiration = profile["ExpirationDate"] as? Date, expiration > now else {
            return try reject("the provisioning profile has expired or has no expiration date.")
        }
        if let created = profile["CreationDate"] as? Date, created > now {
            return try reject("the provisioning profile is not yet valid.")
        }
        guard (profile["TeamIdentifier"] as? [String])?.contains(teamID) == true,
              let profileEntitlements = profile["Entitlements"] as? [String: Any],
              profileEntitlements["com.apple.developer.team-identifier"] as? String == teamID,
              signedEntitlements["com.apple.developer.team-identifier"] as? String == teamID else {
            return try reject("the signing team does not match the provisioning profile and entitlements.")
        }
        let allowed = try canonicalEntitlements(profileEntitlements)
        guard (profile["DeveloperCertificates"] as? [Data])?.contains(certificate) == true else {
            return try reject("the signing certificate is not authorized by the provisioning profile.")
        }
        guard let appID = signedEntitlements["application-identifier"] as? String,
              let prefixes = profile["ApplicationIdentifierPrefix"] as? [String],
              prefixes.contains(where: { appID == "\($0).\(bundleID)" }),
              let allowedID = allowed["application-identifier"] as? String,
              entitlementPattern(allowedID, matches: appID) else {
            return try reject("the signed application identifier does not match the bundle or provisioning profile.")
        }
        // App Store profiles cannot be installed directly on the selected device.
        let devices = profile["ProvisionedDevices"] as? [String] ?? []
        let allDevices = profile["ProvisionsAllDevices"] as? Bool == true
        guard allDevices || !devices.isEmpty else {
            return try reject("the provisioning profile does not authorize installation outside the App Store.")
        }
        if let deviceUDID, !allDevices, !devices.contains(where: { $0.caseInsensitiveCompare(deviceUDID) == .orderedSame }) {
            return try reject("the provisioning profile does not include the selected iPhone or iPad.")
        }
        for (key, requested) in signedEntitlements {
            guard entitlement(allowed[key], permits: requested) else {
                return try reject("the provisioning profile does not authorize entitlement \(key).")
            }
        }
    }

    private static func canonicalEntitlements(_ entitlements: [String: Any]) throws -> [String: Any] {
        var canonical = entitlements
        // Security returns this effective alias on SDK 27 even when only the iOS
        // application-identifier is encoded in the signed entitlement blob. Both
        // names grant the same identity; a conflicting value must still fail.
        if let alias = canonical.removeValue(forKey: "com.apple.application-identifier") {
            guard let alias = alias as? String,
                  canonical["application-identifier"] == nil || canonical["application-identifier"] as? String == alias else {
                throw DeviceServiceError.invalidSignedApplication("the application identifier entitlement aliases disagree.")
            }
            canonical["application-identifier"] = alias
        }
        return canonical
    }

    private static func entitlementPattern(_ allowed: String, matches requested: String) -> Bool {
        if allowed == requested { return true }
        // Provisioning profiles use a trailing wildcard, not arbitrary glob patterns.
        return allowed.hasSuffix("*") && allowed.filter({ $0 == "*" }).count == 1 && requested.hasPrefix(allowed.dropLast())
    }

    private static func entitlement(_ allowed: Any?, permits requested: Any) -> Bool {
        if let requested = requested as? String {
            guard let allowed = allowed as? String else { return false }
            return entitlementPattern(allowed, matches: requested)
        }
        if let requested = requested as? [Any] {
            guard let allowed = allowed as? [Any] else { return false }
            return requested.allSatisfy { value in allowed.contains { entitlement($0, permits: value) } }
        }
        if let requested = requested as? [String: Any] {
            guard let allowed = allowed as? [String: Any] else { return false }
            return requested.allSatisfy { entitlement(allowed[$0.key], permits: $0.value) }
        }
        // A disabled boolean entitlement grants nothing, including when omitted by
        // the profile. Numeric entitlements still require an exact authorized value.
        if allowed == nil, let boolean = requested as? NSNumber,
           CFGetTypeID(boolean) == CFBooleanGetTypeID(), !boolean.boolValue { return true }
        guard let allowed = allowed as? NSObject, let requested = requested as? NSObject else { return false }
        return allowed.isEqual(requested)
    }

    /// Supports both the legacy CoreDevice JSON and Xcode 27's replacement `properties` schema.
    public static func parseDevices(_ data: Data) throws -> [AppleDevice] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let entries = result["devices"] as? [[String: Any]] else {
            throw DeviceServiceError.invalidResponse
        }
        return entries.compactMap { entry -> AppleDevice? in
            let properties = entry["properties"] as? [String: Any] ?? [:]
            let hardware = properties["hardware"] as? [String: Any]
                ?? entry["hardwareProperties"] as? [String: Any] ?? [:]
            let connection = properties["connection"] as? [String: Any]
                ?? entry["connectionProperties"] as? [String: Any] ?? [:]
            let state = properties["state"] as? [String: Any]
                ?? entry["deviceProperties"] as? [String: Any] ?? [:]
            let software = properties["software"] as? [String: Any] ?? [:]
            let legacyDevice = entry["deviceProperties"] as? [String: Any] ?? [:]

            let reality = string(hardware["reality"]).lowercased()
            let visibility = string(state["visibilityClass"] ?? entry["visibilityClass"]).lowercased()
            guard reality != "simulated", reality != "virtual", visibility != "simulators" else { return nil }
            let platform = string(hardware["platform"]).lowercased()
            let deviceType = string(hardware["deviceType"]).lowercased()
            guard ["ios", "ipados"].contains(platform) || ["iphone", "ipad"].contains(deviceType) else { return nil }
            guard let id = entry["identifier"] as? String, !id.isEmpty else { return nil }

            let osValue = software["osVersionNumber"]
            let version: String
            if let object = osValue as? [String: Any] {
                version = string(object["stringValue"])
            } else {
                version = string(osValue ?? legacyDevice["osVersionNumber"])
            }
            let pairing = string(connection["pairingState"]).lowercased()
            let connectionState = string(connection["state"] ?? connection["tunnelState"]).lowercased()
            let developerModeValue = state["developerModeStatus"] ?? software["developerModeStatus"]
                ?? legacyDevice["developerModeStatus"]
            let developerMode: Bool?
            if let bool = developerModeValue as? Bool {
                developerMode = bool
            } else if let status = developerModeValue as? [String: Any] {
                // Xcode 27 encodes this enum as {"enabled":{"mode":1}},
                // whereas earlier releases returned the string "enabled".
                if status["enabled"] != nil && status["disabled"] == nil {
                    developerMode = true
                } else if status["disabled"] != nil && status["enabled"] == nil {
                    developerMode = false
                } else {
                    developerMode = nil
                }
            } else {
                switch string(developerModeValue).lowercased() {
                case "enabled": developerMode = true
                case "disabled": developerMode = false
                default: developerMode = nil
                }
            }
            let name = string(state["name"] ?? legacyDevice["name"])
            let model = string(hardware["marketingName"] ?? hardware["productType"])
            return AppleDevice(id: id, udid: string(hardware["udid"]).isEmpty ? id : string(hardware["udid"]),
                               name: name.isEmpty ? model : name, model: model, osVersion: version,
                               transport: string(connection["transportType"]), isPaired: pairing == "paired",
                               isConnected: ["connected", "available"].contains(connectionState),
                               developerModeEnabled: developerMode)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func string(_ value: Any?) -> String { value as? String ?? "" }
}

private final class SchemeTargetParser: NSObject, XMLParserDelegate {
    private var inBuildAction = false
    private(set) var buildsDmIOS = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "BuildAction" { inBuildAction = true }
        if inBuildAction && elementName == "BuildableReference",
           attributeDict["BlueprintName"] == "DmIOS",
           attributeDict["BuildableName"] == "DmIOS.app" {
            buildsDmIOS = true
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "BuildAction" { inBuildAction = false }
    }
}

public struct DeploymentPlan: Sendable {
    public let buildCommand: ProcessCommand
    public let installCommand: ProcessCommand
    public let signedApplicationURL: URL
    public let deviceUDID: String?

    public init(buildCommand: ProcessCommand, installCommand: ProcessCommand, signedApplicationURL: URL,
                deviceUDID: String? = nil) {
        self.buildCommand = buildCommand
        self.installCommand = installCommand
        self.signedApplicationURL = signedApplicationURL
        self.deviceUDID = deviceUDID
    }
}
