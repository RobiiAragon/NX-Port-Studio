# JKSV save interchange

I provide one save manager in Studio and in newly built Mac/iPhone/iPad ports. It transfers decrypted game save files using the ZIP layout JKSV imports and exports. It does not convert encrypted console save containers or translate incompatible game save versions.

## In Studio

Open **Saved games**, choose an installed Mac port and its save type, then import a JKSV ZIP, export a ZIP, or open the save/backups folder. Close the game first. The manager checks running installed apps; updated runtimes also hold a shared filesystem lease that prevents an external restore while the guest can access its save.

**Main save** is the game's usual save, including titles with only a device save. **Device save** is an additional separate device save for games that mount both account and device data, such as Mario Kart 8 Deluxe. Import/export each separately; putting both trees in one ZIP is not JKSV's format. Select the same game and save type when restoring on the Switch.

## Inside a port

Open **Saved games** in the port's launch settings, before Play. Mac ports restore immediately before boot and can reveal their directories in Finder. On iPhone/iPad, choose a ZIP from Files, confirm it, then close and reopen the port. The original ZIP is copied and validated when selected; the actual restore runs on the next cold launch **before guest preloading**. Play stays disabled after preparing an import. A pending import can be canceled without replacing the existing save; reopen afterward.

An iOS export clones one committed save under the filesystem's commit locks, then creates the ZIP from that snapshot. Use **Share exported ZIP** to save it in Files or transfer it. The folder browser exposes regular files/directories for browsing and sharing. It does not edit a live save. Mac exports run before the guest starts. Changes to Studio do not retrofit already built apps: rebuild each port to receive these controls.

## ZIP layout and original metadata

Save files sit directly at the archive root, without an outer game-name folder. Relative subdirectories, Unicode filenames and empty files are preserved. Case-colliding names are exported using Horizon’s logical names, not the runtime’s `.dm-case-*` storage aliases; import recreates those mappings on case-insensitive Apple filesystems. The optional `.nx_save_meta.bin` record is independently interpreted from [JKSV's public metadata declaration](https://github.com/J-D-K/JKSV/blob/rewrite/include/fs/SaveMetaData.hpp): revision 1, 86 bytes. Its title ID and save type are checked when present. The original record is retained as a private directory attribute and restored to future ZIP exports; it is excluded from the files seen by the game. Its account bytes are never fabricated or promoted to an online identity.

Older/raw backups without that record also work. Their game cannot be established from arbitrary file contents, so check the selected game yourself. Exports created without imported metadata remain raw JKSV-compatible ZIPs. Metadata survives the runtime's APFS clone-and-swap save transactions. The ZIP format alone does not prove that one game's files will load under a different update or DLC configuration.

## Replacement and recovery

A ZIP is extracted into a new private staging directory and fully checked before publication. Existing saves are replaced with an atomic directory swap; the previous complete tree is retained under `save-backups`. A backup-move failure leaves the old tree in its staging location and reports that actual path. A published restore is never reported as safely retryable if a later disk synchronization fails.

iOS pending imports carry a private job token that follows the restored directory through later commits. If removing a consumed queue file fails, the next launch recognizes the applied token and does not roll back newer game progress. Import/export operations use nonblocking leases; concurrent management reports busy rather than waiting behind a game indefinitely.

Archives are bounded to 8 GiB of extracted files, 2 GiB per file, 32,768 entries, 64 directory levels and platform path limits. Encrypted ZIPs, links, special files, unsafe paths, duplicate file aliases, wrong-title/type metadata, corrupt CRCs and changed sources are rejected. Existing ZIP destinations are never overwritten. The implementation uses Apple's SDK libarchive with [preserved public-header notices](../dm/third_party/libarchive-headers/LICENSE.txt); no JKSV implementation is copied.

## Validation scope

I tested independently generated Python ZIPs against the real shared C implementation, including archive round trips, original synthetic metadata, atomic replacement with retained previous data, rejected malformed inputs, delayed imports, recovery without rollback, cancellation and actual OS lease contention, APFS metadata retention and case-colliding guest-name round trips. These run normally and with ASan/UBSan. Swift tests exercise the Studio adapter and installed-port discovery. Both Apple SDKs compile the native controls; full host and iOS source checks remain part of CI.

This is format and implementation validation. A physical Switch restore and game-by-game save compatibility still need qualification. No personal saves or Nintendo game files are test fixtures or public repository assets.
