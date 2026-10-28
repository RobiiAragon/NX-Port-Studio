# Translator dependency notices

These texts accompany the checked-in translator under `dm/gfx/tools/dmsh_xlate_bin`. They preserve the original notices of its dependencies; they do not relabel those components as NX Port Studio code.

| Component | Exact version | License / notice | Primary provenance |
| --- | --- | --- | --- |
| Gommon | 2.8.1.2 | [MIT text](Gommon/LICENSE.txt) | Official NuGet package, `content/LICENSE`; repository commit `222084874ac473e02f27faeb10e540f926702976`. |
| Humanizer / Humanizer.Core and 51 localization packages | 3.0.10 | [MIT text](Humanizer/LICENSE.txt) | Official NuGet metadata and upstream commit `90f0cb1d7427635f38b46350bb1dc5fca2164f2d`. |
| Microsoft.IO.RecyclableMemoryStream | 3.0.1 | [MIT text](RecyclableMemoryStream/LICENSE.txt) | Official NuGet metadata and upstream commit `e29a28387da9018fa9605a1dcb3f7a0435aa9974`. |
| MsgPack.Cli | 1.0.1 | [Apache-2.0 text](MsgPack.Cli/LICENSE.txt), [package attribution](MsgPack.Cli/PACKAGE-NOTICE.txt) | Official NuGet package metadata and upstream tag `1.0.1`. No separate root upstream NOTICE file was present at that tag. |
| System.CodeDom | 4.4.0 | [MIT text](System.CodeDom/LICENSE.txt), [original third-party notices](System.CodeDom/THIRD-PARTY-NOTICES.txt) | Both texts extracted unchanged from the official NuGet package. |
| .NET macOS ARM64 apphost | 10.0.13 | [MIT text](dotnet-apphost/LICENSE.TXT), [original third-party notices](dotnet-apphost/THIRD-PARTY-NOTICES.TXT) | Official `Microsoft.NETCore.App.Host.osx-arm64` NuGet package. The embedded commit resolves in the official dotnet/dotnet VMR: `4099f83977f4d29604a9aeb971fb0a7bc1d5f699`. |

The 56 NuGet DLL/resource payloads were compared byte for byte with the corresponding official package entries. Four managed outputs are built from project sources: `dmsh_xlate.dll` uses the [project license](../../../LICENSE), `Ryujinx.Common.dll` and `Ryujinx.Graphics.Shader.dll` retain the [Ryujinx license](../ryujinx/LICENSE.txt), and `Spv.Generator.dll` retains [its own license](../ryujinx/src/Spv.Generator/LICENSE). The native apphost is generated from a template by binding its managed entrypoint and Mach-O signature, so it is recorded separately rather than described as byte-identical to an unbound template.

[manifest.json](manifest.json) records package URLs, repository references, notice-text hashes, all 61 runtime binary hashes and their notice mapping. It has no machine-specific paths, credentials, game files or original Nintendo SDK assets. The two translator JSON metadata files are dependency/runtime configuration, not additional runtime binaries. Optional PDB debug files are excluded from the public export.

The original notice texts are retained verbatim. `MsgPack.Cli/PACKAGE-NOTICE.txt` is explicitly labeled as a transcription of package metadata attribution rather than a fabricated upstream NOTICE. Broad .NET notice files are preserved as shipped with their packages and do not imply that every listed .NET component is independently included in this translator.
