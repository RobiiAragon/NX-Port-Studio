# Packing

## Compressed inputs

### NSZ decompression rejects `--keys`

- **Symptom:** `decompress NSZ` stops immediately with `nsz: error: unrecognized arguments: --keys …`.
- **Cause:** `nsz` 4.6.1 has no `--keys` argument. It loads `keys.txt` beside `sys.argv[0]`, or falls back to `~/.switch/prod.keys`, while importing its modules, before parsing arguments ([4.6.1 key loader](https://github.com/nicoboss/nsz/blob/4.6.1/nsz/nut/Keys.py)). Newer upstream code supports `--keys`; staging `keys.txt` also supports 4.6.1.
- **Fix:** `scripts/build_ipa_from_nsp.py` `decompress_nsz` links the file selected by `-k` as `keys.txt` in the conversion's temporary folder and runs `nsz -D` there, with `sys.argv[0]` set to `nsz` before import. Input and output paths are absolute. The temporary folder and link are removed on success or failure; the user's default keys are untouched.
- **Found on:** [Super Mario Odyssey](../../dm/games/0100000000010000/README.md), converting its v0 NSZ. Applies to NSZ and XCZ inputs for every game.

## Device builds

### Deployment uses one Xcode output root

- **Symptom:** a signed Release rebuild stops at `SwiftDriver` with `The Xcode build system has crashed`. The local `SWBBuildService` reports show `EXC_BAD_ACCESS` in `clang::ASTReader::ReadAST` during Swift's Clang-module dependency scan.
- **Cause:** prepared projects derive `OBJROOT`, `SYMROOT` and `CONFIGURATION_TEMP_DIR` from `DM_XCODE_OUTPUT_ROOT`. NX Port Studio previously overrode only `CONFIGURATION_BUILD_DIR` and passed another `-derivedDataPath`, mixing the prepared project's compile records with the deployment's module caches. The exact cached module that crashed the scanner was not identified.
- **Fix:** `DeviceService.deploymentPlan` passes `DM_XCODE_OUTPUT_ROOT` and `-derivedDataPath` with the same normalized deployment directory. The affected game recovered with a fresh deployment directory and completed a signed Release build, including real Apple-signature and provisioning-profile verification. Recovery needs only that game's deployment data; extracted game files, shader caches, saves and other projects remain untouched.
- **Found on:** Tomodachi Life 1.0.3 (`010051F0207B2000`), an Xcode 27.1 [prepared device project](../development.md#build-and-run-on-a-device-with-xcode), after changing the iOS controller adapter.
