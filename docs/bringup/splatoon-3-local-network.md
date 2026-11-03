# Splatoon 3: LAN and local-wireless qualification

I audited my **11.3.0** dump on November 2, 2026 (Tijuana local time): title `0100C2500FC20000`, main build `28c4287aee36f7499da60f3e68b54c70`, SDK build `574284b40c06cf1821a44857939083be` (**20.5.22**), Pia **6.32.3**. I compared the imports with the native backend at `dd71f4a8`. This is a source/ABI and fixture result; I have not yet qualified a Splatoon 3 local room or match.

## The game's actual modes

I confirmed that this title has a built-in LAN mode as well as local wireless. Nintendo documents the entry in **The Shoal**: hold **ZL + ZR + Left Stick** until the LAN preparation message appears. This differs from Mario Kart's shortcut. LAN offers Private Battle with up to eight players and two spectators, or Salmon Run with up to four players. Nintendo's console setup uses a shared wired router and compatible LAN hardware; no console modification is required for that built-in mode. See [Nintendo's LAN instructions](https://www.nintendo.com/en-gb/Support/Purchases-Subscriptions/Games/How-to-Use-the-LAN-Play-Feature-of-Splatoon-3-2266112.html).

For local wireless, Nintendo lists up to eight consoles; each player uses a separate console and game. I keep that distinct from wired LAN and from an online service. See [Nintendo's multiplayer overview](https://splatoon.nintendo.com/en/world/).

| In-game choice | Native path I audited | What a console peer needs | Qualification still needed |
|---|---|---|---|
| Shoal, ordinary local wireless | `nn::ldn`, native discovery/membership over IP | A compatible IP LDN module; a stock console's radio-only session is a different transport | Discovery, both host roles, roster changes, a complete match |
| Shoal, built-in LAN | PiaLan and Horizon socket hooks | The game's LAN mode, compatible game version and the same reachable LAN | Actual Pia6 discovery packets, both host roles, match results, disconnect/rejoin |
| Online lobby | NPLN/account/TLS routes | The provider's game/version/account requirements | Separate Nextendo authentication and completed-match evidence |

The [IP LDN module's own description](https://github.com/spacemeowx2/ldn_mitm) explains that it replaces console local-wireless discovery with IP traffic. My native bridge does not implement Nintendo's console radio protocol. I therefore cannot use its IP fixtures to claim interoperability with an unmodified console's ordinary wireless menu. The built-in LAN row is the route to test with unmodified hardware.

## Imported ABI and the missing protocol selector

I found **26** imported LDN entries. Twenty-four already had native hooks. `MakeBroadcastAddress` is a pure bitwise IPv4 helper and can remain in the original SDK. The remaining `SetProtocol(Protocol)` is a service operation: its SDK wrapper dereferences the service global populated by the original initializer, which the native LDN initializer replaces. A Pia initialization call checks its returned `Result`.

I added the [native protocol selector](../reference/services.md#sdk20-ldn-protocol-selection-after-native-initialization). It selects the implemented NX path for SDK Default/NX, validates the initialized lifecycle, and rejects alternate protocol3. Public references label that alternate `Unknown3` and tentatively associate it with NX/Ounce; I have not established its additional semantics. I did not add a successful placeholder for that protocol or alter the game's function. The existing socket imports used by the LAN path already have native hooks; byte-order and address-text helpers can remain pure SDK code.

My source audit does not establish the game's runtime protocol argument, LAN packet compatibility or successful room creation. `DM_LDN_TRACE=1` can record the requested protocol, lifecycle transitions and operation results without recording peer addresses, names, account identifiers or packet contents. If the game requests protocol3, its explicit failure remains a qualification blocker.

## Automatic discovery and physical checks

I retain `DM_NETWORK=auto`: local menus do not require Nextendo credentials, protocol selection in the launcher, or a manually entered peer address. Mac LAN uses the game's original sockets. The existing iOS automatic unicast and optional Mac discovery relay recognize specific discovery framing; I have not verified their Pia6 framing against this game's actual traffic. A known-good Mario Kart discovery fixture is insufficient evidence for Splatoon 3 on iOS.

I need matching, privately owned game versions on two endpoints to complete these checks:

1. Enter the built-in LAN menu, create a Private Battle on the port, discover/join from a physical console, finish a match through results, then reverse the host role.
2. Repeat through the ordinary Shoal local-wireless menu with a compatible console IP LDN module, recording actual protocol selection, discovery, membership, game traffic and exit/rejoin. A Mac-to-Mac fixture cannot substitute for the console result.
3. Check Salmon Run separately; neither a Private Battle lobby nor an online account proves it works. Test spectator slots in LAN independently of the eight-node LDN bridge.
4. After an iOS export exists, validate its Local Network permission, actual discovery framing and both host roles without manual peer configuration.

I have not changed console firmware/modules, user saves, installed ports or the game's original network code during this audit. My synthetic protocol/session fixtures pass **14,859** checks under ASan/UBSan; the SDK-hook fixture also covers protocol state, context lifetime and concurrent finalization. These results prepare the backend; they do not certify a Splatoon 3 match.
