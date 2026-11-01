// The launcher's storage (LauncherSettings.swift LauncherModel), run by test_launcher_storage.py on macOS: only choices that differ from the game's default are
// stored, Reset to tested defaults followed by Play forgets the choices, an env file's values are kept. Arguments: the iOS and the Mac launcher.json of Breath of the Wild (settings.py, GFXAPI=nvn)
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
        expect(m.uiLanguage == .spanish, "app interface defaults to Spanish")
        let preservedGameLanguage = m.values["DM_LANG"]
        m.uiLanguage = .japanese
        expect(d.string(forKey: "launcher.uiLanguage") == "ja" && m.values["DM_LANG"] == preservedGameLanguage, "app UI language is separate from the game language")
        expect(LauncherModel(file.settings, defaults: d).uiLanguage == .japanese, "app UI language survives recreation")
        let scale = file.settings.first { $0.env == "DM_RENDER_SCALE" }!
        expect(["nan", "inf", "-inf", "0.49", "1.01", "invalid", "0x1p-1", "0X1", " 0.75"].allSatisfy { !scale.accepts($0) } && scale.accepts("0.5") && scale.accepts("1.00"), "saved ranges reject nonfinite, out-of-range, hex and padded values, as launcher.c does")
        d.set("nan", forKey: "launcher.DM_RENDER_SCALE")
        expect(LauncherModel(file.settings, defaults: d).values["DM_RENDER_SCALE"] == scale.def, "an invalid saved range loads the default")
        expect(m.values["DM_FPS_TARGET"] == "30" && m.values["DM_PSO_MTL4"] == "0" && m.values["DM_FPS_HOLD"] == "on" && m.values["DM_METAL_HUD"] == "1", "stored choices and the env file are read")
        expect(m.changed, "Reset is offered with changed settings")
        let wide = file.settings.first { $0.env == "DM_DISPLAY_WIDE" }!
        let highFPS = file.settings.first { $0.env == "DM_FPS_120" }!
        expect(wide.unavailable != nil && highFPS.unavailable != nil && !wide.accepts("1") && !highFPS.accepts("1"), "camera and timing mods require platform qualification")
        d.set("1", forKey: "launcher.DM_DISPLAY_WIDE")
        let unsupported = LauncherModel([wide, highFPS], defaults: d, environment: ["DM_ENV_FILE_KEYS":"DM_DISPLAY_WIDE DM_FPS_120", "DM_DISPLAY_WIDE":"1", "DM_FPS_120":"1"], maximumFramesPerSecond: 120)
        expect(unsupported.values["DM_DISPLAY_WIDE"] == "0" && unsupported.values["DM_FPS_120"] == "0", "saved values, env files and a 120 Hz screen cannot grant unsupported mods")
        unsupported.values["DM_FPS_120"] = "1"
        expect(unsupported.apply() && String(cString: getenv("DM_FPS_120")) == "0" && d.string(forKey: "launcher.DM_DISPLAY_WIDE") == nil, "apply rejects a programmatic unsupported mod and removes stale saved choices")
        m.values["DM_RENDER_SCALE"] = "1.00"   // the slider's format of the default
        m.apply()
        expect(d.string(forKey: "launcher.DM_PRESENT_SNAP") == nil, "a value equal to the default is not stored (and an old one is dropped)")
        expect(d.string(forKey: "launcher.DM_RENDER_SCALE") == nil && d.string(forKey: "launcher.DM_OPMODE") == nil && d.string(forKey: "launcher.DM_FPS_HOLD") == nil, "defaults are not stored")
        expect(d.string(forKey: "launcher.DM_FPS_TARGET") == "30" && d.string(forKey: "launcher.DM_PSO_MTL4") == "0", "changed choices are stored")
        expect(d.string(forKey: "launcher.DM_METAL_HUD") == nil && String(cString: getenv("DM_METAL_HUD")) == "1", "the env file's value is kept and not stored")
        expect(String(cString: getenv("DM_PSO_MTL4")) == "0" && String(cString: getenv("DM_PRESENT_SNAP")) == "1" && String(cString: getenv("DM_FPS_HOLD")) == "on", "the environment gets every value")
        m.reset()
        expect(m.values["DM_PSO_MTL4"] == "1" && m.values["DM_FPS_TARGET"] == file.settings.first { $0.env == "DM_FPS_TARGET" }!.def, "Reset shows the defaults")
        expect(d.string(forKey: "launcher.DM_PSO_MTL4") == "0" && d.string(forKey: "launcher.DM_FPS_TARGET") == "30", "Reset alone forgets nothing: Quit after it keeps the choices")
        expect(m.values["DM_METAL_HUD"] == "1" && !m.changed, "Reset leaves the env file's value; nothing left to reset")
        let network = LauncherModel([], defaults: d, environment: [:])
        expect(network.networkMode == .automatic && network.networkValidationError == nil && !network.changed, "network starts with simultaneous automatic services")
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
        expect(reloaded.networkMode == .automatic && reloaded.discoveryPeer.isEmpty && !reloaded.changed, "reset clears saved network choices")
        let locked = LauncherModel([], defaults: d, environment: ["DM_ENV_FILE_KEYS":"DM_NETWORK DM_NET_DISCOVERY_PEER", "DM_NETWORK":"ldn", "DM_NET_DISCOVERY_PEER":"192.168.1.20"])
        locked.reset()
        expect(locked.networkMode == .ldn && locked.discoveryPeer == "192.168.1.20" && !locked.changed, "network env-file choices survive reset")
        d.removeObject(forKey: "launcher.discoveryStyle")
        d.set("192.168.1.99", forKey: "launcher.DM_NET_DISCOVERY_PEER")
        d.set("lan", forKey: "launcher.DM_NETWORK")
        d.removeObject(forKey: "launcher.networkSelectionVersion")
        let migrated = LauncherModel([], defaults: d, environment: [:])
        expect(migrated.networkMode == .automatic && migrated.discoveryPeer.isEmpty && migrated.networkValidationError == nil, "the former mandatory address migrates to automatic discovery")
        for oldMode in ["lan", "ldn", "nextendo"] {
            d.removeObject(forKey: "launcher.networkSelectionVersion")
            d.set(oldMode, forKey: "launcher.DM_NETWORK")
            let automatic = LauncherModel([], defaults: d, environment: [:])
            expect(automatic.networkMode == .automatic && automatic.networkMode.supportsNextendo && automatic.networkMode.usesLocalDiscovery && automatic.apply(), "legacy protocol choices migrate to simultaneous services")
            expect(String(cString: getenv("DM_NETWORK")) == "auto", "automatic capabilities reach the native host")
        }
        let offline = LauncherModel([], defaults: d, environment: [:])
        offline.networkMode = .offline
        expect(offline.apply() && LauncherModel([], defaults: d, environment: [:]).networkMode == .offline, "explicit network disable survives reopening")
        let invalidOverride = LauncherModel([], defaults: d, environment: ["DM_ENV_FILE_KEYS":"DM_NETWORK", "DM_NETWORK":"invalid"])
        expect(invalidOverride.networkMode == .offline, "invalid explicit override fails closed")
        let missingRoutes = LauncherNextendoStatus(rawValue: 1 | (1 << 8))
        expect(!missingRoutes.canStart && missingRoutes.hasValidCredential && missingRoutes.blockingMessage != nil, "a valid credential cannot silently start Nextendo without configured services")
        expect(!LauncherNextendoStatus(rawValue: 0).canStart, "configured routes cannot start Nextendo without a valid game credential")
        expect(!LauncherNextendoStatus(rawValue: 5 | (1 << 8)).canStart, "an invalid service certificate blocks Nextendo")
        expect(LauncherNextendoStatus(rawValue: 1 << 8).canStart, "native metadata distinguishes configured services and a validated credential from missing setup")
        m.apply()
        expect(d.string(forKey: "launcher.DM_PSO_MTL4") == nil && d.string(forKey: "launcher.DM_FPS_TARGET") == nil, "Play after Reset forgets the choices")
        d.set(30, forKey: "launcher.DM_FPS_TARGET"); d.set(false, forKey: "launcher.DM_RUMBLE")   // a number and a boolean, as defaults write -int / -bool stores them
        let typed = LauncherModel(file.settings, defaults: d)
        expect(typed.values["DM_FPS_TARGET"] == file.settings.first { $0.env == "DM_FPS_TARGET" }!.def && typed.values["DM_RUMBLE"] == "1", "a saved value that is not a string is ignored, as launcher.c ignores it")
        d.removeObject(forKey: "launcher.DM_FPS_TARGET"); d.removeObject(forKey: "launcher.DM_RUMBLE")
        // Sub-settings: a row with "needs" is drawn only while the setting it names has that value
        m.values["DM_RUMBLE"] = "1"
        expect(m.rows(in: "Controls").contains { $0.env == "DM_RUMBLE_GAIN" }, "a sub-setting is drawn while its setting is on")
        m.values["DM_RUMBLE"] = "0"
        expect(!m.rows(in: "Controls").contains { $0.env == "DM_RUMBLE_GAIN" }, "a sub-setting is hidden while its setting is off")
        expect(m.rows(in: "Controls").contains { $0.env == "DM_RUMBLE" }, "the setting it depends on stays drawn")
        m.values["DM_RUMBLE"] = "1"
        // DM_LAUNCHER=0 skips the screen, not the saved choices; DM_SAVED_CHOICES=0 ignores them and leaves them stored
        let fps = file.settings.first { $0.env == "DM_FPS_TARGET" }!
        d.set("30", forKey: "launcher.DM_FPS_TARGET"); unsetenv("DM_FPS_TARGET")
        LauncherModel(file.settings, defaults: d).applySaved()
        expect(String(cString: getenv("DM_FPS_TARGET")) == "30" && d.string(forKey: "launcher.DM_FPS_TARGET") == "30", "without the screen, a saved choice goes into the environment and stays saved")
        setenv("DM_SAVED_CHOICES", "0", 1); unsetenv("DM_FPS_TARGET")
        let plain = LauncherModel(file.settings, defaults: d)
        expect(plain.values["DM_FPS_TARGET"] == fps.def, "DM_SAVED_CHOICES=0 starts from the defaults")
        plain.applySaved()
        expect(getenv("DM_FPS_TARGET") == nil, "DM_SAVED_CHOICES=0: nothing saved goes into the environment")
        plain.apply()
        expect(String(cString: getenv("DM_FPS_TARGET")) == fps.def && d.string(forKey: "launcher.DM_FPS_TARGET") == "30", "DM_SAVED_CHOICES=0: Play uses the screen's values and leaves the saved choices")
        plain.reset()
        expect(d.string(forKey: "launcher.DM_FPS_TARGET") == "30", "DM_SAVED_CHOICES=0: Reset leaves the saved choices too")
        unsetenv("DM_SAVED_CHOICES")
        // The Mac window's list (second argument): Basic first, then Advanced in the list's sections; Display mode; the render scale in pixels; values set at launch are fixed
        let mac = try! JSONDecoder().decode(SettingsFile.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        setenv("DM_ENV_FILE_KEYS", "", 1); unsetenv("DM_FULLSCREEN"); unsetenv("DM_OPMODE")
        let mm = LauncherModel(mac.settings, defaults: d)
        expect(mm.sections(basic: true) == ["Game", "Controls"] && mm.sections(basic: false) == ["Game", "Display", "Controls", "Performance"], "Basic and Advanced keep the list's sections")
        expect(mm.rows(in: "Game", basic: true).map(\.env) == ["DM_FPS_TARGET", "DM_RENDER_SCALE", "DM_OPMODE", "DM_LANG", "DM_FULLSCREEN"], "Basic rows in the list's order")
        expect(!file.settings.contains { $0.env == "DM_FULLSCREEN" } && mm.values["DM_FULLSCREEN"] == "0", "Display mode is the Mac's, Window by default")
        mm.values["DM_FULLSCREEN"] = "1"; mm.apply()
        expect(String(cString: getenv("DM_FULLSCREEN")) == "1" && d.string(forKey: "launcher.DM_FULLSCREEN") == "1", "Fullscreen goes into the environment and is saved")
        mm.values["DM_FULLSCREEN"] = "0"; mm.apply()
        expect(String(cString: getenv("DM_FULLSCREEN")) == "0" && d.string(forKey: "launcher.DM_FULLSCREEN") == nil, "Window is the default: set to 0, not saved")
        let macScale = mac.settings.first { $0.env == "DM_RENDER_SCALE" }!
        mm.values["DM_OPMODE"] = "1"
        expect(mm.rangeLabel(macScale, 1) == "1600 × 900 (100 %)" && mm.rangeLabel(macScale, 0.5) == "800 × 450 (50 %)", "docked size in pixels at 1.0 and 0.5")
        mm.values["DM_OPMODE"] = "0"
        expect(mm.rangeLabel(macScale, 0.75) == "960 × 540 (75 %)", "handheld size in pixels")
        let plainScale = try! JSONDecoder().decode(Setting.self, from: Data(#"{"env":"DM_X","kind":"range","label":"X","note":"","default":"1.0","min":0.5,"max":1.0,"step":0.05,"level":"expert"}"#.utf8))
        expect(mm.rangeLabel(plainScale, 0.5) == "50 %" && !plainScale.basic, "no base size: the percentage; an unknown level decodes as Advanced")
        d.set("1", forKey: "launcher.DM_OPMODE"); setenv("DM_ENV_LAUNCH_KEYS", "DM_OPMODE", 1); setenv("DM_OPMODE", "0", 1)   // a front end's launch override over a saved choice
        let launched = LauncherModel(mac.settings, defaults: d)
        expect(launched.values["DM_OPMODE"] == "0" && launched.fixed.contains("DM_OPMODE") && launched.fromLaunch.contains("DM_OPMODE"), "a variable set at launch is shown fixed, over the saved choice")
        launched.apply()
        expect(String(cString: getenv("DM_OPMODE")) == "0" && d.string(forKey: "launcher.DM_OPMODE") == "1", "Play keeps the launch value and leaves the saved choice")
        launched.reset(); launched.apply()
        expect(launched.values["DM_OPMODE"] == "0" && d.string(forKey: "launcher.DM_OPMODE") == "1", "Reset then Play keeps the saved choice of a setting fixed at launch")
        unsetenv("DM_OPMODE"); setenv("DM_ENV_LAUNCH_KEYS", "", 1); d.removeObject(forKey: "launcher.DM_OPMODE")
        failed += checkLauncherLayout(LauncherModel(mac.settings, defaults: d), defaults: d)
        print("launcher storage: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
