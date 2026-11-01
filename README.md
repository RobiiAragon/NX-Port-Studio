<p align="center">
  <img src="docs/images/hero.svg" alt="NX Port Studio — Your Switch library. Native Apple apps." width="100%">
</p>

<p align="center">
  <a href="#get-started">Get started</a> · <a href="#what-is-verified">Verified status</a> · <a href="ROADMAP.md">Roadmap</a> · <a href="CONTRIBUTING.md">Contribute</a> · <a href="CREDITS.md">Credits</a>
</p>

<p align="center"><strong>English</strong> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.ja.md">日本語</a> · <a href="README.zh-Hans.md">简体中文</a></p>

**NX Port Studio is a macOS workspace for turning your own Nintendo Switch game files into native Apple apps.** Choose a game, prepare its tools and resources, then build a Mac app or an iPhone/iPad port signed through Xcode.

This is an independent project built on [seedds/nxnative](https://github.com/seedds/nxnative). The upstream native-execution engine, its authors and their original MIT notice remain credited and preserved. See [Credits](CREDITS.md) and [License](LICENSE).

> **1.6.0 release candidate:** the engine is synchronized with nxnative `d2a86b05ccce` (352 upstream commits since the shared baseline). Automated host, graphics and iOS checks pass; game-by-game qualification of this new engine remains open. See [release notes](docs/releases/1.6.0-rc.2.md).

## Inside Studio

Captured from the running macOS app in English.

![New port — choose your inputs and Apple platform](docs/images/en/studio-new-port.jpg)

| Versioned system resources | Local room discovery |
| :---: | :---: |
| [![Firmware resource library](docs/images/en/studio-firmware.jpg)](docs/images/en/studio-firmware.jpg) | [![Local discovery bridge, shown inactive](docs/images/en/studio-local-play.jpg)](docs/images/en/studio-local-play.jpg) |

## One workspace, from input to app

- **Real build progress.** Choose one game's base files, updates and DLC; follow the engine's actual stages and actionable errors.
- **Flexible local imports.** ZIP/7z archives, nested folders and upper-case extensions are recognized, with bounded extraction and byte-verified reuse. Known build failures include recovery steps in all five interface languages.
- **Signed iOS exports.** Every iOS export goes through Xcode signing and profile verification. Optional installation follows a successful signed export.
- **Original system resources.** Import your own firmware data for Mii models, shared fonts and the certificate store, with version and content checks.
- **Native controls.** Per-game controller settings, motion and vibration where the host platform and connected hardware expose them.
- **Connections from the game menu.** Online uses Nextendo, local wireless uses the LDN bridge and LAN uses native IP sockets. No launcher protocol selection or restart is required; compatibility is validated for each path.

The engine runs rewritten ARM64 game code on Apple silicon and implements the required host services and graphics translation. Compatibility depends on the exact game, update, profile and device. Creating an app does not by itself establish that the game is playable.

## Beyond the build UI

This project also extends the native runtime and integration paths:

- [Horizon socket transport](dm/host/hle_net_backend.c): explicit address/errno/flag translation, real TCP/UDP and safe descriptor close/reuse.
- [Blocking HLE entry](dm/host/entry.S): guest-register publication, native host stacks and pause/resume-aware waits instead of fabricated progress.
- [Apple TLS backend](dm/host/hle_ssl_apple.m): certificate/hostname verification and context-scoped trust, with original CertStore data supplied through the [firmware importer](dm/tools/nx_extract/FirmwareResources.cs).
- [Original LDN bridge](dm/host/hle_ldn.c): real discovery, session control, roster synchronization and lifecycle over the public protocol, with owner-confirmed Mario Kart 3.0.5 LAN/LDN play across native Mac/iOS ports and a physical Switch.
- [Native account bridge](dm/host/hle_nextendo_apple.m), [social API](dm/host/hle_nextendo_social_apple.m) and [automatic service profiles](dm/tools/nextendo_services.py): real account/friend/presence data and per-title routing, with [complete catalog coverage and qualification](docs/nextendo-coverage.md). Scoped OAuth is not promoted into a game credential.
- [Signed provider game adapters](dm/tools/nextendo_patches.py): exact-build guarded IPS32 plans, compiled into separate Nextendo modules while Offline/LAN keep the original rewrite.
- [Controller mapping](dm/host/controls_map.h) and [Mac Joy-Con path](dm/host/joycon_mac.inc): Nintendo/Xbox layouts, public Apple controller APIs and a calibrated raw-device fallback on Mac. iOS remains limited to the capabilities its public APIs expose.

These mechanisms have different validation milestones. They do not establish that every game can play online.

## What is verified

| Area | Current evidence | Scope |
| --- | --- | --- |
| macOS Studio | Build, configuration, process handling, resource import and Xcode signing tests pass. | Apple silicon; the Studio interface requires macOS 14+. Individual games can require newer macOS/Metal features. |
| Mac ↔ Switch LAN | An earlier tested Mac build **completed a full Mario Kart 8 Deluxe 3.0.5 race** with a physical Switch. | Historical baseline for matching versions and the game's LAN mode. The current candidate has not repeated that race. |
| LDN bridge | The owner confirmed working Mario Kart 3.0.5 LAN and LDN play across native macOS/iOS ports and a physical Switch on October 31. Protocol and peer fixtures also pass. | Hardware result from the pre-sync ports; the new engine needs a fresh game test. IP LDN requires a compatible console module; built-in LAN is a separate path. |
| Nextendo | Account integration plus one real **Smash 13.0.5 arena round on Mac** are verified. | Automatic connection mode; an explicitly approved per-service leaf enrollment was used. Quickplay, other titles and iOS online are not established by this result. |
| iPhone/iPad | A signed Mario Kart 3.0.5 build has joined LAN lobbies with a physical Switch in both host roles, confirmed by the user. | Lobby entry is verified; a completed race remains unverified. Device, signing and platform restrictions still apply. |
| Android / Windows | Planned after the Apple baseline is stable. | No builds or compatibility claims yet; ARM and x86 need separate architecture work. |

## Get started

### Requirements

- An Apple silicon Mac with macOS 14 or later for Studio, plus [Xcode 27.2](https://developer.apple.com/xcode/) with Swift 6. The engine validates that version’s Metal compiler against its translation lock. The engine or an individual game may need newer graphics tooling.
- Your own game files and console keys. Matching updates and DLC belong in the same game's input folder.
- For iPhone/iPad exports: an eligible physical device, Xcode account/team configuration, pairing, trust and Developer Mode. Current engine targets use iOS/iPadOS 26 and supported A17 Pro/M-series hardware; consult the per-game notes.

### Build Studio from source

From a checkout containing the Studio and engine sources:

```sh
cd macOS/NXPortStudio
swift test
swift run NXPortStudio
```

Create a local app bundle:

```sh
./scripts/package_app.sh "/path/to/NX Port Studio.app"
```

The package script refuses to overwrite an existing destination. Its default local ad-hoc signature is for the **Mac Studio app**; public notarized distribution is a separate release step. **Game IPAs use Xcode development signing**, with Apple's account, device and expiration rules.

### Create a port

1. Open **Environment** and prepare the tools the engine reports as required.
2. Select one game's folder and your `prod.keys` in **New port**.
3. Optionally import original system resources in **Firmware** and choose the catalog for new ports.
4. Choose **Mac** or **iPhone / iPad**. For iOS, select a paired eligible device and enter your Xcode development Team ID.
5. Create the port. Mac builds install directly in **Applications** and remove their temporary engine, extraction and build files. Updates replace only a verified port of the same game. An iOS build is successful only after signing and IPA verification; **Install when finished** controls installation, not whether the export is signed.

The interface starts in Spanish. Choose English, French, Japanese or Simplified Chinese in the sidebar or Language menu. Interface and game languages are independent. Technical tool output retains its original language. Mac builds retain only the installed app; saves and runtime settings live in Application Support. iOS projects and extracted files remain beside the game for Xcode signing; IPA exports default to Downloads.

## Network modes have different requirements

Ports start with automatic connection services. Choose Online, Local wireless or LAN inside the game. Nextendo setup is available independently; missing online credentials do not block local play. Network disabling and a discovery peer override remain optional advanced settings.

**LAN** uses a game's own LAN mode and real IP sockets. Use matching game versions and the same network. The earlier completed Mario Kart race above is the physical interoperability baseline; it does not certify a later runtime candidate. The current 3.0.5 Mac candidate can [create a local LAN room](dm/games/0100152000022000/README.md#local-network-validation), reaching the host lobby and rules. An external peer joining and a newly completed race remain unvalidated for that candidate.

**LDN** bridges local-wireless service discovery and membership over IP. It needs a compatible peer/module and a matching game. Passing peer fixtures is not a substitute for testing a physical console.

Some games also require a local play-history identity during room setup. Import your own firmware in Studio and select it before building the port. The importer can extract that private resource from a recognized friends module; firmware 23.0.1 has been validated. [The implementation and its limits](docs/reference/services.md#local-play-history-identity-required-after-network-creation) are documented separately from online accounts.

**Nextendo** adds account authorization and signed service policies. Studio uses your own registered application's client ID, saved locally, and keeps account credentials in the Mac's Keychain. Scoped OAuth access is not automatically a NEX game credential. An explicit request can obtain an identity-checked NEX credential; that account step has been verified. A listed or enabled server, an accepted version and a saved credential each describe a requirement; none proves a working native online match. Check the signed catalog in the app for current version policy.

The port also includes **Nextendo setup on iPhone/iPad**: authorize in the system browser, keep the account in the app's Keychain, refresh the signed catalog and inspect game-version/service requirements before launch. These device-side flows have fixture coverage; physical browser authorization is still being validated. Account setup does not establish a working native online match.

On iOS, the runtime implements automatic unicast discovery on an eligible, bounded IPv4 local subnet when broadcast/multicast access is unavailable. The advanced peer address is optional. The user confirmed LAN lobby entry in both host roles with a physical Switch; a complete race remains unverified.

For rooms hosted on iPhone/iPad, Studio's **Local play → Start bridge** enables an optional [local discovery relay](dm/net/lan_relay.c) on the Mac. Keep Studio open on the same network. The bridge relays supported LAN/LDN room discovery; gameplay connects peers directly. It starts off, shows real traffic/error state and does not require an account or a manually entered IP address. **The owner confirmed LAN and LDN play across native Mac/iOS ports and physical Switch hardware on October 31.** This does not qualify every game, host pairing or the newly synchronized engine.

### Current game-service blockers

As of 2026-10-31, five production account/BAAS/data endpoints pass the native scoped-CA handshake, including the provider’s long-lived certificates. The probed MK8 NEX endpoint still presents a self-signed certificate without its required hostname, and the device/application-auth chain does not match the published provider CA. These checks remain failures. The available Mario Kart 8 Deluxe **3.0.5** build also falls outside the catalog’s **4.0.1** requirement. The [full coverage inventory](docs/nextendo-coverage.md) lists all 58 catalog entries, 62 regional service profiles and 22 exact-build patch plans, separately from unverified native online gameplay.

## What belongs in this repository

Source, original project artwork, profiles, tooling, documentation and preserved dependency licenses belong here. Games, decrypted game assets, console keys, firmware archives, account credentials and personal save data do not. Nintendo screenshots, covers, artwork, game icons and original SDK files are excluded from this public repository. Validation results are described in text.

See [Contributing](CONTRIBUTING.md) for useful bug reports and validation evidence, and [Roadmap](ROADMAP.md) for planned work. This project is not affiliated with Nintendo, Apple, Nextendo or the upstream authors; using an upstream engine or a service does not imply their endorsement.
