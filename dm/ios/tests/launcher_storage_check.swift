// The launcher's storage (LauncherSettings.swift LauncherModel), run by test_launcher_storage.py on macOS: only choices that differ from the game's default are
// stored, Reset to tested defaults clears all choices, an env file's values are kept. Argument: a launcher.json of Breath of the Wild (settings.py, GFXAPI=nvn)
import Foundation
@main struct Check {
    static func main() {
        var failed = 0
        func expect(_ c: Bool, _ what: String) { print((c ? "PASS " : "FAIL ") + what); if !c { failed += 1 } }
        let file = try! JSONDecoder().decode(SettingsFile.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let suite = "nxnative.launcher-test." + UUID().uuidString
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        d.set("1", forKey: "launcher.DM_PRESENT_SNAP")   // stored by the old launcher, equal to the default
        d.set("30", forKey: "launcher.DM_FPS_TARGET")    // a changed game setting
        d.set("0", forKey: "launcher.DM_PSO_MTL4")       // a changed performance setting
        d.set("1", forKey: "launcher.DM_FPS_HOLD")       // a value the toggle does not take (on / off): the default
        setenv("DM_ENV_FILE_KEYS", "DM_METAL_HUD", 1); setenv("DM_METAL_HUD", "1", 1)   // set by Documents/env.txt
        let m = LauncherModel(file.settings, defaults: d)
        let scale = file.settings.first { $0.env == "DM_RENDER_SCALE" }!
        expect(["nan", "inf", "-inf", "0.49", "1.01", "invalid"].allSatisfy { !scale.accepts($0) } && scale.accepts("0.5") && scale.accepts("1.00"), "saved ranges reject nonfinite and out-of-range values")
        d.set("nan", forKey: "launcher.DM_RENDER_SCALE")
        expect(LauncherModel(file.settings, defaults: d).values["DM_RENDER_SCALE"] == scale.def, "an invalid saved range loads the default")
        expect(m.values["DM_FPS_TARGET"] == "30" && m.values["DM_PSO_MTL4"] == "0" && m.values["DM_FPS_HOLD"] == "on" && m.values["DM_METAL_HUD"] == "1", "stored choices and the env file are read")
        expect(m.changed, "Reset is offered with changed settings")
        m.values["DM_RENDER_SCALE"] = "1.00"   // the slider's format of the default
        m.apply()
        expect(d.string(forKey: "launcher.DM_PRESENT_SNAP") == nil, "a value equal to the default is not stored (and an old one is dropped)")
        expect(d.string(forKey: "launcher.DM_RENDER_SCALE") == nil && d.string(forKey: "launcher.DM_OPMODE") == nil && d.string(forKey: "launcher.DM_FPS_HOLD") == nil, "defaults are not stored")
        expect(d.string(forKey: "launcher.DM_FPS_TARGET") == "30" && d.string(forKey: "launcher.DM_PSO_MTL4") == "0", "changed choices are stored")
        expect(d.string(forKey: "launcher.DM_METAL_HUD") == nil && String(cString: getenv("DM_METAL_HUD")) == "1", "the env file's value is kept and not stored")
        expect(String(cString: getenv("DM_PSO_MTL4")) == "0" && String(cString: getenv("DM_PRESENT_SNAP")) == "1" && String(cString: getenv("DM_FPS_HOLD")) == "on", "the environment gets every value")
        m.reset()
        expect(d.string(forKey: "launcher.DM_PSO_MTL4") == nil && m.values["DM_PSO_MTL4"] == "1", "Reset clears performance choices and shows the defaults")
        expect(d.string(forKey: "launcher.DM_FPS_TARGET") == nil && m.values["DM_FPS_TARGET"] == file.settings.first { $0.env == "DM_FPS_TARGET" }!.def, "Reset also clears game choices")
        expect(m.values["DM_METAL_HUD"] == "1" && !m.changed, "Reset leaves the env file's value; nothing left to reset")
        let network = LauncherModel([], defaults: d, environment: [:])
        expect(network.networkMode == .offline && network.networkValidationError == nil, "network starts offline")
        network.networkMode = .lan
        expect(network.networkValidationError == nil && network.apply() && getenv("DM_NET_DISCOVERY_PEER") == nil, "LAN defaults to automatic discovery without a required IP")
        expect(["", "hostname", "1.2.3", "192.168.1.2:11452", "0.0.0.0", "224.0.0.1", "255.255.255.255"].allSatisfy { LauncherNetwork.peer($0) == nil }, "invalid, multicast and broadcast discovery addresses are rejected")
        expect(LauncherNetwork.peer("192.168.001.2") == "192.168.1.2", "Darwin's accepted padded decimal form is normalized")
        network.discoveryPeer = " 192.168.1.10 \n"
        expect(network.apply() && String(cString: getenv("DM_NETWORK")) == "lan" && String(cString: getenv("DM_NET_DISCOVERY_PEER")) == "192.168.1.10", "validated peer and mode reach the native environment")
        let reloaded = LauncherModel([], defaults: d, environment: [:])
        expect(reloaded.networkMode == .lan && reloaded.discoveryPeer == "192.168.1.10", "network choices survive launcher recreation")
        reloaded.networkMode = .ldn
        expect(reloaded.networkValidationError == nil, "LDN uses the same explicit unicast boundary")
        reloaded.discoveryPeer = ""
        expect(reloaded.apply() && getenv("DM_NET_DISCOVERY_PEER") == nil, "LDN also permits automatic discovery")
        reloaded.discoveryPeer = "invalid optional address"
        expect(reloaded.networkValidationError != nil && !reloaded.apply(), "an invalid manual override is rejected without requiring one")
        reloaded.networkMode = .nextendo; reloaded.discoveryPeer = ""
        expect(reloaded.apply() && getenv("DM_NET_DISCOVERY_PEER") == nil, "Nextendo does not require or invent a local discovery peer")
        reloaded.reset()
        expect(reloaded.networkMode == .offline && reloaded.discoveryPeer.isEmpty && !reloaded.changed, "reset clears saved network choices")
        let locked = LauncherModel([], defaults: d, environment: ["DM_ENV_FILE_KEYS":"DM_NETWORK DM_NET_DISCOVERY_PEER", "DM_NETWORK":"ldn", "DM_NET_DISCOVERY_PEER":"192.168.1.20"])
        locked.reset()
        expect(locked.networkMode == .ldn && locked.discoveryPeer == "192.168.1.20" && !locked.changed, "network env-file choices survive reset")
        d.removeObject(forKey: "launcher.discoveryStyle")
        d.set("192.168.1.99", forKey: "launcher.DM_NET_DISCOVERY_PEER")
        d.set("lan", forKey: "launcher.DM_NETWORK")
        let migrated = LauncherModel([], defaults: d, environment: [:])
        expect(migrated.networkMode == .lan && migrated.discoveryPeer.isEmpty && migrated.networkValidationError == nil, "the former mandatory address migrates to automatic discovery")
        let missingRoutes = LauncherNextendoStatus(rawValue: 1 | (1 << 8))
        expect(!missingRoutes.canStart && missingRoutes.hasValidCredential && missingRoutes.blockingMessage != nil, "a valid credential cannot silently start Nextendo without configured services")
        expect(!LauncherNextendoStatus(rawValue: 0).canStart, "configured routes cannot start Nextendo without a valid game credential")
        expect(!LauncherNextendoStatus(rawValue: 5 | (1 << 8)).canStart, "an invalid service certificate blocks Nextendo")
        expect(LauncherNextendoStatus(rawValue: 1 << 8).canStart, "native metadata distinguishes configured services and a validated credential from missing setup")
        print("launcher storage: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
