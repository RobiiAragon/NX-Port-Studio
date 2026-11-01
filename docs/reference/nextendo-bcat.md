# Native delivery calendars

I prepare public Nextendo calendars during a port build and check for updates in
an independent background task at game startup. I use the same original importer
on macOS and iOS. A download, catalog entry or successful bootstrap does not prove
an online match.

## Current resource adapter

I implemented the documented Splatoon 2 BCAT layout for the provider's exact EUR
`0100f8f0000a2000`, USA `01003bc0000a0000` and published Japanese
`01003c700009c800` identities, with version **5.5.2**. The Japanese catalog identity
is in the patch range; I do not silently authorize the different base title ID.
I verified actual downloads and private staging for all three published
identities. I have not tested these resources in a running online game.

[Prelude's public resource contract](https://github.com/NextendoNetwork/Prelude-Nextendo/blob/482c182917228d69ebbbabfea44fffa4a44051be/source/nextendo_bcat.h)
identifies `/api/bcat/<titleID>` and the `coopdata`, `vsdata` and `fesdata` directories.
I place these files at `DebugUnderPilot/bcat` in a read-only RomFS overlay. For
EUR/USA I also obtain the configuration and dummy resource from the pinned
Prelude revision and require their exact SHA-256 values. I keep these payloads
in private local caches and game apps; none belongs in this source repository.

I did not import Prelude implementation code. The importer and SDK adapters are
original implementations. Resource provenance refers to the provider's data and
layout, not a claim that its differently licensed implementation is part of this
MIT codebase.

## Integrity and publication

I verify the Ed25519 signature of the
[official game catalog](https://nextendo.network/service-catalog/v1/game-catalog),
the exact regional identity, enabled state, supported capabilities and accepted
game version. A fresh catalog is required before a network refresh. I retain a
valid older snapshot when offline; catalog expiry is not misrepresented as a
successful online eligibility check.

The calendar ZIP endpoint currently supplies **no detached signature or published
digest**. I authenticate its transport with normal HTTPS certificate/hostname
verification. I do not call its payload signed. A local SHA-256 inventory detects
cache corruption; ZIP CRCs, resource headers, safe paths and explicit size limits
are additional checks. I reject redirects, cookies, stored URL credentials,
encryption, symlinks, traversal, duplicate/case-alias names, overlapping entries,
unsupported compression, invalid BYAML offsets and incomplete required data. I
accept highly compressible valid textures using absolute bounds rather than a
compression-ratio cutoff. Per-service game TLS exceptions are not used by the
calendar downloader.

I stage a complete immutable snapshot and its provenance manifest before
atomically publishing its pointer. The build embeds only a revalidated complete
snapshot. If the first download is unavailable, I can embed only its explicit recipe descriptor so startup can retry; it cannot be mounted or reported as delivered data. A failed download never publishes an empty successful delivery cache.
An optional ETag produces a conditional request when the server supplies one;
a 304 response still requires revalidation of the retained data.

Build cache: `~/Library/Application Support/NX Port Studio/Nextendo/BCAT/`.
Runtime cache: the app's Application Support directory under
`nxnative/BCAT/<titleID>/<version>/`. I keep refresh work off the guest thread and
do not require an account token for these public resources. A network outage
leaves local play and the previous verified snapshot available.
Disabling online services still selects a valid local snapshot; it prevents the
downloader and synchronization requests, rather than disabling delivery-file
reads. The recipe must match this port's exact title, version and format.

## Runtime behavior

I fix the RomFS overlay for the session so background publication cannot change
paths underneath the game's open resources. New delivery opens can select the
new validated snapshot; an already-open delivery file keeps its original native
file descriptor. The updated RomFS overlay becomes available at the next game
launch. This deliberately avoids replacing files during a match.

The delivery mount is real and read-only. Missing data returns failure. Directory
listing merges overlay and base resources. Unmount hides new `bcat:` path opens;
existing immutable file descriptors remain usable until closed. The SDK adapter
implements actual file reads, sizes, MD5 delivery digests and directory entries.
Progress observers retain their own asynchronous job, including its final
failure or success and the SDK's completed status value 9. A pending job
can have no error yet without being complete; I preserve that distinction. It does not fabricate a completed
network synchronization from an empty cache.

I derived the SDK 3 object/return ABI from my own Splatoon 2 dump, and checked the
public [BCAT service descriptions](https://switchbrew.org/wiki/BCAT_services).
I verified the 16-byte digest through the actual registered BIG guest entry,
including its `x0`/`x1` return registers and guest-to-host stack transition. The
unopened size, digest and directory-count getters retain the SDK's abort
precondition. A successful repeated synchronization request replaces its old
observer; a failed request preserves it. Startup accepts its identity only once.
The tests use original synthetic resources and keys, never Nintendo files.

## Validation and remaining bring-up

I ran policy, ZIP, cache-path, SDK lifecycle and filesystem overlay fixtures,
including AddressSanitizer/UndefinedBehaviorSanitizer checks. I compiled the new
backend for the iPhone SDK. These checks establish mechanisms, not multiplayer
compatibility.

I also tested a real cold startup with only the USA 5.5.2 recipe and no runtime
cache. Its initial delivery mount failed. The background HTTPS task downloaded
and validated the public resources, after which the actual filesystem HLE mounted
the delivery cache, opened and read a BYAML calendar and hid the mount again on
unmount. A second process selected that validated cache at startup and read the
real configuration XML through the merged RomFS overlay. These tests used no
account credentials and did not run a game or verify matchmaking.

I repeated startup with online services disabled. The validated USA cache still
provided its RomFS configuration and real delivery files. A separate EUR process
with only a recipe and no cache correctly failed its mount. Neither queued a
download or accepted a synchronization request; both retained the not-started
progress status instead of reporting completed synchronization.

My first native Splatoon 2 EUR 5.5.2 bootstrap reached `nnMain` with the real merged
RomFS, then encountered the SDK 3 system-gameplay-recording applet path. After I
exposed the missing system-recorder capability correctly, a second headless
bootstrap ran for its full 15-second limit, initialized audio and produced NVN
frames without crashing. I intentionally used no translated game shaders in that
bootstrap, so I have not verified the rendered image or title screen. Shader
translation, matchmaking, a complete online match, local wireless and LAN still
require separate game tests. I have not installed or qualified a playable
Splatoon 2 port yet.

Other games can use the same downloader/store and SDK API. I only enable a
resource recipe after verifying its provider layout, formats and identity policy;
I do not treat every Nextendo catalog entry as needing the Splatoon calendar.
