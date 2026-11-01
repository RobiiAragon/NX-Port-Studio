// Read-only container identification. LibHac verifies the Meta NCA filesystem;
// only the bounded CNMT header is interpreted here, never game code or RomFS.
// Layout: https://switchbrew.org/wiki/CNMT (PackagedContentMetaHeader and extended headers).
using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using LibHac.Common;
using LibHac.Common.Keys;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.Ncm;
using LibHac.Tools.Fs;
using LibHac.Tools.FsSystem;
using LibHac.Tools.FsSystem.NcaUtils;

static class ContainerIdentity {
    internal const int MaxMetadataBytes = 1024 * 1024;
    internal const int MaxRecords = 128;
    internal sealed record IdentityRecord(string titleId, string applicationTitleId, string type, uint version);

    internal static IdentityRecord Parse(ReadOnlySpan<byte> data) {
        if (data.Length < 0x20 || data.Length > MaxMetadataBytes) throw new InvalidDataException("The CNMT size is invalid.");
        var kind = (ContentMetaType)data[0xc];
        int requiredHeader = kind switch {
            ContentMetaType.Application => 0x10,
            ContentMetaType.Patch => 0x18,
            ContentMetaType.AddOnContent => 0x10,
            _ => throw new InvalidDataException("The container has no supported application, patch or add-on metadata.")
        };
        if (data[0xd] != 0) throw new InvalidDataException("The CNMT targets an unsupported content platform.");
        int extendedHeader = BinaryPrimitives.ReadUInt16LittleEndian(data.Slice(0xe, 2));
        int contents = BinaryPrimitives.ReadUInt16LittleEndian(data.Slice(0x10, 2));
        int metas = BinaryPrimitives.ReadUInt16LittleEndian(data.Slice(0x12, 2));
        long minimumBytes = 0x20L + extendedHeader + contents * 0x38L + metas * 0x10L + 0x20;
        if (extendedHeader < requiredHeader || contents > 4096 || metas > 4096 || minimumBytes > data.Length)
            throw new InvalidDataException("The CNMT tables are truncated or exceed the supported bounds.");
        if (kind == ContentMetaType.Patch) {
            uint extraBytes = BinaryPrimitives.ReadUInt32LittleEndian(data.Slice(0x2c, 4));
            if (minimumBytes + extraBytes > data.Length) throw new InvalidDataException("The CNMT extended data is truncated.");
        }
        ulong title = BinaryPrimitives.ReadUInt64LittleEndian(data);
        ulong application = kind == ContentMetaType.Application ? title : BinaryPrimitives.ReadUInt64LittleEndian(data.Slice(0x20, 8));
        if (title == 0 || application == 0) throw new InvalidDataException("The CNMT title identity is empty.");
        return new IdentityRecord(title.ToString("x16"), application.ToString("x16"), kind.ToString(), BinaryPrimitives.ReadUInt32LittleEndian(data.Slice(8, 4)));
    }

    internal static IdentityRecord[] Select(IEnumerable<IdentityRecord> input) {
        var records = new List<IdentityRecord>();
        foreach (var item in input) {
            if (records.Count == MaxRecords) throw new InvalidDataException("The container contains too many metadata records.");
            records.Add(item);
        }
        if (records.Count == 0) throw new InvalidDataException("No application CNMT was found; use a complete game dump.");
        if (records.Select(x => x.applicationTitleId).Distinct(StringComparer.Ordinal).Count() != 1)
            throw new InvalidDataException("The container holds more than one game; use a single-game dump.");
        if (records.GroupBy(x => (x.titleId, x.type)).Any(group => group.Select(x => x.version).Distinct().Count() != 1))
            throw new InvalidDataException("The container holds conflicting versions of the same title metadata.");
        return records.Distinct().OrderBy(x => x.titleId, StringComparer.Ordinal).ThenBy(x => x.type, StringComparer.Ordinal).ToArray();
    }

    public static int Identify(KeySet keys, string source, string output) {
        try {
            var ncas = P.OpenNsp(keys, source);
            var records = new List<IdentityRecord>();
            int metaCount = 0;
            foreach (var nca in ncas) {
                if (nca.Header.ContentType != NcaContentType.Meta) continue;
                if (++metaCount > MaxRecords) throw new InvalidDataException("The container contains too many Meta NCAs.");
                using var fs = nca.OpenFileSystem(NcaSectionType.Data, IntegrityCheckLevel.ErrorOnInvalid);
                foreach (var entry in fs.EnumerateEntries("*", SearchOptions.Default)) {
                    if (entry.Type != DirectoryEntryType.File || !entry.Name.EndsWith(".cnmt", StringComparison.OrdinalIgnoreCase)) continue;
                    if (records.Count == MaxRecords || entry.Size < 0x20 || entry.Size > MaxMetadataBytes)
                        throw new InvalidDataException("The CNMT count or size exceeds the supported bounds.");
                    using var file = new UniqueRef<IFile>();
                    fs.OpenFile(ref file.Ref, entry.FullPath.ToU8Span(), OpenMode.Read).ThrowIfFailure();
                    var data = new byte[(int)entry.Size];
                    file.Get.Read(out long read, 0, data, ReadOption.None).ThrowIfFailure();
                    if (read != data.Length) throw new InvalidDataException("The CNMT data is truncated.");
                    var type = (ContentMetaType)data[0xc];
                    if (type == ContentMetaType.Application || type == ContentMetaType.Patch || type == ContentMetaType.AddOnContent) records.Add(Parse(data));
                }
            }
            var selected = Select(records);
            // The caller chooses a private, fresh output; never overwrite an existing path.
            using var stream = new FileStream(output, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            JsonSerializer.Serialize(stream, new { formatVersion = 1, records = selected });
            return 0;
        } catch (Exception error) {
            Console.Error.WriteLine("[RED] Container identification failed: " + error.Message);
            return 4;
        }
    }
}
