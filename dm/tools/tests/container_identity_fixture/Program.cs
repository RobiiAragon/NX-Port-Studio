// Synthetic metadata only. No game files, console keys or Nintendo binaries.
using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using LibHac.Ncm;

static class IdentityTests {
    const ulong App = 0x0100000000001000;
    static int checks;
    static void Check(bool value) { checks++; if (!value) throw new Exception("Synthetic container identity check failed: " + checks); }
    static void Reject(Action action) {
        checks++;
        try { action(); } catch (InvalidDataException) { return; }
        throw new Exception("Expected metadata rejection: " + checks);
    }
    static byte[] Metadata(ContentMetaType kind, ulong title, uint version = 0, ulong application = App, int? extendedBytes = null) {
        int extended = extendedBytes ?? (kind == ContentMetaType.Patch ? 0x18 : 0x10);
        var bytes = new byte[0x20 + extended + 0x38 + 0x20];
        BinaryPrimitives.WriteUInt64LittleEndian(bytes, title);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(8), version);
        bytes[0xc] = (byte)kind;
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(0xe), (ushort)extended);
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(0x10), 1);
        BinaryPrimitives.WriteUInt64LittleEndian(bytes.AsSpan(0x20), application);
        return bytes;
    }
    static int Main() {
        var baseRecord = ContainerIdentity.Parse(Metadata(ContentMetaType.Application, App));
        Check(baseRecord.titleId == "0100000000001000");
        Check(baseRecord.applicationTitleId == baseRecord.titleId);
        Check(baseRecord.type == "Application" && baseRecord.version == 0);
        var patch = ContainerIdentity.Parse(Metadata(ContentMetaType.Patch, App + 0x800, 393216));
        Check(patch.titleId == "0100000000001800");
        Check(patch.applicationTitleId == baseRecord.titleId && patch.type == "Patch" && patch.version == 393216);
        var addon = ContainerIdentity.Parse(Metadata(ContentMetaType.AddOnContent, App + 0x1001, 65536));
        Check(addon.applicationTitleId == baseRecord.titleId && addon.type == "AddOnContent" && addon.version == 65536);
        Check(ContainerIdentity.Parse(Metadata(ContentMetaType.AddOnContent, App + 0x1001, extendedBytes: 0x18)) == addon with { version = 0 });
        Reject(() => ContainerIdentity.Parse(new byte[0x1f]));
        Reject(() => ContainerIdentity.Parse(new byte[ContainerIdentity.MaxMetadataBytes + 1]));
        Reject(() => ContainerIdentity.Parse(Metadata(ContentMetaType.SystemData, App)));
        Reject(() => ContainerIdentity.Parse(Metadata(ContentMetaType.Application, 0)));
        Reject(() => ContainerIdentity.Parse(Metadata(ContentMetaType.Patch, App + 0x800, application: 0)));
        Reject(() => ContainerIdentity.Parse(Metadata(ContentMetaType.Patch, App + 0x800, extendedBytes: 0x10)));
        var platform = Metadata(ContentMetaType.Application, App); platform[0xd] = 1;
        Reject(() => ContainerIdentity.Parse(platform));
        var truncated = Metadata(ContentMetaType.Application, App);
        Reject(() => ContainerIdentity.Parse(truncated.AsSpan(0, truncated.Length - 1)));
        var hugeTable = Metadata(ContentMetaType.Application, App);
        BinaryPrimitives.WriteUInt16LittleEndian(hugeTable.AsSpan(0x10), 4097);
        Reject(() => ContainerIdentity.Parse(hugeTable));
        var hugeMetaTable = Metadata(ContentMetaType.Application, App);
        BinaryPrimitives.WriteUInt16LittleEndian(hugeMetaTable.AsSpan(0x12), 4097);
        Reject(() => ContainerIdentity.Parse(hugeMetaTable));
        var hugeExtended = Metadata(ContentMetaType.Patch, App + 0x800);
        BinaryPrimitives.WriteUInt32LittleEndian(hugeExtended.AsSpan(0x2c), uint.MaxValue);
        Reject(() => ContainerIdentity.Parse(hugeExtended));
        Check(ContainerIdentity.Select(new[] { baseRecord, baseRecord }).Length == 1);
        Check(ContainerIdentity.Select(new[] { patch, baseRecord }).SequenceEqual(new[] { baseRecord, patch }));
        Check(ContainerIdentity.Select(new[] { baseRecord, patch, addon }).Length == 3);
        Reject(() => ContainerIdentity.Select(Array.Empty<ContainerIdentity.IdentityRecord>()));
        Reject(() => ContainerIdentity.Select(new[] { baseRecord, baseRecord with { applicationTitleId = "0100000000002000", titleId = "0100000000002000" } }));
        Reject(() => ContainerIdentity.Select(new[] { patch, patch with { version = 65536 } }));
        Reject(() => ContainerIdentity.Select(Enumerable.Repeat(baseRecord, ContainerIdentity.MaxRecords + 1)));
        var json = JsonSerializer.Serialize(new { formatVersion = 1, records = ContainerIdentity.Select(new[] { baseRecord, patch }) });
        using var document = JsonDocument.Parse(json);
        Check(document.RootElement.GetProperty("formatVersion").GetInt32() == 1);
        Check(document.RootElement.GetProperty("records")[1].GetProperty("version").GetUInt32() == 393216);
        Check(document.RootElement.GetProperty("records")[1].GetProperty("type").GetString() == "Patch");
        Console.WriteLine($"Container identity: {checks} synthetic checks passed.");
        return 0;
    }
}
