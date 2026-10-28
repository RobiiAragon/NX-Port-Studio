# Tomodachi Life: Living the Dream

## Status

Bring-up in progress on 1.0.3, SDK 20.5.3, Nintendo EPD's sead / agl / gsys engine over NVN. The profile is registered here with the derived shader tables; game files and translated shader libraries stay beside the user's extracted game. Intro/editor testing does not establish full playability.

After the startup and mip-tail fixes below, the Mac renders the initial settings, the island tutorial and responds to both cursor and camera sticks at about 30 fps. First-resident creation reaches the facial editor and height/build screen. With `render_cond on`, the initial Mii previews and facial editor display complete Miis with head, hair, face and body; without it the offscreen previews are erased, although the height/build screen still displays a Mii. Validation used a separate test save and an isolated host built against the generated profile. The initial iPhone Play crash was reproduced on the Mac; the corrected iPhone build still needs a fresh on-device gameplay check.

## Build and profile

- Main build ID: `6291e14453ee63090164e79b227113f0`.
- SDK build ID: `651781821e2c2e0b2bdfe905e8676f56`.
- The generated profile reserves 4 GiB, with alias/stack regions of 256 MiB, application pool `0xCD500000` and rewritten used memory `0x6600000`. The NPDM declares no system-resource region. These remain provisional values, not newly tuned memory rules.
- Modules: `main sdk`. No game-specific rewriter cuts were added during this bring-up.
- `render_cond on` evaluates the game's clear conditions. A Mac A/B using identical code, data and shader libraries changed the empty Mii previews/facial editor to visible Miis. The pass dump shows initial counters 1/0, timestamp reports, then 0/0 conditions that skip redundant color/depth clears. Leaving conditions off erases the reused offscreen targets. This reuses the existing backend also required by Animal Crossing: New Horizons and Tears of the Kingdom.
- Shader input tables and `shader_*` values preserve their original digest; adding `render_cond` changes host behavior and does not require translating the shader library again.

## Driving the Mac test

Start with a separate test save. In the Spanish first-run settings, the defaults already select the correct date/time, North America, pesos and OK: confirm with A. A clock-change warning may follow; confirm its three notices, then move right from No to Yes to start with the current time. The rendered island asks to move the cursor with the left stick and camera with the right stick before introducing the first resident. Diagnostic `DM_CTL` input and screenshots can drive this route; avoid timed scripts that choose a date-adjustment option before checking the current selection.

## Found on this game

- [Album image notifications without an application proxy](../../../docs/reference/services.md#album-image-notifications-without-an-application-proxy): the initial Play crash, a null application proxy in `EnableAlbumImageTakenNotification`.
- [Adjustable-clock snapshots](../../../docs/reference/services.md#adjustable-clock-snapshots): the next abort called the unopened time-service session instead of the host clock.
- [Conditional rendering evaluated at replay](../../../docs/reference/rendering.md#conditional-rendering-evaluated-at-replay): redundant clears erase offscreen Mii portraits and the facial editor unless the profile enables render conditions.
- [Redundant 1x1 mip tails exceed Metal's dimensioned chain](../../../docs/reference/nvn-objects.md#redundant-1x1-mip-tails-exceed-metals-dimensioned-chain): preserving the guest's 15 levels while materializing nine Metal levels avoids the next assertion without changing pool layout.

## Open

- Confirm the corrected build on the iPhone and continue through first resident creation, save/relaunch and ordinary play before declaring the port playable.
- A green rectangle can remain over tutorial/editor UI with conditional rendering enabled. Its rendering cause is unconfirmed. The empty Mii previews/facial editor are resolved by `render_cond on`; the run logs no MiiModel stand-in mount.
- The first-run clock-change warning remains unexplained. It can be acknowledged normally; no time-check bypass was added.
- Explicit sampling/rendering/copying of redundant mip-tail levels beyond the physical Metal chain is not implemented. No such access was needed to reach the island tutorial.
- Sustained performance, audio output and later game features have not been verified by this bring-up run.
