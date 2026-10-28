// Import selected data archives from a locally supplied firmware dump. No system executables or keys are retained.
using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using LibHac.Common;
using LibHac.Common.Keys;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.FsSystem;
using LibHac.Tools.Fs;
using LibHac.Tools.FsSystem;
using LibHac.Tools.FsSystem.NcaUtils;
using LibHac.Tools.FsSystem.RomFs;
using Path = System.IO.Path;

static class FirmwareResources {
    static readonly Dictionary<ulong,string> Wanted = new() {
        [0x0100000000000800]="CertStore",
        [0x0100000000000802]="MiiModel", [0x0100000000000809]="SystemVersion", [0x0100000000000805]="InputMethodDictionary",
        [0x0100000000000810]="FontNintendoExtension", [0x0100000000000811]="FontStandard", [0x0100000000000812]="FontKorean",
        [0x0100000000000813]="FontChineseTraditional", [0x0100000000000814]="FontChineseSimple"
    };
    record Source(string Name,string File,ZipArchiveEntry Entry,long Bytes);
    record ImportedFile(string path,long bytes,string sha256);
    record Resource(string titleId,string name,string relativePath,string contentSha256,long bytes,List<ImportedFile> files);
    static void Progress(string name,int done,int total,string message) => Console.WriteLine(JsonSerializer.Serialize(new {ev="progress",name,done,total,frac=total>0?(double)done/total:0,msg=message}));
    static bool NcaName(string path) {
        string normalized=path.Replace('\\','/').TrimEnd('/');
        return normalized.EndsWith(".nca",StringComparison.OrdinalIgnoreCase) ||
            Path.GetFileName(normalized)=="00" && (Path.GetDirectoryName(normalized) ?? "").EndsWith(".nca",StringComparison.OrdinalIgnoreCase);
    }
    static bool UnsafeName(string name) => name.Replace('\\','/').Split('/').Any(part=>part=="..") || name.StartsWith('/') || name.StartsWith('\\') || name.Contains(':');
    static string Hash(string path) { using var stream=File.OpenRead(path);return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant(); }
    public static int Import(KeySet keys,string source,string destination) {
        try { return Run(keys,source,destination); }
        catch(Exception error) { Console.Error.WriteLine("[RED] Firmware resource import failed: "+error.Message);return 4; }
    }
    static int Run(KeySet keys,string source,string destination) {
        destination=Path.GetFullPath(destination);
        if(Directory.Exists(destination) && Directory.EnumerateFileSystemEntries(destination).Any())throw new IOException("Choose an empty firmware import destination.");
        Directory.CreateDirectory(destination);
        string temporary=Path.Combine(destination,".source-staging");Directory.CreateDirectory(temporary);
        using ZipArchive zip=File.Exists(source) && Path.GetExtension(source).Equals(".zip",StringComparison.OrdinalIgnoreCase) ? ZipFile.OpenRead(source) : null;
        var sources=new List<Source>();
        if(zip!=null) {
            foreach(var entry in zip.Entries) {
                if(UnsafeName(entry.FullName))throw new IOException("The firmware ZIP contains an unsafe path.");
                if(entry.Name.Length==0 || !NcaName(entry.FullName))continue;
                if(entry.Length<0xc00 || entry.Length>4L*1024*1024*1024)throw new IOException("An NCA has an invalid file size.");
                sources.Add(new Source(entry.FullName,null,entry,entry.Length));
            }
        } else if(Directory.Exists(source)) {
            var options=new EnumerationOptions { RecurseSubdirectories=true,AttributesToSkip=FileAttributes.ReparsePoint,IgnoreInaccessible=false };
            foreach(string file in Directory.EnumerateFiles(source,"*",options).Where(NcaName).OrderBy(x=>x,StringComparer.Ordinal)) {
                var info=new FileInfo(file);if(info.Length<0xc00)throw new IOException("An NCA is incomplete: "+info.Name);
                sources.Add(new Source(Path.GetRelativePath(source,file),file,null,info.Length));
            }
        } else throw new IOException("Choose a firmware directory or ZIP file.");
        if(sources.Count==0)throw new IOException("The selected source contains no firmware NCAs.");
        var resources=new List<Resource>();var seen=new Dictionary<ulong,string>();string version=null;int scanned=0;
        try {
            foreach(Source input in sources) {
                scanned++;string file=input.File;
                if(input.Entry!=null) { file=Path.Combine(temporary,scanned+".nca");input.Entry.ExtractToFile(file,false); }
                Progress("Inspecting firmware",scanned,sources.Count,"Inspecting archive "+scanned+" of "+sources.Count);
                using(var storage=new LocalStorage(file,FileAccess.Read)) {
                    var nca=new Nca(keys,storage);ulong id=nca.Header.TitleId;
                    if(Wanted.TryGetValue(id,out string name) && (nca.Header.ContentType==NcaContentType.Data || nca.Header.ContentType==NcaContentType.PublicData)) {
                        string sha=Hash(file);
                        if(seen.TryGetValue(id,out string existing)) { if(existing!=sha)throw new IOException("The source contains conflicting versions of "+name+". Use one complete firmware dump."); }
                        else {
                            seen[id]=sha;string idText=id.ToString("x16"),relative="system_data/"+idText+"/files",folder=Path.Combine(destination,relative);
                            var fs=new RomFsFileSystem(nca.OpenStorage(NcaSectionType.Data,IntegrityCheckLevel.ErrorOnInvalid));
                            var files=Copy(fs,folder);long bytes=files.Sum(x=>x.bytes);
                            resources.Add(new Resource(idText,name,relative,sha,bytes,files));
                            Console.WriteLine(JsonSerializer.Serialize(new {ev="say",msg="Validated "+name+": "+files.Count+" files"}));
                            if(id==0x0100000000000809)version=ReadVersion(folder);
                        }
                    }
                }
                if(input.Entry!=null)File.Delete(file);
            }
            if(version==null)throw new IOException("SystemVersion (0100000000000809) is missing or invalid; the firmware version could not be verified.");
            Resource mii=resources.FirstOrDefault(x=>x.titleId=="0100000000000802");
            if(mii==null)throw new IOException("MiiModel (0100000000000802) is missing from this firmware dump.");
            string[] miiFiles={"NXTextureLowLinear.dat","NXTextureLowSRGB.dat","NXTextureMidLinear.dat","NXTextureMidSRGB.dat","ShapeMid.dat","ShapeHigh.dat"};
            foreach(string required in miiFiles)if(!mii.files.Any(f=>Path.GetFileName(f.path)==required && f.bytes>0))throw new IOException("MiiModel is incomplete: "+required+" is missing.");
            Resource certStore=resources.FirstOrDefault(x=>x.titleId=="0100000000000800");
            if(certStore==null)throw new IOException("CertStore (0100000000000800) is missing from this firmware dump.");
            ValidateCertStore(Path.Combine(destination,certStore.relativePath,"ssl_TrustedCerts.bdf"));
            resources.Sort((a,b)=>StringComparer.Ordinal.Compare(a.titleId,b.titleId));
            string digest=Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(string.Join("\n",resources.Select(x=>x.titleId+":"+x.contentSha256))))).ToLowerInvariant();
            var catalog=new {formatVersion=1,firmwareVersion=version,contentDigest=digest,importedAt=DateTimeOffset.UtcNow.ToString("O"),sourceKind=zip==null?"directory":"zip",archiveCount=sources.Count,resources};
            File.WriteAllText(Path.Combine(destination,"manifest.json"),JsonSerializer.Serialize(catalog,new JsonSerializerOptions{WriteIndented=true}));
            Progress("Firmware resources imported",sources.Count,sources.Count,"Firmware "+version+" validated; "+resources.Count+" resource archives imported.");
            return 0;
        } finally { if(Directory.Exists(temporary))Directory.Delete(temporary,true); }
    }
    static string ReadVersion(string directory) {
        string path=Path.Combine(directory,"file");if(!File.Exists(path))throw new IOException("SystemVersion has no version file.");
        byte[] bytes=File.ReadAllBytes(path);if(bytes.Length<0x80)throw new IOException("SystemVersion is truncated.");
        string numeric=$"{bytes[0]}.{bytes[1]}.{bytes[2]}",display=Encoding.ASCII.GetString(bytes,0x68,0x18).TrimEnd('\0');
        if(!display.StartsWith(numeric,StringComparison.Ordinal))throw new IOException("SystemVersion fields disagree.");
        return numeric;
    }
    static void ValidateCertStore(string path) {
        // Original firmware CertStore: sslT, entry count, then 16-byte LE
        // {id,status,size,offset} records. Offsets are relative to byte 8.
        // Keep this archive as data; importing it never installs trust anchors.
        if(!File.Exists(path))throw new IOException("CertStore is incomplete: ssl_TrustedCerts.bdf is missing.");
        using var file=File.OpenRead(path);Span<byte> header=stackalloc byte[8];
        if(file.Length<8)throw new IOException("CertStore has a truncated certificate table.");
        file.ReadExactly(header);
        if(header[0]!='s' || header[1]!='s' || header[2]!='l' || header[3]!='T')throw new IOException("CertStore has an invalid certificate table header.");
        uint count=BinaryPrimitives.ReadUInt32LittleEndian(header[4..]);long tableEnd=8L+16L*count;
        if(count==0 || tableEnd>file.Length)throw new IOException("CertStore has an invalid certificate table size.");
        Span<byte> entry=stackalloc byte[16];var ids=new HashSet<uint>();
        for(uint i=0;i<count;i++) {
            file.ReadExactly(entry);uint id=BinaryPrimitives.ReadUInt32LittleEndian(entry);
            uint size=BinaryPrimitives.ReadUInt32LittleEndian(entry[8..]),offset=BinaryPrimitives.ReadUInt32LittleEndian(entry[12..]);
            long start=8L+offset;
            if(!ids.Add(id) || size==0 || start<tableEnd || start+size>file.Length)throw new IOException("CertStore has an invalid certificate table entry.");
        }
    }
    static List<ImportedFile> Copy(IFileSystem fs,string destination) {
        var files=new List<ImportedFile>();byte[] buffer=new byte[1024*1024];
        foreach(DirectoryEntryEx entry in fs.EnumerateEntries("*",SearchOptions.RecurseSubdirectories)) {
            string relative=entry.FullPath.TrimStart('/');if(UnsafeName(relative))throw new IOException("The data archive contains an unsafe path.");
            string path=Path.Combine(destination,relative);
            if(entry.Type==DirectoryEntryType.Directory){Directory.CreateDirectory(path);continue;}
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            using var input=new UniqueRef<IFile>();fs.OpenFile(ref input.Ref,entry.FullPath.ToU8Span(),OpenMode.Read).ThrowIfFailure();
            using(var output=File.Create(path))for(long offset=0;offset<entry.Size;) {
                input.Get.Read(out long got,offset,buffer.AsSpan(0,(int)Math.Min(buffer.Length,entry.Size-offset)),ReadOption.None).ThrowIfFailure();
                if(got<=0)throw new IOException("A system data file is truncated.");output.Write(buffer,0,(int)got);offset+=got;
            }
            files.Add(new ImportedFile(relative,entry.Size,Hash(path)));
        }
        files.Sort((a,b)=>StringComparer.Ordinal.Compare(a.path,b.path));return files;
    }
}
