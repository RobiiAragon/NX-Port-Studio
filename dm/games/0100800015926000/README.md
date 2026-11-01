# Suika Game

Version 2.3.6, Unity 2022.3.13f1 / IL2CPP, Nintendo SDK 16.2.6, NVN.
This is an experimental startup profile, not a claim of complete game coverage.

## Startup and memory

The original provisional profile aborted during `nninitStartup`, before
`nnMain`, on both Mac and iPhone. `StandardAllocator::Initialize` could not fit
its first region after the SDK's approximately 1 GiB address-region node area.
The SDK build has the same reviewed constructor mechanism as other SDK 16
titles. Its two node-area values are reduced to 62 MiB through an exact-build,
original-byte-checked cut in `dm/tools/sdk_patches.py`.

The NPDM declares 16 MiB of system resource. The profile keeps a 5 GiB address
reservation with a 4.375 GiB alias region. After the node-area fix, calibration
reduced the reported application pool to 1 GiB so StandardAllocator leaves room
for Unity's own address regions. In the bounded Mac startup, the alias high-water
mark fell from 4.26 GiB to 2.27 GiB; mapped backing reached about 0.78 GiB.
These are startup observations, not worst-case memory bounds for every mode.

The calibrated Mac host ran for 25 seconds and logged more than 1,200 frames
without the previous abort or red diagnostics. A signed update on iPhone 18 Pro
passed `nnMain` and logged 6,300 on-screen frames without a fatal,
crash or red diagnostic. Observed device footprint rose from about 1.04 GiB to
1.44 GiB during this startup. The user also confirmed that game content is visible
and the app stays open on the iPhone. Full gameplay coverage remains unverified.
The final captured log ends
with background entry and drained GPU work; no new abort is recorded there.
Shader metadata remains byte-identical to the prepared package; generated
libraries, SDK files, game resources and diagnostic logs remain private.

## Found on this game

- [The SDK's address-region node area](../../../docs/reference/memory.md#the-sdks-address-region-node-area).
- [A saved certificate does not configure an Xcode account](../../../docs/reference/packing.md#a-saved-certificate-does-not-configure-an-xcode-account).
- [Failed memory calibration must be retried](../../../docs/reference/packing.md#failed-memory-calibration-must-be-retried).

## Open

Validate longer play, all modes and memory peaks on both platforms. A successful
heap observation calibrates memory; it does not establish full compatibility.
