param([string] $Cargo = 'cargo')

$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    & $Cargo build --release --bin VoltDeck
    if ($LASTEXITCODE -ne 0) { throw 'Der Rust-Build ist fehlgeschlagen.' }

    if (-not ('VoltDeckResources' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class VoltDeckResources {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr BeginUpdateResource(string path, bool deleteExisting);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool UpdateResource(IntPtr handle, IntPtr type, IntPtr name,
                                               ushort language, byte[] data, uint size);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool EndUpdateResource(IntPtr handle, bool discard);

    public static void Apply(string exe, string ico, Version version, string productVersion) {
        var bytes = File.ReadAllBytes(ico);
        using (var source = new BinaryReader(new MemoryStream(bytes)))
        using (var group = new BinaryWriter(new MemoryStream())) {
            if (source.ReadUInt16() != 0 || source.ReadUInt16() != 1)
                throw new InvalidDataException("Expected an ICO file.");
            ushort count = source.ReadUInt16();
            group.Write((ushort)0);
            group.Write((ushort)1);
            group.Write(count);

            IntPtr handle = BeginUpdateResource(exe, false);
            if (handle == IntPtr.Zero) throw new Win32Exception();
            bool ready = false;
            try {
                for (int index = 0; index < count; index++) {
                    group.Write(source.ReadBytes(8));
                    int size = source.ReadInt32();
                    int offset = source.ReadInt32();
                    byte[] image = new byte[size];
                    Array.Copy(bytes, offset, image, 0, size);
                    ushort id = (ushort)(index + 1);
                    group.Write(size);
                    group.Write(id);
                    Put(handle, 3, id, image);
                }
                Put(handle, 14, 1, ((MemoryStream)group.BaseStream).ToArray());
                Put(handle, 16, 1, VersionInfo(version, productVersion));
                ready = true;
            } finally {
                if (!EndUpdateResource(handle, !ready) && ready) throw new Win32Exception();
            }
        }
    }

    private static void Put(IntPtr handle, int type, int id, byte[] data) {
        if (!UpdateResource(handle, (IntPtr)type, (IntPtr)id, 0, data, (uint)data.Length))
            throw new Win32Exception();
    }

    private static byte[] VersionInfo(Version version, string productVersion) {
        string number = version.ToString(3);
        uint majorMinor = ((uint)version.Major << 16) | (uint)version.Minor;
        uint buildRevision = (uint)version.Build << 16;
        byte[] fixedInfo = Bytes(0xFEEF04BD, 0x00010000, majorMinor, buildRevision, majorMinor,
                                 buildRevision, 0x3F, 0, 0x00040004, 1, 0, 0, 0);
        return Block("VS_VERSION_INFO", false, fixedInfo,
            Block("StringFileInfo", true, new byte[0],
                Block("040904B0", true, new byte[0],
                    Text("CompanyName", "Lokicraft"), Text("FileDescription", "VoltDeck"),
                    Text("FileVersion", number), Text("OriginalFilename", "VoltDeck.exe"),
                    Text("ProductName", "VoltDeck"), Text("ProductVersion", productVersion))),
            Block("VarFileInfo", true, new byte[0], Block("Translation", false, Bytes(0x04B00409))));
    }

    private static byte[] Bytes(params uint[] values) {
        using (var writer = new BinaryWriter(new MemoryStream())) {
            foreach (uint value in values) writer.Write(value);
            return ((MemoryStream)writer.BaseStream).ToArray();
        }
    }

    private static byte[] Text(string key, string text) {
        return Block(key, true, Encoding.Unicode.GetBytes(text + '\0'));
    }

    private static byte[] Block(string key, bool text, byte[] value, params byte[][] children) {
        using (var writer = new BinaryWriter(new MemoryStream())) {
            writer.Write((ushort)0);
            writer.Write((ushort)(text ? value.Length / 2 : value.Length));
            writer.Write((ushort)(text ? 1 : 0));
            writer.Write(Encoding.Unicode.GetBytes(key + '\0'));
            Align(writer);
            writer.Write(value);
            foreach (byte[] child in children) {
                Align(writer);
                writer.Write(child);
            }
            ushort length = (ushort)writer.BaseStream.Length;
            writer.BaseStream.Position = 0;
            writer.Write(length);
            return ((MemoryStream)writer.BaseStream).ToArray();
        }
    }

    private static void Align(BinaryWriter writer) {
        while (writer.BaseStream.Position % 4 != 0) writer.Write((byte)0);
    }
}
'@
    }
    $exe = (Resolve-Path '.\target\release\VoltDeck.exe').Path
    $ico = (Resolve-Path '.\assets\VoltDeck.ico').Path
    $versionLine = Select-String -LiteralPath '.\Cargo.toml' -Pattern '^version\s*=\s*"((\d+\.\d+\.\d+)(?:-[A-Za-z0-9.-]+)?)"' | Select-Object -First 1
    if (-not $versionLine) { throw 'Die Paketversion konnte nicht aus Cargo.toml gelesen werden.' }
    $parts = $versionLine.Matches[0].Groups
    [VoltDeckResources]::Apply($exe, $ico, [version] $parts[2].Value, $parts[1].Value)
    Write-Output $exe
} finally {
    Pop-Location
}
