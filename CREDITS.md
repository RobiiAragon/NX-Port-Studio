# Credits and provenance

NX Port Studio is an independent project built on [nxnative by seedds](https://github.com/seedds/nxnative). It is not presented as the original author of that engine. The original MIT license and `Copyright (c) 2026 seedds` notice are preserved in [LICENSE](LICENSE).

## The foundation

- **seedds / nxnative:** native Switch execution on Apple hardware, the host and graphics layers, profiles, tools and documentation on which this project builds.
- **[d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile):** the earlier native-execution approach from which nxnative's generic rewriter, Horizon host, NVN-on-Metal and iOS shell originated. Its upstream attribution and license notices must remain.
- **Studio contributors:** the macOS workflow, mandatory signed IPA exports, resource-library integration, controller/network work and validation added around that foundation. Commit history should identify the authors of individual changes.

## Dependencies and reference work

Preserve the exact license files and attribution in the source tree. This overview does not replace those notices or relabel all dependencies as MIT.

| Project | Role |
| --- | --- |
| Ryujinx | Shader translation libraries; reference work for kernel and system services. Vendored components retain their MIT notices. |
| LibHac / hactool | Original package extraction and update/resource handling; preserve their own notices. |
| SPIRV-Cross / glslang | Shader conversion and compilation used by the graphics toolchain. |
| h1k421 / reconstructed NVN interface | MIT-licensed interface definitions in `dm/gfx/nvn/include/nvn.h`; preserve the file's original notice. These are not a redistributed original Nintendo SDK. |
| deko3d | Texture layout work, including the separately credited zlib-licensed port in the NVN layer. |
| SDL / Valve contributors | Joy-Con amplitude quantization adapted under the zlib license. The altered-source notice is retained in `joycon_rumble.h`. |
| libvpx / stb_vorbis | Video and audio decoding; their licenses remain beside the vendored sources. |
| Vulkan-Headers / NVIDIA FLIP / MacNativeGames | Graphics interfaces, verification and individually attributed implementation components. |
| Atmosphère / libnx / Switchbrew / Nintendo Switch reverse-engineering contributors | Primary references for observable platform structures, synchronization, hardware protocols and service semantics. |
| ldn_mitm contributors | Public wire-format and interoperability references for the original C bridge. The bridge implementation does not copy the GPL discovery implementation. This does not change the license of the external Switch module. |
| Nextendo contributors | Account, service and signed-catalog infrastructure used by the integration. No endorsement or ownership of that service is implied. |
| Capstone / lz4 / fontTools / XcodeGen | Build and analysis tools, with their respective licenses. |

The engine's vendored dependency inventory remains the authoritative map for included components and notices. When exporting this repository, retain that inventory and every applicable license alongside the code.

## Artwork and validation media

The banner in `docs/images/hero.svg` is original SVG artwork based on Studio's source-drawn cartridge/export icon. It contains no game artwork or invented application screenshot.

The Studio interface captures in `docs/images/studio-*.jpg` were taken from the running macOS app. Their reviewed hashes and provenance are recorded in `public-assets.json`.

Nintendo gameplay screenshots, covers, artwork, game icons, firmware, game content and original SDK files are excluded from this public repository. Test results may be documented in text; excluding artwork does not remove the obligation to credit upstream software authors.
