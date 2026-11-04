# Splatoon 3 (`0100C2500FC20000`)

I registered update **11.3.0** (`v2752512`), SDK **20.5.22**, with the native NVN renderer. In my latest Mac test of candidate `9f3f6be1`, I passed the title screen, entered the lobby and its tour, created my player card, and entered the Nextendo matchmaking queue. **This profile remains experimental:** severe graphics corruption persisted during that run, and I have not completed a match. Earlier diagnostics reached character creation, the tutorial, the train transition and the plaza, then failed a lobby connection with `2321-4992`; that older error is not the result of this new queue attempt. Nextendo match completion, LAN/LDN discovery and matches, iPhone rendering, DLC gameplay and long-session stability remain unqualified.

I record the detailed bring-up evidence and remaining tests in [Splatoon 3 bring-up](../../../docs/bringup/splatoon-3.md) and [local-network requirements](../../../docs/bringup/splatoon-3-local-network.md). Passing backend fixtures and recognizing a server profile do not establish working multiplayer in this game.

## Registered inputs

| Module | NSO build ID |
|---|---|
| `main` | `28c4287aee36f7499da60f3e68b54c70` |
| `sdk` | `574284b40c06cf1821a44857939083be` |

I identified Nintendo's sead / agl / gsys engine, Pia **6.32.3** and NPLN **1.38.1**. I use my own base, matching update and three DLC packages. An unrelated application in the same download folder is a different title and must remain outside this game's build input. No game binaries, shader programs, translated libraries, firmware, keys or save data belong in this profile.

The metadata tables describe **31,218** unique shaders: 13,020 vertex, 17,978 pixel, 100 compute and 120 geometry shaders. I retain their generated labels so that their shader-input identity stays reproducible. I do not add a `validated.tsv` or claim that every shader is exercised. The runtime's global translation-chain stamp must match freshly built libraries; generated `c1_full.tsv` and `cb_extent.tsv` remain local.

## Profile requirements

| Setting | Reason |
|---|---|
| `modules main sdk` | Both modules are imported by this build. |
| `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | I took the application layout from the executable's declared memory requirements; its heap fits the reserved region. |
| `sys_resource 0x0` | The NPDM declares no system-resource memory; I preserve the original virtual-address-memory behavior. |
| `mem_used 0x7600000` | The rewritten modules need more than the default 64 MB. |
| `render_cond on` | I evaluate the game's NVN conditional-render reports using the existing backend. This is not a substitute for diagnosing the remaining graphics corruption. |
| `romfs_marker Model/Fld_PlayerMake.bfres.zs` | I validate the selected game's resource root. |

I use no game-specific function cuts. I import supported original system resources through Studio's private firmware library; this does not execute the console's entire firmware.

## Shader preparation and startup

I previously compiled the Mac libraries with chain `a7dbbce711c3` and input digest `d22a9286232c`. A new build must use its own current stamps. An earlier eager pipeline prebuild encountered compiler allocation/XPC failures; I used the explicit diagnostic options `--gpu none` and `DM_PSO_PREBUILD=0` to test the pipelines the game actually draws. These options retain Metal rendering and shader libraries, but omit eager precomputation. I have not qualified them as a permanent performance fix or a stable release configuration.

The first startup abort came from the embedded gRPC wakeup-descriptor availability check. I implemented real [local event-counter descriptors](../../../docs/reference/services.md#grpc-cannot-create-a-local-event-counter-wakeup-descriptor). Later, I corrected [small host-lent command-memory capacity](../../../docs/reference/nvn-objects.md#host-lent-command-memory-segments); the earlier private run then passed the formerly failing train transition. Neither result proves that the remaining picture or network behavior is correct.

## Multiplayer

I verified Nextendo's signed catalog for exact version 11.3.0 and its guarded adapter for this main build. Online uses the game's embedded gRPC/HTTP2/BoringSSL NPLN client, rather than Splatoon 2's NEX transport. I compile the provider's signed adapter into a separate module variant; Offline/LAN retain the original rewrite. Credentials stay outside game bundles.

I check the versioned [calendar recipe](../../../docs/reference/nextendo-bcat.md) before each online launch and retain the last validated snapshot if refresh fails. The game still has to accept its encrypted region-specific packs and complete a real session. I do not infer that result from successful delivery alone.

Local wireless is available at the Shoal; built-in LAN uses **ZL + ZR + Left Stick** there. I keep these protocols separate: native LAN uses IP sockets, while the LDN bridge requires a compatible IP peer/module. Two ordinary windows on one Mac do not establish two independent endpoints. I have not qualified discovery, joining, both host roles or a completed local match for this profile.

## Mac acceptance on November 4, 2026

I tested the installed Mac application built from `9f3f6be1`. I advanced beyond the title, entered the lobby, completed its tour, created my player card and started the Nextendo matchmaking queue. The picture became severely corrupted during this sequence. I have not finished an online match or established the cause of the remaining graphics defect.

My bounded, metadata-only capture contained **7,384 ordinary log lines**, with no crash marker at capture time. Native account availability was one; no account-preparation or returned account-operation error was recorded. Friends creator command 0 returned success, the canonical friends API returned **HTTP 200**, and **2,893 socket operations** were recorded. No LDN event was recorded. These facts establish the observed startup/lobby progress and that API response, without qualifying matchmaking completion, a LAN/LDN session, hourly credential rotation or long-session stability. No token, account ID, payload, raw crash report or live-memory inspection was needed for this receipt.

## Found on this game

- [A game credential is reused for account APIs](../../../docs/reference/services.md#a-game-credential-is-reused-for-account-apis): I separated the host social OAuth bearer from the NEX game proof in synthetic decoder/transport tests. The installed `9f3f6be1` test recorded a real friends API HTTP 200; other permissions and completed gameplay remain unqualified.

- [Friends IPC initialization needs real objects and completion events](../../../docs/reference/services.md#friends-ipc-initialization-needs-real-objects-and-completion-events): the earlier 11.3.0 initializer reached unsupported `friend:u` after Play. My installed `9f3f6be1` candidate passed the title and reached the lobby/queue, with creator command 0 succeeding. The broader IPC surface and completed multiplayer remain open.

I link the shared service and graphics findings from the [bring-up note](../../../docs/bringup/splatoon-3.md). Those entries distinguish reproduced backend defects from hypotheses about this game's remaining corruption. I will update this note only after testing the exact new engine and shader stamps in the game.

During the static rendering audit I reproduced [pending attachment clears overtaking a later texture clear](../../../docs/reference/rendering.md#pending-attachment-clears-precede-an-explicit-texture-clear) with an authored GPU fixture. I have not observed that sequence in this game's failing transition. A candidate containing the correction still shows black/red artifacts after the rejected lobby return, so I have not established that clear ordering causes that visual defect.

I also corrected the [shader-progress observer](../../../docs/reference/packing.md#shader-progress-freezes-or-counts-unfinished-work-as-complete) after its displayed count lagged behind this game's base artifacts. The new synthetic schedules qualify progress reporting, not shader correctness, rendering or network play.

I added [failed account-operation metadata](../../../docs/reference/services.md#a-generic-account-result-does-not-identify-the-failing-operation) after a lobby attempt reported the shared `0x2a2` Result before a recorded socket call. I verified the diagnostic with synthetic providers; I have not attributed that game failure to an account, token or service without a new coordinated trace.

While investigating unavailable credentials, I reproduced and corrected [game sign-in replacing a native proof with scoped OAuth](../../../docs/reference/services.md#game-sign-in-overwrites-a-working-native-credential-with-scoped-oauth). The synthetic coordinator and native decoder tests establish that storage defect and its preservation checks. They do not identify the contents of my actual Keychain item or qualify this game's online access; the provider must still authorize the complete exchange.

I also added [read-versus-decoder rejection metadata](../../../docs/reference/services.md#account-credential-acquisition-fails-without-identifying-read-or-decode-rejection), tested with fake Security and synthetic providers. My diagnostic run identified an expired stored credential before any recorded guest socket; I have not qualified an online session.

I reproduced [the local nickname hook ignoring a validated identity snapshot](../../../docs/reference/services.md#local-nickname-ignores-an-already-validated-account-snapshot) with synthetic profiles and real HLE hooks. I have not tested the change in this game or claimed that its current in-game name has changed.

I corrected [retention and renewal of the provider's OAuth grant](../../../docs/reference/services.md#a-linked-nextendo-account-expires-and-forces-browser-sign-in-again) in the shared account service, with synthetic production-coordinator and two-process checks. The actual service must still accept the application's consent/refresh, and updated ports must be rebuilt; I do not treat this as a completed Splatoon 3 online session or a graphics fix.

I ran the [Mac account transaction before SDK startup](../../../docs/reference/services.md#packed-mac-launch-does-not-prepare-a-renewable-game-account-before-sdk-startup) in the installed `9f3f6be1` candidate. I observed the [lobby and queue milestone above](#mac-acceptance-on-november-4-2026), with no preparation error in the captured ordinary prefix. I have not qualified a completed online match or observed a real hourly refresh/rotation.

During the static rendering audit I reproduced [pending attachment clears overtaking a later texture clear](../../../docs/reference/rendering.md#pending-attachment-clears-precede-an-explicit-texture-clear) with an authored GPU fixture. I have not observed that sequence in this game's failing transition. A candidate containing the correction still shows black/red artifacts after the rejected lobby return, so I have not established that clear ordering causes that visual defect.
