# Nextendo integration coverage

Snapshot: 2026-10-31. The provider-signed game catalog is revision 19 (58 entries, 62 regional title IDs); the independently signed NPLN patch catalog is revision 9 (22 exact-build patches). Catalog eligibility is not a gameplay test.

## Implemented native infrastructure

- Automatic per-title service profiles in Mac and signed iPhone exports, including third-party service families. The iPhone can prepare its public profile without entering an IP or transferring files.
- Browser PKCE account authorization, separately acquired NEX credentials in Keychain, and signed version policy; original game versions are retained.
- Bounded retail NSD service-name expansion and correct NEX socket status flags, shared by Mac and iOS. Smash 13.0.5 on Mac now authenticates, creates/joins arenas and has played one real arena round; its game note records the scope.
- Bounded DNS policies with exact-host, DNS-boundary suffix and single-label patterns; exact overrides preserve the separate NAT endpoint. Shared Epic service redirects are scoped to Guilty Gear.
- Explicit private-CA TLS validation: Apple chain evaluation plus strict OpenSSL SAN, purpose, signature, time and strength checks. Public HTTPS keeps system trust. Static dependencies target macOS 14 and iOS 26.
- Signed IPS32 adapters verify the full 32-byte NSO build ID, every preimage, patch digest, complete guard coverage, bounds and catalog validity. Mac and iPhone package separate rewritten code for Nextendo; explicit Offline/LAN use the original rewrite; automatic mode selects the available online variant. No game patches or game binaries are checked into this repository.
- Registered online SDK NROs are rewritten and signed ahead of time. Their activation is enabled in automatic and Nextendo mode; iOS never downloads or modifies executable game code at runtime.

## Service and gameplay qualification

Five production account/BAAS/data endpoints completed native TLS handshakes without sending application data. Local fixtures test bidirectional transport, wrong-host rejection, untrusted/expired certificates and malformed inputs. All 22 published IPS32 plans passed synthetic guarded-image checks. These are transport/build checks, **not 58 working native online games**.

The native social bridge now retrieves real friend snapshots and publishes the SDK application-presence field through canonical provider HTTPS. API/schema failures remain failures; object layout is verified from SDK getter/constructor semantics. PID and required server-reported BAAS identity are distinct. Friend availability and request completion use actual service results. Synthetic tests cover pagination, filters, cache/account separation, presence publication, malformed responses and unsupported layouts. Notifications, invitations, asynchronous profile requests and recent-play filters remain open, along with provider-specific legacy game adaptations outside the signed NPLN catalog and real per-game authentication, matchmaking and completed-match tests. On the probed MK8 NEX host, the presented certificate is self-signed without the required SAN; the probed device/application-auth chain does not match the published provider CA. These are retained as failed checks, not converted into successful authentication. Unknown exact builds receive no address-based patch. A game with no NPLN patch can still use its original SDK path; that is not a compatibility claim.

On 2026-10-31, the installed Mac Smash 13.0.5 port played a real Nextendo arena round and returned to the same lobby. Its private NEX endpoint used an explicitly approved exact-leaf enrollment; this is not a default CA-authenticated service or an approval for other endpoints. Quickplay currently rejects the connection as unstable, and a later arena session disconnected while spectating. Those failures remain open; one completed round does not establish stable online play. iOS Smash online remains unqualified.

## Full catalog inventory

“Profile” means a generated, bounded service configuration for every regional title ID. “Patch builds” counts signed published plans, not tested native builds. Smash 13.0.5 has one verified Mac arena round; other native online gameplay remains unverified.

| Game / application | Catalog protocol | Accepted versions | Regional profiles | Patch builds | Native online |
| --- | --- | --- | ---: | ---: | --- |
| Among Us | SDK / unspecified | 2026.19.0, 2026.18.0 | 1 | 0 | Unverified |
| Animal Crossing: New Horizons | SDK / unspecified | 3.0.3 | 1 | 0 | Unverified |
| ARMS | SDK / unspecified | 5.5.1 | 1 | 0 | Unverified |
| Clubhouse Games: 51 Worldwide Classics | nex | 2.0.1 | 1 | 0 | Unverified |
| Crash Team Racing Nitro-Fueled | demonware | 1.0.15 | 1 | 0 | Unverified |
| Crypt of the NecroDancer | SDK / unspecified | 4.2.1-b5668 | 1 | 0 | Unverified |
| Diablo III: Eternal Collection | demonware | 2.7.7.92380 | 1 | 0 | Unverified |
| DRAGON BALL FighterZ | SDK / unspecified | 01.50 | 1 | 0 | Unverified |
| Friday the 13th: The Game | SDK / unspecified | 1.08.00 | 1 | 0 | Unverified |
| Game Boy - Nintendo Switch Online | npln | 4.1.0 | 1 | 1 | Unverified |
| Game Boy Advance - Nintendo Switch Online | npln | 3.3.0, 3.4.0 | 1 | 2 | Unverified |
| Guilty Gear -Strive- | SDK / unspecified | 1.08 | 1 | 0 | Unverified |
| Just Dance 2022 | ubisoft | 326704.600931, 327835.644926 | 1 | 0 | Unverified |
| Kirby Fighters 2 | nex | 1.0.0 | 1 | 0 | Unverified |
| Luigi's Mansion 3 | SDK / unspecified | 1.4.0 | 1 | 0 | Unverified |
| Mario & Sonic at the Olympic Games Tokyo 2020 | nex | 1.0.1 | 1 | 0 | Unverified |
| Mario Golf: Super Rush | SDK / unspecified | 4.0.0 | 1 | 0 | Unverified |
| Mario Kart 8 Deluxe | SDK / unspecified | 4.0.1 | 1 | 0 | Unverified |
| Mario Party Superstars | nex | 1.1.1 | 1 | 0 | Unverified |
| Mario Strikers: Battle League | nex | 1.3.2 | 1 | 0 | Unverified |
| Mario Tennis Aces | SDK / unspecified | 3.1.1 | 1 | 0 | Unverified |
| METAL GEAR SOLID: Peace Walker | npln | 1.3.0 | 2 | 2 | Unverified |
| Minecraft Dungeons II | SDK / unspecified | 1.1.3.0 | 1 | 0 | Unverified |
| Minecraft: Nintendo Switch Edition | SDK / unspecified | 1.0.17 | 1 | 0 | Unverified |
| Monster Hunter Generations Ultimate | nex | 1.4.0 | 1 | 0 | Unverified |
| MONSTER HUNTER RISE | npln | 16.0.2 | 2 | 1 | Unverified |
| Nintendo 64 – Nintendo Classics | npln | 4.2.0 | 1 | 1 | Unverified |
| Nintendo Entertainment System - Nintendo Switch Online | npln | 9.1.0 | 1 | 1 | Unverified |
| Nintendo Switch Sports | SDK / unspecified | 1.5.0 | 1 | 0 | Unverified |
| Overcooked! 2 | npln | 1.0.19 | 1 | 1 | Unverified |
| Pac-Man 99 | SDK / unspecified | 1.1.0 | 1 | 0 | Unverified |
| Pokkén Tournament DX | nex | 1.3.3 | 1 | 0 | Unverified |
| Pokémon Legends: Z-A | npln | 2.0.2 | 1 | 1 | Unverified |
| Pokémon Scarlet | npln | 4.0.0 | 1 | 1 | Unverified |
| Pokémon Shield | SDK / unspecified | 1.3.2 | 1 | 0 | Unverified |
| Pokémon Sword | SDK / unspecified | 1.3.2 | 1 | 0 | Unverified |
| Pokémon Violet | npln | 4.0.0 | 1 | 1 | Unverified |
| Portal 2 | SDK / unspecified | 1.0.3 | 1 | 0 | Unverified |
| Saints Row: The Third – The Full Package | nex | 1.6.1 | 1 | 0 | Unverified |
| SEGA Genesis - Nintendo Classics | npln | 3.1.1 | 1 | 1 | Unverified |
| Sonic Racing: CrossWorlds | SDK / unspecified | 1.43 | 1 | 0 | Unverified |
| Splatoon 2 | SDK / unspecified | 5.5.2 | 3 | 0 | Unverified |
| Splatoon 3 | npln | 11.3.0 | 1 | 2 | Unverified |
| Super Kirby Clash | SDK / unspecified | 1.0.1 | 1 | 0 | Unverified |
| Super Mario 3D World + Bowser's Fury | SDK / unspecified | 1.2.2 | 1 | 0 | Unverified |
| Super Mario Bros. 35 | SDK / unspecified | 1.0.2 | 1 | 0 | Unverified |
| Super Mario Bros. Wonder | npln | 1.2.1 | 1 | 1 | Unverified |
| Super Mario Maker 2 | SDK / unspecified | 3.0.3 | 1 | 0 | Unverified |
| Super Mario Odyssey | SDK / unspecified | 1.4.1 | 1 | 0 | Unverified |
| Super Mario Party Jamboree | npln | 2.3.0 | 1 | 1 | Unverified |
| Super Monkey Ball Banana Mania | SDK / unspecified | 1.0.4 | 1 | 0 | Unverified |
| Super Nintendo Entertainment System - Nintendo Switch Online | npln | 6.0.0 | 1 | 1 | Unverified |
| Super Smash Bros. Ultimate | SDK / unspecified | 13.0.5 | 1 | 0 | [Mac arena round verified](../dm/games/01006A800016E000/README.md#native-network-validation) |
| Terraria | SDK / unspecified | 1.4.4.9, 4.5.6 | 1 | 0 | Unverified |
| Tetris 99 | nex | 2.6.0 | 1 | 0 | Unverified |
| Ultimate Chicken Horse | SDK / unspecified | 1.13.13.765 | 1 | 0 | Unverified |
| UNO | SDK / unspecified | 1.1.17 | 1 | 0 | Unverified |
| Zombie Army 4: Dead War | SDK / unspecified | 1.1.1 | 1 | 0 | Unverified |

## Native-profile qualification scope

The revision-19 catalog intersects **16 titles** with the native game profiles in this engine snapshot. Fourteen have a declared native build whose display version is accepted by the catalog. Scarlet and Violet currently declare native profiles for 1.0.0, while the service requires 4.0.0; those newer builds still need their own native qualification. A matching title ID or display version does not establish completed online play.

All 62 regional service configurations were prepared and staged through the production integrity checks using the pinned public provider CA. These are route/configuration checks, separate from the native profiles below and from authentication, matchmaking or a completed match.

| Game | Native profile | Declared native build versions | Catalog accepts | Native online qualification |
| --- | --- | --- | --- | --- |
| Animal Crossing: New Horizons | [01006F8002326000](../dm/games/01006F8002326000/README.md) | 3.0.3 | 3.0.3 | Not qualified |
| Luigi's Mansion 3 | [0100DCA0064A6000](../dm/games/0100DCA0064A6000/README.md) | 1.4.0 | 1.4.0 | Not qualified |
| Mario Kart 8 Deluxe | [0100152000022000](../dm/games/0100152000022000/README.md) | 4.0.0, 4.0.1 | 4.0.1 | Not qualified |
| Mario Party Superstars | [01006FE013472000](../dm/games/01006FE013472000/README.md) | 1.1.1 | 1.1.1 | Not qualified |
| MONSTER HUNTER RISE | [0100B04011742000](../dm/games/0100B04011742000/README.md) | 16.0.2 | 16.0.2 | Not qualified |
| Pokémon Legends: Z-A | [0100F43008C44000](../dm/games/0100F43008C44000/README.md) | 2.0.2 | 2.0.2 | Not qualified |
| Pokémon Scarlet | [0100A3D008C5C000](../dm/games/0100A3D008C5C000/README.md) | 1.0.0 | 4.0.0 | Accepted update not yet qualified |
| Pokémon Shield | [01008DB008C2C000](../dm/games/01008DB008C2C000/README.md) | 1.3.2 | 1.3.2 | Not qualified |
| Pokémon Sword | [0100ABF008968000](../dm/games/0100ABF008968000/README.md) | 1.3.2 | 1.3.2 | Not qualified |
| Pokémon Violet | [01008F6008C5E000](../dm/games/01008F6008C5E000/README.md) | 1.0.0 | 4.0.0 | Accepted update not yet qualified |
| Portal 2 | [0100ABD01785C000](../dm/games/0100ABD01785C000/README.md) | 1.0.3 | 1.0.3 | Not qualified |
| Super Mario 3D World + Bowser's Fury | [010028600EBDA000](../dm/games/010028600EBDA000/README.md) | 1.2.2 | 1.2.2 | Not qualified |
| Super Mario Bros. Wonder | [010015100B514000](../dm/games/010015100B514000/README.md) | 1.0.0, 1.0.1, 1.2.1 | 1.2.1 | Not qualified |
| Super Mario Odyssey | [0100000000010000](../dm/games/0100000000010000/README.md) | 1.4.1 | 1.4.1 | Not qualified |
| Super Mario Party Jamboree | [0100965017338000](../dm/games/0100965017338000/README.md) | 2.3.0 | 2.3.0 | Not qualified |
| Super Smash Bros. Ultimate | [01006A800016E000](../dm/games/01006A800016E000/README.md) | 13.0.5 | 13.0.5 | [One Mac arena round; Quickplay and stability open](../dm/games/01006A800016E000/README.md#native-network-validation) |

The full catalog contains other titles without a native profile in this snapshot. Generating their service routes does not add a native execution or graphics implementation for those games. Qualification must name the game build, platform, authentication path and actual multiplayer result.

## Community version reports

The user supplied a 24-title community list on 2026-10-31. These reports remain separate from authenticated provider eligibility. The current signed catalog has entries matching 21 of those reported names, including Terraria (`1.4.4.9` and `4.5.6`). Stardew Valley (`1.6.15.13`), Monopoly for Nintendo Switch (`1.0.5`) and Dying Light: Platinum Edition (`1.0.5`) are not present in revision 19; their service qualification is pending rather than silently omitted or marked supported.

Several reported versions differ from the provider's exact policy: Rise `16.02` versus `16.0.2`; Just Dance 2022 `1.0.2` versus its listed internal build versions; Crypt of the NecroDancer `4.0.0` versus `4.2.1-b5668`; Sonic Racing: CrossWorlds `1.4.3` versus `1.43`. The report names Guilty Gear `1.0.8`, whereas the catalog identifies **Guilty Gear -Strive-** `1.08`; title identity must be established before treating them as the same game. Ports retain their actual title IDs and versions. Among Us accepts both listed updates, but cross-version matchmaking has not been tested.

DLC counts in a community report do not establish DLC identities or ownership. The signed catalog explicitly leaves Diablo III (3), Overcooked! 2 (6) and Minecraft Dungeons II (unspecified count) pending exact identifiers. The report also requests Rise: Sunbreak and ten CTR DLC items; these are tracked requirements, not fabricated validation results. Only supplied, owned content is packaged.

## Primary provider references

[Game catalog](https://nextendo.network/service-catalog/v1/game-catalog), [signed patch catalog](https://nextendo.network/service-catalog/v1/npln-patches), [provider projects](https://github.com/NextendoNetwork). Endpoint facts were inspected at Prelude commit `482c182917228d69ebbbabfea44fffa4a44051be` and the Nextendo Ryujinx client commit `140ecc0084c2979d6d53bb767852a67f5186cb85`. This project implements its adapters independently; the other clients are not imported as MIT-licensed project code.
