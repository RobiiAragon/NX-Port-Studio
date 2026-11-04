# Splatoon 3 (`0100C2500FC20000`)

I registered update **11.3.0** (`v2752512`), SDK **20.5.22**, with the native NVN renderer. I reached character creation, the tutorial, the train transition and the plaza in earlier private Mac diagnostics. **This profile remains experimental:** I observed serious color/texture corruption after returning from the online lobby, and the connection failed with `2321-4992`. I have not qualified a completed Nextendo, LAN or LDN match, iPhone rendering, DLC gameplay or a long session.

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

## Found on this game

I link the shared service and graphics findings from the [bring-up note](../../../docs/bringup/splatoon-3.md). Those entries distinguish reproduced backend defects from hypotheses about this game's remaining corruption. I will update this note only after testing the exact new engine and shader stamps in the game.

I also corrected the [shader-progress observer](../../../docs/reference/packing.md#shader-progress-freezes-or-counts-unfinished-work-as-complete) after its displayed count lagged behind this game's base artifacts. The new synthetic schedules qualify progress reporting, not shader correctness, rendering or network play.

I added [failed account-operation metadata](../../../docs/reference/services.md#a-generic-account-result-does-not-identify-the-failing-operation) after a lobby attempt reported the shared `0x2a2` Result before a recorded socket call. I verified the diagnostic with synthetic providers; I have not attributed that game failure to an account, token or service without a new coordinated trace.

While investigating unavailable credentials, I reproduced and corrected [game sign-in replacing a native proof with scoped OAuth](../../../docs/reference/services.md#game-sign-in-overwrites-a-working-native-credential-with-scoped-oauth). The synthetic coordinator and native decoder tests establish that storage defect and its preservation checks. They do not identify the contents of my actual Keychain item or qualify this game's online access; the provider must still authorize the complete exchange.

I reproduced [the local nickname hook ignoring a validated identity snapshot](../../../docs/reference/services.md#local-nickname-ignores-an-already-validated-account-snapshot) with synthetic profiles and real HLE hooks. I have not tested the change in this game or claimed that its current in-game name has changed.
