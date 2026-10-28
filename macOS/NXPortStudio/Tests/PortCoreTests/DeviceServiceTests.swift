import XCTest
@testable import PortCore

final class DeviceServiceTests: XCTestCase {
    func testModernCoreDeviceSchemaExcludesSimulatorsAndNonIOSDevices() throws {
        let json = #"""
        {"result":{"devices":[
          {"identifier":"physical-phone","properties":{
            "hardware":{"reality":"physical","platform":"iOS","deviceType":"iPhone","marketingName":"iPhone 16 Pro","udid":"device-udid"},
            "connection":{"pairingState":"paired","state":"connected","transportType":"localNetwork"},
            "state":{"name":"Test phone","visibilityClass":"default","developerModeStatus":{"enabled":{"mode":1}}},
            "software":{"osVersionNumber":{"stringValue":"26.1"}}
          }},
          {"identifier":"simulator","properties":{
            "hardware":{"reality":"simulated","platform":"iOS","deviceType":"iPhone"},
            "state":{"visibilityClass":"simulators"}
          }},
          {"identifier":"tv","hardwareProperties":{"reality":"physical","platform":"tvOS","deviceType":"AppleTV"}}
        ]}}
        """#
        let devices = try DeviceService.parseDevices(Data(json.utf8))
        XCTAssertEqual(devices.count, 1)
        let phone = try XCTUnwrap(devices.first)
        XCTAssertEqual(phone.id, "physical-phone")
        XCTAssertEqual(phone.udid, "device-udid")
        XCTAssertEqual(phone.connectionLabel, "Wi-Fi")
        XCTAssertEqual(phone.osVersion, "26.1")
        XCTAssertEqual(phone.developerModeEnabled, true)
        XCTAssertTrue(phone.canInstall)
    }

    func testModernDisabledDeveloperModePreventsInstallation() throws {
        let json = #"""
        {"result":{"devices":[{"identifier":"phone","properties":{
          "hardware":{"reality":"physical","platform":"iOS","deviceType":"iPhone"},
          "connection":{"pairingState":"paired","state":"connected","transportType":"wired"},
          "state":{"name":"Test phone","developerModeStatus":{"disabled":{}}},
          "software":{"osVersionNumber":{"stringValue":"27.0.1"}}
        }}]}}
        """#
        let phone = try XCTUnwrap(DeviceService.parseDevices(Data(json.utf8)).first)
        XCTAssertEqual(phone.developerModeEnabled, false)
        XCTAssertFalse(phone.canInstall)
    }

    func testLegacySchemaKeepsOfflinePairedDeviceUnavailable() throws {
        let json = #"""
        {"result":{"devices":[
          {"identifier":"tablet","hardwareProperties":{"reality":"physical","platform":"iOS","deviceType":"iPad","marketingName":"iPad Pro","udid":"tablet-udid"},
           "connectionProperties":{"pairingState":"paired","tunnelState":"disconnected","transportType":"network"},
           "deviceProperties":{"name":"Test tablet","osVersionNumber":"26.0","developerModeStatus":"enabled"}},
          {"identifier":"usb-phone","hardwareProperties":{"reality":"physical","platform":"iOS","deviceType":"iPhone"},
           "connectionProperties":{"pairingState":"paired","tunnelState":"connected","transportType":"usb"},
           "deviceProperties":{"name":"Test phone","osVersionNumber":"25.0","developerModeStatus":"disabled"}}
        ]}}
        """#
        let devices = try DeviceService.parseDevices(Data(json.utf8))
        let tablet = try XCTUnwrap(devices.first { $0.id == "tablet" })
        XCTAssertTrue(tablet.isPaired)
        XCTAssertFalse(tablet.isConnected)
        XCTAssertFalse(tablet.canInstall)
        let phone = try XCTUnwrap(devices.first { $0.id == "usb-phone" })
        XCTAssertEqual(phone.connectionLabel, "USB")
        XCTAssertFalse(phone.supportsRequiredOS)
        XCTAssertFalse(phone.canInstall)
    }

    func testEmptyResponseIsValidButSchemaChangesAreReported() throws {
        XCTAssertEqual(try DeviceService.parseDevices(Data(#"{"result":{"devices":[]}}"#.utf8)), [])
        XCTAssertThrowsError(try DeviceService.parseDevices(Data(#"{"result":{}}"#.utf8)))
    }

    private var cachedPhone: AppleDevice {
        AppleDevice(id: "selected-phone", udid: "selected-udid", name: "Fixture phone", model: "iPhone",
                    osVersion: "27.2", transport: "localNetwork", isPaired: true,
                    isConnected: false, developerModeEnabled: true)
    }

    // Sanitized structural fixture of the directed Xcode 27 details response.
    // Modern properties coexist with compatibility properties; DDI is reported
    // by deviceProperties, not by the passive discovery list.
    private var directedDetails: String {
        #"""
        {"result":{"identifier":"selected-phone",
          "properties":{
            "hardware":{"reality":"physical","platform":"iOS","deviceType":"iPhone","udid":"selected-udid"},
            "connection":{"pairingState":"paired","state":"connected","transportType":"localNetwork"},
            "state":{"name":"Fixture phone","developerModeStatus":{"enabled":{"mode":1}}},
            "software":{"osVersionNumber":{"components":[27,2,0,0,0],"originalComponentsCount":2,"stringValue":"27.2"}}
          },
          "hardwareProperties":{"platform":"iOS","deviceType":"iPhone","udid":"selected-udid"},
          "connectionProperties":{"pairingState":"paired","tunnelState":"connected","transportType":"localNetwork"},
          "deviceProperties":{"ddiServicesAvailable":true,"developerModeStatus":"enabled","osVersionNumber":"27.2"}
        }}
        """#
    }

    func testDirectedConnectionResolvesOnlySelectedCachedOfflineDevice() async throws {
        let selected = cachedPhone, json = Data(directedDetails.utf8)
        XCTAssertTrue(selected.canAttemptConnection)
        XCTAssertFalse(selected.canInstall)
        let resolved = try await DeviceService.resolveConnection(selected: selected, execute: { command in
            XCTAssertEqual(command.executableURL.path, "/usr/bin/xcrun")
            XCTAssertEqual(Array(command.arguments.prefix(8)), ["devicectl", "device", "info", "details", "--device", "selected-phone", "--timeout", "20"])
            XCTAssertFalse(command.arguments.contains("list"))
            XCTAssertFalse(command.arguments.contains("install"))
            let index = try XCTUnwrap(command.arguments.firstIndex(of: "--json-output"))
            try json.write(to: URL(fileURLWithPath: command.arguments[index + 1]))
            return ProcessResult(exitCode: 0, output: "")
        })
        XCTAssertEqual(resolved.id, selected.id)
        XCTAssertEqual(resolved.udid, selected.udid)
        XCTAssertTrue(resolved.isPaired)
        XCTAssertTrue(resolved.isConnected)
        XCTAssertTrue(resolved.canInstall)
        XCTAssertEqual(resolved.connectionLabel, "Wi-Fi")
        XCTAssertFalse(selected.isConnected, "Resolving a new snapshot never fabricates a connection in the original list.")
    }

    func testDirectedDetailsRejectIdentityConnectionAndDDIMismatches() throws {
        let original = directedDetails
        for invalid in [
            original.replacingOccurrences(of: "selected-phone", with: "different-phone"),
            original.replacingOccurrences(of: "selected-udid", with: "different-udid"),
            original.replacingOccurrences(of: "connected", with: "disconnected"),
            original.replacingOccurrences(of: "paired", with: "unpaired"),
            original.replacingOccurrences(of: #""ddiServicesAvailable":true,"#, with: ""),
            original.replacingOccurrences(of: #""ddiServicesAvailable":true"#, with: #""ddiServicesAvailable":false"#),
            original.replacingOccurrences(of: #""ddiServicesAvailable":true"#, with: #""ddiServicesAvailable":"true""#),
            original.replacingOccurrences(of: #""ddiServicesAvailable":true"#, with: #""ddiServicesAvailable":1"#),
            original.replacingOccurrences(of: #""developerModeStatus":"enabled""#, with: #""developerModeStatus":"disabled""#),
            original.replacingOccurrences(of: "27.2", with: "25.0"),
            original.replacingOccurrences(of: "physical", with: "simulated"),
            original.replacingOccurrences(of: "iOS", with: "tvOS"),
            #"{"result":{"devices":[]}}"#
        ] {
            XCTAssertThrowsError(try DeviceService.parseDeviceDetails(Data(invalid.utf8), selected: cachedPhone))
        }
        // A missing actual UDID cannot be replaced by the parser's ID fallback.
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any])
        var result = try XCTUnwrap(object["result"] as? [String: Any])
        var properties = try XCTUnwrap(result["properties"] as? [String: Any])
        var hardware = try XCTUnwrap(properties["hardware"] as? [String: Any]); hardware.removeValue(forKey: "udid")
        properties["hardware"] = hardware; result["properties"] = properties
        var legacy = try XCTUnwrap(result["hardwareProperties"] as? [String: Any]); legacy.removeValue(forKey: "udid")
        result["hardwareProperties"] = legacy
        let bytes = try JSONSerialization.data(withJSONObject: ["result": result])
        let fallback = AppleDevice(id: "selected-phone", udid: "selected-phone", name: "Fixture", model: "iPhone", osVersion: "27.2",
                                   transport: "usb", isPaired: true, isConnected: false, developerModeEnabled: nil)
        XCTAssertThrowsError(try DeviceService.parseDeviceDetails(bytes, selected: fallback))
    }

    func testDirectedDetailsAcceptLegacyShapeAndUnknownDeveloperMode() throws {
        let json = #"""
        {"result":{"identifier":"selected-phone",
          "hardwareProperties":{"reality":"physical","platform":"iOS","deviceType":"iPhone","udid":"selected-udid"},
          "connectionProperties":{"pairingState":"paired","tunnelState":"connected","transportType":"usb"},
          "deviceProperties":{"name":"Fixture","ddiServicesAvailable":true,"osVersionNumber":"27.2"}}}
        """#
        let device = try DeviceService.parseDeviceDetails(Data(json.utf8), selected: cachedPhone)
        XCTAssertTrue(device.canInstall)
        XCTAssertNil(device.developerModeEnabled)
    }

    func testDirectedDetailsPreserveSelectedIdentityCasingWithFreshConnection() throws {
        let selected = AppleDevice(id: "selected-phone", udid: "selected-udid", name: "Cached name", model: "Cached model",
                                   osVersion: "26.0", transport: "usb", isPaired: true,
                                   isConnected: false, developerModeEnabled: nil)
        let json = directedDetails.replacingOccurrences(of: "selected-phone", with: "SELECTED-PHONE")
            .replacingOccurrences(of: "selected-udid", with: "SELECTED-UDID")
        let device = try DeviceService.parseDeviceDetails(Data(json.utf8), selected: selected)
        XCTAssertEqual(device.id, selected.id)
        XCTAssertEqual(device.udid, selected.udid)
        XCTAssertEqual(device.name, "Fixture phone")
        XCTAssertEqual(device.osVersion, "27.2")
        XCTAssertEqual(device.connectionLabel, "Wi-Fi")
        XCTAssertEqual(device.developerModeEnabled, true)
        XCTAssertTrue(device.canInstall)
    }

    func testDirectedConnectionTimeoutAndCancellationDoNotPromoteSnapshot() async throws {
        let selected = cachedPhone
        do {
            _ = try await DeviceService.resolveConnection(selected: selected, execute: { _ in
                ProcessResult(exitCode: 1, output: "The directed device request timed out.")
            })
            XCTFail("An unsuccessful CoreDevice command cannot promote a device.")
        } catch DeviceServiceError.commandFailed { }
        let json = Data(directedDetails.utf8)
        let task = Task {
            try await DeviceService.resolveConnection(selected: selected, execute: { command in
                let index = try XCTUnwrap(command.arguments.firstIndex(of: "--json-output"))
                try json.write(to: URL(fileURLWithPath: command.arguments[index + 1]))
                withUnsafeCurrentTask { $0?.cancel() }
                return ProcessResult(exitCode: 0, output: "")
            })
        }
        do { _ = try await task.value; XCTFail("Cancellation must discard even a valid late response.") }
        catch is CancellationError { }
        XCTAssertFalse(selected.canInstall)
    }

    func testDirectedConnectionDoesNotProbeIneligibleDevices() async throws {
        for device in [
            AppleDevice(id: "phone", udid: "udid", name: "Fixture", model: "iPhone", osVersion: "27.2", transport: "usb", isPaired: false, isConnected: false, developerModeEnabled: true),
            AppleDevice(id: "phone", udid: "udid", name: "Fixture", model: "iPhone", osVersion: "25.0", transport: "usb", isPaired: true, isConnected: true, developerModeEnabled: true),
            AppleDevice(id: "phone", udid: "udid", name: "Fixture", model: "iPhone", osVersion: "27.2", transport: "usb", isPaired: true, isConnected: true, developerModeEnabled: false)
        ] {
            do {
                _ = try await DeviceService.resolveConnection(selected: device, execute: { _ in
                    XCTFail("An ineligible device must not be probed."); return ProcessResult(exitCode: 0, output: "")
                })
                XCTFail("An ineligible device cannot be resolved.")
            } catch DeviceServiceError.unavailableDevice { }
        }
    }

    func testDeploymentPlanPreservesPathsAndEnablesSigningExplicitly() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let project = temporary.appendingPathComponent("Game files/xcode/DmIOS.xcodeproj")
        try writeProject(in: project, identifier: "org.nxnative.010015100b514000")
        // build_ipa.sh replaces '/' and ':' in the display name and adds the title ID.
        let generatedScheme = "Test__ Adventure (010015100B514000)"
        try writeScheme(named: generatedScheme, in: project)
        let phone = AppleDevice(id: "core-device", udid: "phone-udid", name: "Phone", model: "iPhone",
                                osVersion: "26.0", transport: "usb", isPaired: true,
                                isConnected: true, developerModeEnabled: nil)
        let plan = try DeviceService.deploymentPlan(projectURL: project, teamID: "abcdefgh12", device: phone,
            derivedDataURL: temporary.appendingPathComponent("Signed build"))
        XCTAssertTrue(plan.buildCommand.arguments.contains("DEVELOPMENT_TEAM=ABCDEFGH12"))
        XCTAssertTrue(plan.buildCommand.arguments.contains("-allowProvisioningUpdates"))
        XCTAssertTrue(plan.buildCommand.arguments.contains("platform=iOS,id=phone-udid"))
        XCTAssertTrue(plan.buildCommand.arguments.contains("DM_XCODE_OUTPUT_ROOT=\(temporary.appendingPathComponent("Signed build").resolvingSymlinksInPath().standardizedFileURL.path)"),
                      "Prepared projects must not reuse their pinned Xcode intermediates with another deployment's module caches.")
        XCTAssertTrue(plan.buildCommand.arguments.contains(project.path))
        XCTAssertTrue(plan.buildCommand.arguments.contains("PRODUCT_BUNDLE_IDENTIFIER=org.nxnative.abcdefgh12.010015100b514000"))
        let schemeFlag = try XCTUnwrap(plan.buildCommand.arguments.firstIndex(of: "-scheme"))
        XCTAssertEqual(plan.buildCommand.arguments[schemeFlag + 1], generatedScheme)
        XCTAssertTrue(plan.installCommand.arguments.contains("core-device"))
        XCTAssertTrue(plan.installCommand.arguments.contains(plan.signedApplicationURL.path))
        XCTAssertFalse(plan.installCommand.arguments.contains("--timeout"))
        XCTAssertEqual(plan.signedApplicationURL.lastPathComponent, "DmIOS.app")
        XCTAssertEqual(plan.deviceUDID, "phone-udid")
        XCTAssertThrowsError(try DeviceService.deploymentPlan(projectURL: project, teamID: "bad\nsetting", device: phone,
            derivedDataURL: temporary))
    }

    func testBundleIdentifierNamespacePreservesCustomIDsAndOtherTargets() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("DmIOS.xcodeproj")
        defer { try? FileManager.default.removeItem(at: project.deletingLastPathComponent()) }
        try writeProject(in: project, identifier: "org.nxnative.0100152000022000")
        XCTAssertEqual(DeviceService.defaultBundleIdentifierOverride(in: project, teamID: "9X76Y99YGD"),
                       "org.nxnative.9x76y99ygd.0100152000022000")
        try writeProject(in: project, identifier: "com.example.my-mario-kart")
        XCTAssertNil(DeviceService.defaultBundleIdentifierOverride(in: project, teamID: "9X76Y99YGD"))
        try writeProject(in: project, identifier: "org.nxnative.9x76y99ygd.0100152000022000")
        XCTAssertNil(DeviceService.defaultBundleIdentifierOverride(in: project, teamID: "9X76Y99YGD"))
        try writeProject(in: project, identifier: "org.nxnative.0100152000022000", includesOtherTarget: true)
        XCTAssertNil(DeviceService.defaultBundleIdentifierOverride(in: project, teamID: "9X76Y99YGD"))
        try writeProject(in: project, identifier: "org.nxnative.0100152000022000", infoIdentifier: "com.example.explicit")
        XCTAssertNil(DeviceService.defaultBundleIdentifierOverride(in: project, teamID: "9X76Y99YGD"))
    }

    private func writeProject(in project: URL, identifier: String, includesOtherTarget: Bool = false,
                              infoIdentifier: String = "$(PRODUCT_BUNDLE_IDENTIFIER)") throws {
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let pbxproj = """
        // !$*UTF8*$!
        {
          archiveVersion = 1;
          objectVersion = 77;
          objects = {
            ROOT = { isa = PBXProject; targets = (APP, \(includesOtherTarget ? "OTHER," : "")); };
            APP = { isa = PBXNativeTarget; name = DmIOS; productType = "com.apple.product-type.application"; buildConfigurationList = CONFIGURATIONS; };
            OTHER = { isa = PBXNativeTarget; name = AnotherApp; };
            CONFIGURATIONS = { isa = XCConfigurationList; buildConfigurations = (RELEASE,); };
            RELEASE = { isa = XCBuildConfiguration; name = Release; buildSettings = {
              PRODUCT_BUNDLE_IDENTIFIER = "\(identifier)";
              INFOPLIST_FILE = Gen/Info.plist;
            }; };
          };
          rootObject = ROOT;
        }
        """
        try Data(pbxproj.utf8).write(to: project.appendingPathComponent("project.pbxproj"))
        let info = project.deletingLastPathComponent().appendingPathComponent("Gen/Info.plist")
        try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": infoIdentifier],
                                                       format: .xml, options: 0)
        try bytes.write(to: info)
    }

    func testPreparedSchemeRejectsMissingOrAmbiguousGameSchemes() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("DmIOS.xcodeproj")
        defer { try? FileManager.default.removeItem(at: project.deletingLastPathComponent()) }
        XCTAssertThrowsError(try DeviceService.preparedScheme(in: project)) { error in
            guard case DeviceServiceError.missingPreparedScheme = error else {
                return XCTFail("Expected a missing prepared game scheme error.")
            }
        }
        try writeScheme(named: "Unrelated", in: project, target: "OtherApp")
        XCTAssertThrowsError(try DeviceService.preparedScheme(in: project))
        try writeScheme(named: "A game (010015100B514000)", in: project)
        XCTAssertEqual(try DeviceService.preparedScheme(in: project), "A game (010015100B514000)")
        try writeScheme(named: "A duplicate game", in: project)
        XCTAssertThrowsError(try DeviceService.preparedScheme(in: project)) { error in
            guard case DeviceServiceError.ambiguousPreparedScheme = error else {
                return XCTFail("Expected an ambiguous prepared game scheme error.")
            }
        }
    }

    private func writeScheme(named name: String, in project: URL, target: String = "DmIOS") throws {
        let directory = project.appendingPathComponent("xcshareddata/xcschemes")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme LastUpgradeVersion="2700" version="1.3">
          <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
            <BuildActionEntries><BuildActionEntry buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES">
              <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="TEST-TARGET" BuildableName="\(target).app" BlueprintName="\(target)" ReferencedContainer="container:DmIOS.xcodeproj"/>
            </BuildActionEntry></BuildActionEntries>
          </BuildAction>
        </Scheme>
        """
        try Data(xml.utf8).write(to: directory.appendingPathComponent(name + ".xcscheme"))
    }

    func testFailedBuildNeverReachesInstallCommand() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let marker = temporary.appendingPathComponent("unexpected-install")
        let plan = DeploymentPlan(
            buildCommand: ProcessCommand(executableURL: URL(fileURLWithPath: "/usr/bin/false")),
            installCommand: ProcessCommand(executableURL: URL(fileURLWithPath: "/usr/bin/touch"), arguments: [marker.path]),
            signedApplicationURL: temporary.appendingPathComponent("DmIOS.app"))
        do {
            _ = try await DeviceService.buildAndInstall(plan, using: ProcessRunner())
            XCTFail("A failed Xcode build must be reported as failure.")
        } catch DeviceServiceError.commandFailed { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testMissingBuildProductNeverReachesInstallCommand() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let marker = temporary.appendingPathComponent("unexpected-install")
        let plan = DeploymentPlan(
            buildCommand: ProcessCommand(executableURL: URL(fileURLWithPath: "/usr/bin/true")),
            installCommand: ProcessCommand(executableURL: URL(fileURLWithPath: "/usr/bin/touch"), arguments: [marker.path]),
            signedApplicationURL: temporary.appendingPathComponent("DmIOS.app"))
        do {
            _ = try await DeviceService.buildAndInstall(plan, using: ProcessRunner())
            XCTFail("A successful process without its signed app must not report installation success.")
        } catch DeviceServiceError.missingSignedApplication { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    private let testTeam = "ABCDEFGH12"
    private let testBundle = "org.example.game"
    private let testCertificate = Data([1, 2, 3, 4])
    private let testNow = Date(timeIntervalSince1970: 1_800_000_000)

    private var signingEntitlements: [String: Any] {
        ["application-identifier": "LEGACY1234.org.example.game",
         "com.apple.developer.team-identifier": testTeam,
         "keychain-access-groups": ["LEGACY1234.org.example.game"],
         "get-task-allow": true]
    }

    private var provisioningProfile: [String: Any] {
        ["ExpirationDate": testNow.addingTimeInterval(3600),
         "CreationDate": testNow.addingTimeInterval(-3600),
         "TeamIdentifier": [testTeam], "ApplicationIdentifierPrefix": ["LEGACY1234"],
         "DeveloperCertificates": [testCertificate], "ProvisionedDevices": ["PHONE-UDID"],
         "Entitlements": ["application-identifier": "LEGACY1234.org.example.*",
                          "com.apple.developer.team-identifier": testTeam,
                          "keychain-access-groups": ["LEGACY1234.*"], "get-task-allow": true]]
    }

    private func validate(_ profile: [String: Any], entitlements: [String: Any]? = nil,
                          certificate: Data? = nil, device: String? = "phone-udid") throws {
        try DeviceService.validateProvisioning(profile: profile, bundleID: testBundle, teamID: testTeam,
            certificate: certificate ?? testCertificate, entitlements: entitlements ?? signingEntitlements,
            deviceUDID: device, now: testNow)
    }

    func testProvisioningAllowsLegacyAppPrefixAndAuthorizedWildcardEntitlements() throws {
        try validate(provisioningProfile)
        var entitlements = signingEntitlements
        entitlements["com.apple.developer.optional-disabled-capability"] = false
        try validate(provisioningProfile, entitlements: entitlements)
    }

    func testEffectiveApplicationIdentifierAliasMustMatchItsSignedIdentity() throws {
        var entitlements = signingEntitlements
        entitlements["com.apple.application-identifier"] = entitlements["application-identifier"]
        try validate(provisioningProfile, entitlements: entitlements)
        entitlements.removeValue(forKey: "application-identifier")
        try validate(provisioningProfile, entitlements: entitlements)
        entitlements["application-identifier"] = "LEGACY1234.org.example.other-game"
        XCTAssertThrowsError(try validate(provisioningProfile, entitlements: entitlements))
        entitlements = signingEntitlements
        entitlements["com.apple.application-identifier"] = true
        XCTAssertThrowsError(try validate(provisioningProfile, entitlements: entitlements))
    }

    func testProvisioningRejectsExpiredProfileWrongCertificateAndOtherDevice() throws {
        var expired = provisioningProfile
        expired["ExpirationDate"] = testNow
        XCTAssertThrowsError(try validate(expired))
        var future = provisioningProfile
        future["CreationDate"] = testNow.addingTimeInterval(60)
        XCTAssertThrowsError(try validate(future))
        XCTAssertThrowsError(try validate(provisioningProfile, certificate: Data([9])))
        XCTAssertThrowsError(try validate(provisioningProfile, device: "another-phone"))
        var appStore = provisioningProfile
        appStore.removeValue(forKey: "ProvisionedDevices")
        XCTAssertThrowsError(try validate(appStore))
        appStore["ProvisionsAllDevices"] = true
        try validate(appStore)
    }

    func testProvisioningRejectsTeamBundleAndEntitlementMismatches() throws {
        var profile = provisioningProfile
        profile["TeamIdentifier"] = ["OTHERTEAM1"]
        XCTAssertThrowsError(try validate(profile))
        var entitlements = signingEntitlements
        entitlements["application-identifier"] = "LEGACY1234.org.example.other-game"
        XCTAssertThrowsError(try validate(provisioningProfile, entitlements: entitlements))
        entitlements = signingEntitlements
        entitlements["keychain-access-groups"] = ["OTHERTEAM1.shared"]
        XCTAssertThrowsError(try validate(provisioningProfile, entitlements: entitlements))
        entitlements = signingEntitlements
        entitlements["com.apple.developer.kernel.increased-memory-limit"] = true
        XCTAssertThrowsError(try validate(provisioningProfile, entitlements: entitlements))
        entitlements = signingEntitlements
        entitlements["com.apple.developer.team-identifier"] = "OTHERTEAM1"
        XCTAssertThrowsError(try validate(provisioningProfile, entitlements: entitlements))
    }

    func testProvisioningRequiresSignedCMSRatherThanPlainPlist() throws {
        let unsigned = try PropertyListSerialization.data(fromPropertyList: provisioningProfile, format: .xml, options: 0)
        XCTAssertThrowsError(try DeviceService.decodeProvisioningProfile(unsigned))
        XCTAssertThrowsError(try DeviceService.decodeProvisioningProfile(Data("broken CMS".utf8)))
    }

    func testIPAPublicationIsExclusiveAndPreservesExistingFile() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let first = temporary.appendingPathComponent("first.partial")
        let second = temporary.appendingPathComponent("second.partial")
        let output = temporary.appendingPathComponent("Game.ipa")
        try Data("first signed export".utf8).write(to: first)
        try Data("other export".utf8).write(to: second)
        try DeviceService.validateIPAOutput(output)
        try DeviceService.publishIPA(first, to: output)
        XCTAssertThrowsError(try DeviceService.publishIPA(second, to: output))
        XCTAssertThrowsError(try DeviceService.validateIPAOutput(output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "first signed export")
        let dangling = temporary.appendingPathComponent("dangling.ipa")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: temporary.appendingPathComponent("missing"))
        XCTAssertThrowsError(try DeviceService.validateIPAOutput(dangling))
        XCTAssertThrowsError(try DeviceService.publishIPA(second, to: dangling))
        XCTAssertThrowsError(try DeviceService.validateIPAOutput(temporary.appendingPathComponent("Game.zip")))
    }

    private func writeUnsignedApplication(in temporary: URL) throws -> URL {
        let app = temporary.appendingPathComponent("Test.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": testBundle, "CFBundleExecutable": "Test",
                                  "CFBundlePackageType": "APPL", "CFBundleSupportedPlatforms": ["iPhoneOS"]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent("Test"))
        return app
    }

    func testAdHocSignatureCannotBeExportedOrInstalled() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let app = try writeUnsignedApplication(in: temporary)
        let runner = ProcessRunner()
        let signed = try await runner.run(ProcessCommand(executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--force", "--sign", "-", app.path]))
        XCTAssertEqual(signed.exitCode, 0, signed.output)
        let ordinaryVerification = try await runner.run(ProcessCommand(executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--strict", app.path]))
        XCTAssertEqual(ordinaryVerification.exitCode, 0, ordinaryVerification.output)
        let output = temporary.appendingPathComponent("Game.ipa")
        do {
            _ = try await DeviceService.exportSignedIPA(applicationURL: app, outputURL: output, using: runner)
            XCTFail("Ad-hoc code must not become a supposedly installable IPA.")
        } catch DeviceServiceError.commandFailed(let message) {
            XCTAssertFalse(message.contains("invalid requirement specification"), message)
            XCTAssertTrue(message.contains("code requirement"), message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let marker = temporary.appendingPathComponent("unexpected-install")
        let plan = DeploymentPlan(buildCommand: ProcessCommand(executableURL: URL(fileURLWithPath: "/usr/bin/true")),
            installCommand: ProcessCommand(executableURL: URL(fileURLWithPath: "/usr/bin/touch"), arguments: [marker.path]),
            signedApplicationURL: app)
        do {
            try await DeviceService.installSignedApplication(plan, using: runner)
            XCTFail("An ad-hoc app must never reach the installer.")
        } catch DeviceServiceError.commandFailed { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: temporary.path).contains { $0.hasPrefix(".nxport-export-") })
    }

    func testAppleSignatureRequirementAcceptsRealAppleCode() async throws {
        let result = try await ProcessRunner().run(DeviceService.signedApplicationVerificationCommand(URL(fileURLWithPath: "/usr/bin/true")))
        XCTAssertEqual(result.exitCode, 0, result.output)
    }

    func testInstallationReportsFreeAccountAppLimitInsteadOfGenericIntegrityFailure() {
        let output = """
        ERROR: The application could not be installed because its integrity could not be verified.
        NSUnderlyingError = This device has reached the MAXIMUM NUMBER OF INSTALLED APPS
        using a free developer profile.
        """
        guard case .freeDeveloperAppLimit = DeviceService.installationError(output: output) else {
            return XCTFail("The actionable Apple account limit must take precedence over generic integrity text.")
        }
        let unrelated = "The application could not be installed because its integrity could not be verified."
        guard case .commandFailed(let detail) = DeviceService.installationError(output: unrelated) else {
            return XCTFail("Other integrity failures must retain their real diagnostic.")
        }
        XCTAssertEqual(detail, unrelated)
    }

    func testCancelledExportPublishesNothing() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let app = try writeUnsignedApplication(in: temporary)
        let output = temporary.appendingPathComponent("Game.ipa")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DeviceService.exportSignedIPA(applicationURL: app, outputURL: output, using: ProcessRunner())
        }
        do { _ = try await task.value; XCTFail("Cancelled export must throw.") }
        catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: temporary.path).contains { $0.hasPrefix(".nxport-export-") })
    }
}
