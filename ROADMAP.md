# Roadmap

Priorities follow reproducible results. This roadmap describes intended work, not promised release dates or universal compatibility.

## 1. Stabilize the Apple baseline

- Make Studio setup, resource import, cancellation and signed IPA export reliable on a clean Mac.
- Validate each game/update profile independently and retain exact build/version notes.
- Finish current iPhone integration and verify launch, rendering, controls, saving and installation on physical devices.
- Improve actionable diagnostics and recovery while preserving existing user data and exports.
- Retain the five implemented interface languages and matching documentation captures; verify new screens in every language.
- Review packaging, dependency notices, signing and notarization before a public binary release.

**Exit evidence:** repeatable build/install flows and documented gameplay for the exact supported configurations.

## 2. Expand verified local multiplayer

- Retain Mario Kart 8 Deluxe 3.0.5 Mac ↔ Switch LAN as the current completed-race baseline.
- Validate physical LDN join/create with a compatible Switch after the local play-history correction; the corrected Mac build reaches its host lobby, while a completed physical session remains pending.
- Extend the user-confirmed iPhone ↔ Switch LAN lobby entry in both host roles to completed races. Isolate discovery/receive behavior and profile restrictions, including use of the optional Studio relay.
- Exercise disconnect/reconnect, multiple participants, room changes and longer sessions.
- Expand controller motion/vibration coverage according to actual platform/device capabilities.

**Exit evidence:** physical peer tests and completed sessions, separate from protocol/unit test results.

## 3. Validate Nextendo game traffic

Own-application OAuth → identity-checked NEX credential acquisition and Keychain roundtrip have been verified. The following game-traffic milestones remain separate.

- Keep own-application OAuth and signed-catalog support distinct from game authentication.
- Complete and test the native identity, DNS, TLS and game-service paths required by specific titles.
- Resolve the current native TLS certificate validity/hostname blockers with valid service certificates, retaining verification.
- Obtain and validate an eligible Mario Kart game build: the available LAN-tested 3.0.5 build does not meet the current signed 4.0.1 service requirement.
- Establish an actual authorized NEX game session and complete an online match on a supported game/version.
- Add per-title network status with evidence, failures and reproducible versions.
- Physically validate the implemented mobile account flow: system-browser authorization, identity-checked NEX acquisition, per-app Keychain storage and migration from the earlier private credential cache.

**Exit evidence:** a documented native online match. Server policy acceptance and an OAuth token alone do not meet this milestone.

## 4. Research additional platforms

After the Apple baseline is stable, explore **Android and Windows across ARM and x86 architecture families**. No builds for these targets are currently offered.

| Target | Work to establish feasibility |
| --- | --- |
| Android / ARM | Host services, mobile lifecycle/input, packaging and a suitable graphics backend. |
| Windows / ARM | Host ABI and synchronization, device/input integration, packaging and a suitable graphics backend. |
| Android or Windows / x86 | CPU translation or recompilation in addition to the platform/graphics work. ARM game code cannot execute directly on an x86 CPU. |

Exact CPU generations, 32/64-bit targets and device requirements will be decided from working prototypes. These are research directions, not compatibility promises.

## How progress is recorded

An implemented feature, a passing isolated test, physical interoperability and completed gameplay are separate milestones. Issues and release notes should say which one was reached and link to the corresponding evidence.
