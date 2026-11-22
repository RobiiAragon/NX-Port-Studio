# Splatoon 3 (`0100C2500FC20000`)

I registered updates **11.3.0** (`v2752512`, SDK **20.5.22**) and **12.0.0** (`v2818048`, SDK **20.5.32**) with the native NVN renderer; the shader tables are 12.0.0's. On November 21, 2026, I tested 12.0.0 on the Mac, built from source with shader chain `e00d4dfc770d`, with Nextendo online. The plaza, the lobby and its practice area rendered as they do on my Switch, after I corrected [stale floating-point storage at first use](../../../docs/reference/nvn-objects.md#stale-floating-point-storage-at-first-use). The game connected to the provider, and I completed an online Salmon Run shift with other players. **This profile remains experimental:** Turf War and Anarchy matches, LAN/LDN discovery and matches, iPhone rendering, DLC gameplay and long-session stability remain unqualified.

I record the detailed bring-up evidence and remaining tests in [Splatoon 3 bring-up](../../../docs/bringup/splatoon-3.md) and [local-network requirements](../../../docs/bringup/splatoon-3-local-network.md). Passing backend fixtures and recognizing a server profile do not establish working multiplayer in this game.

## Registered inputs

| Module | NSO build ID |
|---|---|
| `main` 11.3.0 | `28c4287aee36f7499da60f3e68b54c70` |
| `sdk` 11.3.0 | `574284b40c06cf1821a44857939083be` |
| `main` 12.0.0 | `6cbb16698653e1af3c3a7602164819bb` |
| `sdk` 12.0.0 | `6a0a2600867712cd6f6c4dec53ae0d9c` |

I identified Nintendo's sead / agl / gsys engine, Pia **6.32.3** and NPLN **1.38.1**. I use my own base, matching update and three DLC packages. An unrelated application in the same download folder is a different title and must remain outside this game's build input. No game binaries, shader programs, translated libraries, firmware, keys or save data belong in this profile.

The metadata tables, made from 12.0.0's files, describe **31,224** unique shaders: 13,020 vertex, 17,984 pixel, 100 compute and 120 geometry shaders (11.3.0 had six pixel shaders fewer). When the folder holds 12.0.0, an 11.3.0 package takes these tables; with 11.3.0 alone, the NSP script derives them from 11.3.0's files. I retain their generated labels so that their shader-input identity stays reproducible. I do not add a `validated.tsv` or claim that every shader is exercised. The runtime's global translation-chain stamp must match freshly built libraries; generated `c1_full.tsv` and `cb_extent.tsv` remain local.

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

My November 21 build compiled the Mac libraries with chain `e00d4dfc770d`; earlier builds used `a7dbbce711c3` and `8410a1435ffe`. A new build must use its own current stamps. An earlier eager pipeline prebuild encountered compiler allocation/XPC failures; I used the explicit diagnostic options `--gpu none` and `DM_PSO_PREBUILD=0` to test the pipelines the game actually draws. These options retain Metal rendering and shader libraries, but omit eager precomputation. I have not qualified them as a permanent performance fix or a stable release configuration.

The first startup abort came from the embedded gRPC wakeup-descriptor availability check. I implemented real [local event-counter descriptors](../../../docs/reference/services.md#grpc-cannot-create-a-local-event-counter-wakeup-descriptor). Later, I corrected [small host-lent command-memory capacity](../../../docs/reference/nvn-objects.md#host-lent-command-memory-segments); the earlier private run then passed the formerly failing train transition. Neither result proves that the remaining picture or network behavior is correct.

## Multiplayer

I verified Nextendo's signed catalog for exact versions 11.3.0 and 12.0.0 and their guarded adapters for these main builds. The provider recommends 12.0.0, and its players are there: my 11.3.0 queue never found a match either. Online uses the game's embedded gRPC/HTTP2/BoringSSL NPLN client, rather than Splatoon 2's NEX transport. I compile the provider's signed adapter into a separate module variant; Offline/LAN retain the original rewrite. Credentials stay outside game bundles.

I check the versioned [calendar recipe](../../../docs/reference/nextendo-bcat.md) before each online launch and retain the last validated snapshot if refresh fails. The game still has to accept its encrypted region-specific packs and complete a real session. I do not infer that result from successful delivery alone.

Local wireless is available at the Shoal; built-in LAN uses **ZL + ZR + Left Stick** there. I keep these protocols separate: native LAN uses IP sockets, while the LDN bridge requires a compatible IP peer/module. Two ordinary windows on one Mac do not establish two independent endpoints. I have not qualified discovery, joining, both host roles or a completed local match for this profile.

## Mac acceptance on November 21, 2026

### Rare NaN texels after a return from the lobby

In a 12.0.0 build from upstream nxnative's code with the same stale-storage fix, the plaza showed black and red blocks on its buildings after a failed attempt to enter the lobby. A dump of the 128×128×78 environment-probe array found 14 NaN texels (0.001 %): its storage had been under the 1 % threshold, so the texture kept it. Those elements now start from 0 and the rest of the storage stays the content ([stale floating-point storage at first use](../../../docs/reference/nvn-objects.md#stale-floating-point-storage-at-first-use)). In a run with the final code, the failed lobby attempt and the return gave six textures such elements, from 79 to 22,215 (0.32 %, in a 256×256×78 probe array), and one probe array started from zeros. All of them were in `CPU_NO_ACCESS` pools, and the plaza then rendered cleanly.


### 12.0.0 with shader chain e00d4dfc770d

I built 12.0.0 from this source with the online variant and tested it on an M5 Max. Before the graphics fix, the plaza showed black dots and colored halos, and the lobby and Salmon Run practice area came out blown out in black and white. My frame captures found NaN in the HDR scene target, about 690,000 pixels in the lobby. I traced it to the environment-probe array's initial content ([stale floating-point storage at first use](../../../docs/reference/nvn-objects.md#stale-floating-point-storage-at-first-use)): 35 % of its texels were NaN that the Switch's blender discards and Apple's does not. With the fix, five textures start from zeros, the replay's probe array has no NaN, and the plaza, the lobby and its practice area render as they do on my Switch. The [zero-weight blend guard](../../../docs/reference/shaders.md#a-nan-colour-with-a-zero-blend-weight) ported from upstream runs on 17,950 of the pixel shaders; on its own it did not change this defect.

Online, the 12.0.0 adapter first failed with `2321-4992` before opening a socket. I corrected [the provider's public host name](../../../docs/reference/services.md#a-signed-adapter-names-a-provider-host-by-its-own-public-name), [the adapter's code in the text page padding](../../../docs/reference/services.md#a-signed-adapter-adds-code-in-the-text-segments-page-padding) and [the rewriter corrupting the adapter's embedded root certificate](../../../docs/reference/rewriter.md#embedded-text-in-the-text-segment). Then the game connected to the provider for the whole session without an error, entered the lobby and the matchmaking queue ("Searching for players…"), and passed the NAT check (both UDP sockets exchanged packets). In my first waits in the queue, it never received a match assignment and opened no session or Pia socket. The provider's published server source (`matchmaking_seuil_attente.go`) forms a match only from players searching the same mode at the same time: the full count (8 for Turf War, 4 for Salmon Run) for the first 45 seconds, three quarters after 45 seconds and half after 90 seconds, never fewer. Its own measurement of a quiet evening found at most 5 distinct players in the Turf War queue. Too few simultaneous players is therefore the likely cause. I could not confirm it, because the live queue counts are not public. The quickest test is Salmon Run with a second player, which forms a match at two after 90 seconds.

Later that morning, with this build, I completed an online Salmon Run shift with other players: the game was matched, played the shift and returned to Grizzco's results. My screenshot of the results, at 05:31 local time on my M5 Max with macOS 27.2, shows the Metal HUD at 60 FPS, 6.38 ms GPU time and a 16.67 ms frame interval; that is a single reading, not a benchmark. This qualifies Nextendo matchmaking and the Pia peer connection for one Salmon Run shift with this build. It ran before RC10's [held UDP socket](../../../docs/reference/services.md#a-udp-sockets-router-mapping-across-pias-close-and-rebind), so that change was not needed for it, and I have not completed a match with RC10 yet. Turf War and Anarchy matches remain unqualified.

## Mac acceptance on November 4, 2026

### Source 8836235c with shader chain 8410a1435ffe

I tested the rebuilt Mac application with relaxed shader math. The lobby scene improved substantially and rendered normally across most of the picture. My private capture showed 60 FPS, 4.28 ms GPU time and a 16.67 ms frame interval on an M5 Max. This is a single captured reading, not a benchmark or a long-session stability result. Localized black stippling and white/red highlights remained in some floor reflections; I have not attributed that residual defect to an image binding, sampler LOD or shader operation.

The bounded metadata sample from the tone-map consumer contained six accepted facts with no rejected metadata line or crash marker. It identified real full-resolution and five-mip lower-resolution inputs, whose serials differed from the output attachment. This does not establish feedback in an earlier producer or show its sampler clamps.

I also entered the Territorial matchmaking queue. After the game announced the start of combat, it remained on a black loading screen with saving/loading indicators; I did not reach a match or its results. During a 238-second metadata-only observation, some sockets continued exchanging bytes while two others repeatedly returned `EAGAIN` without successful sends or receives. That does not identify their protocol, establish a deadlock or prove a server fault. The ordinary log later stopped growing and the process was absent at the next process-list check, without a recorded crash marker; I have not established why it exited. LAN/LDN and iPhone acceptance remain pending.

### Earlier source 9f3f6be1

I tested the installed Mac application built from `9f3f6be1`. I advanced beyond the title, entered the lobby, completed its tour, created my player card and started the Nextendo matchmaking queue. The picture became severely corrupted during this sequence. I have not finished an online match or established the cause of the remaining graphics defect.

My bounded, metadata-only capture contained **7,384 ordinary log lines**, with no crash marker at capture time. Native account availability was one; no account-preparation or returned account-operation error was recorded. Friends creator command 0 returned success, the canonical friends API returned **HTTP 200**, and **2,893 socket operations** were recorded. No LDN event was recorded. These facts establish the observed startup/lobby progress and that API response, without qualifying matchmaking completion, a LAN/LDN session, hourly credential rotation or long-session stability. No token, account ID, payload, raw crash report or live-memory inspection was needed for this receipt.

## Found on this game

- [Stale floating-point storage at first use](../../../docs/reference/nvn-objects.md#stale-floating-point-storage-at-first-use): the lobby's environment-probe array started as stale NaN storage; with the fix, 12.0.0's plaza, lobby and practice area render correctly ([acceptance](#mac-acceptance-on-november-21-2026)).

- [A NaN colour with a zero blend weight](../../../docs/reference/shaders.md#a-nan-colour-with-a-zero-blend-weight): ported from upstream and active on this game's draws; it did not cause or fix the lobby's NaN.

- [Embedded text in the text segment](../../../docs/reference/rewriter.md#embedded-text-in-the-text-segment), [a signed adapter's code in the page padding](../../../docs/reference/services.md#a-signed-adapter-adds-code-in-the-text-segments-page-padding) and [the provider's public host name](../../../docs/reference/services.md#a-signed-adapter-names-a-provider-host-by-its-own-public-name): 12.0.0's online variant needed all three to connect.

- [A revised signed patch rejects the whole catalog](../../../docs/reference/services.md#a-revised-signed-patch-rejects-the-whole-catalog): on November 21, 2026 the provider published revision 2 of this build's adapter, with an additional guarded record, and my export stopped at the adapter step until I accepted positive patch revisions. I have not yet tested whether the revised patch changes the [match-start failure](#mac-acceptance-on-november-4-2026).

- [Mac fast math removes exceptional values before precise operations](../../../docs/reference/shaders.md#mac-fast-math-removes-exceptional-values-before-precise-operations): I reproduced a general offline compiler defect with authored GPU controls, then corrected the shared Mac shader policy. The derived-arithmetic control changes from 330/800 failures to zero with relaxed mode. My rebuilt `8836235c` port improved substantially in the lobby, but its residual reflection artifacts still need a separate cause and correction.

- [A game credential is reused for account APIs](../../../docs/reference/services.md#a-game-credential-is-reused-for-account-apis): I separated the host social OAuth bearer from the NEX game proof in synthetic decoder/transport tests. The installed `9f3f6be1` test recorded a real friends API HTTP 200; other permissions and completed gameplay remain unqualified.

- [Friends IPC initialization needs real objects and completion events](../../../docs/reference/services.md#friends-ipc-initialization-needs-real-objects-and-completion-events): the earlier 11.3.0 initializer reached unsupported `friend:u` after Play. My installed `9f3f6be1` candidate passed the title and reached the lobby/queue, with creator command 0 succeeding. The broader IPC surface and completed multiplayer remain open.

I link the shared service and graphics findings from the [bring-up note](../../../docs/bringup/splatoon-3.md). Those entries distinguish reproduced backend defects from hypotheses about this game's remaining corruption. I update this note only after testing the exact new engine and shader stamps in the game.

During the static rendering audit I reproduced [pending attachment clears overtaking a later texture clear](../../../docs/reference/rendering.md#pending-attachment-clears-precede-an-explicit-texture-clear) with an authored GPU fixture. I have not observed that sequence in this game's failing transition. A candidate containing the correction still shows black/red artifacts after the rejected lobby return, so I have not established that clear ordering causes that visual defect.

I also corrected the [shader-progress observer](../../../docs/reference/packing.md#shader-progress-freezes-or-counts-unfinished-work-as-complete) after its displayed count lagged behind this game's base artifacts. The new synthetic schedules qualify progress reporting, not shader correctness, rendering or network play.

I added [failed account-operation metadata](../../../docs/reference/services.md#a-generic-account-result-does-not-identify-the-failing-operation) after a lobby attempt reported the shared `0x2a2` Result before a recorded socket call. I verified the diagnostic with synthetic providers; I have not attributed that game failure to an account, token or service without a new coordinated trace.

While investigating unavailable credentials, I reproduced and corrected [game sign-in replacing a native proof with scoped OAuth](../../../docs/reference/services.md#game-sign-in-overwrites-a-working-native-credential-with-scoped-oauth). The synthetic coordinator and native decoder tests establish that storage defect and its preservation checks. They do not identify the contents of my actual Keychain item or qualify this game's online access; the provider must still authorize the complete exchange.

I also added [read-versus-decoder rejection metadata](../../../docs/reference/services.md#account-credential-acquisition-fails-without-identifying-read-or-decode-rejection), tested with fake Security and synthetic providers. My diagnostic run identified an expired stored credential before any recorded guest socket; I have not qualified an online session.

I reproduced [the local nickname hook ignoring a validated identity snapshot](../../../docs/reference/services.md#local-nickname-ignores-an-already-validated-account-snapshot) with synthetic profiles and real HLE hooks. I have not tested the change in this game or claimed that its current in-game name has changed.

I corrected [retention and renewal of the provider's OAuth grant](../../../docs/reference/services.md#a-linked-nextendo-account-expires-and-forces-browser-sign-in-again) in the shared account service, with synthetic production-coordinator and two-process checks. The actual service must still accept the application's consent/refresh, and updated ports must be rebuilt; I do not treat this as a completed Splatoon 3 online session or a graphics fix.

I ran the [Mac account transaction before SDK startup](../../../docs/reference/services.md#packed-mac-launch-does-not-prepare-a-renewable-game-account-before-sdk-startup) in the installed `9f3f6be1` candidate. I observed the [lobby and queue milestone above](#mac-acceptance-on-november-4-2026), with no preparation error in the captured ordinary prefix. I have not qualified a completed online match or observed a real hourly refresh/rotation.
