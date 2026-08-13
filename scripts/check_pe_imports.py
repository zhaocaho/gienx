#!/usr/bin/env python3
"""Check PE import tables for API symbols that need newer Windows versions.

The main Win7 risk is a static import whose symbol is not present in the
Windows 7 DLL: the loader refuses to start the process before any Rust code
can run. This script parses the PE import directory and reports any imports
from the deny list below.

Usage:
  python scripts/check_pe_imports.py path/to/gienx.exe [more.exe ...]
  python scripts/check_pe_imports.py --all path/to/gienx.exe
"""

import argparse
import pathlib
import struct
import sys


# Functions introduced after Windows 7 SP1. The list is intentionally
# conservative: add entries as the Win7 audit finds them.
WIN7_DENY_SYMBOLS = {
    "CreateAppContainerProfile",
    "CreateFile2",
    "CreatePseudoConsole",
    "ClosePseudoConsole",
    "DeriveAppContainerSidFromAppContainerName",
    "GetAppContainerNamedObjectPath",
    "GetCurrentPackageFullName",
    "GetProcessInformation",
    "GetProcessMitigationPolicy",
    "GetSystemCpuSetInformation",
    "GetSystemTimePreciseAsFileTime",
    "GetTempPath2W",
    "GetThreadDescription",
    "IsWow64Process2",
    "PathCchCanonicalizeEx",
    "PathCchCombineEx",
    "PathCchRemoveFileSpec",
    "ResizePseudoConsole",
    "SetProcessInformation",
    "SetProcessMitigationPolicy",
    "SetThreadDescription",
}


def read_u16(data: bytes, off: int) -> int:
    return struct.unpack_from("<H", data, off)[0]


def read_u32(data: bytes, off: int) -> int:
    return struct.unpack_from("<I", data, off)[0]


def read_u64(data: bytes, off: int) -> int:
    return struct.unpack_from("<Q", data, off)[0]


def read_c_string(data: bytes, off: int) -> str:
    end = data.find(b"\x00", off)
    if end < 0:
        end = len(data)
    return data[off:end].decode("utf-8", "replace")


def parse_sections(data: bytes, coff_off: int, opt_size: int, num_sections: int):
    sections = []
    start = coff_off + 20 + opt_size
    for index in range(num_sections):
        off = start + index * 40
        name = data[off : off + 8].rstrip(b"\x00").decode("ascii", "replace")
        virtual_size, virtual_address, raw_size, raw_pointer = struct.unpack_from(
            "<IIII", data, off + 8
        )
        sections.append(
            (name, virtual_address, virtual_size, raw_size, raw_pointer)
        )
    return sections


def rva_to_file_offset(data: bytes, sections, rva: int):
    for name, virtual_address, virtual_size, raw_size, raw_pointer in sections:
        mapped_size = max(virtual_size, raw_size)
        if virtual_address <= rva < virtual_address + mapped_size:
            delta = rva - virtual_address
            if delta < raw_size:
                return raw_pointer + delta
    return None


def parse_imports(data: bytes):
    if len(data) < 0x40:
        raise ValueError("not a PE file (too small)")

    pe_offset = read_u32(data, 0x3C)
    if data[pe_offset : pe_offset + 4] != b"PE\x00\x00":
        raise ValueError("not a PE file (bad signature)")

    coff_off = pe_offset + 4
    num_sections = read_u16(data, coff_off + 2)
    opt_size = read_u16(data, coff_off + 16)
    optional_off = coff_off + 20
    magic = read_u16(data, optional_off)
    if magic == 0x10B:
        is_64 = False
        data_directory_off = optional_off + 96
    elif magic == 0x20B:
        is_64 = True
        data_directory_off = optional_off + 112
    else:
        raise ValueError(f"unsupported PE optional header magic 0x{magic:04x}")

    sections = parse_sections(data, coff_off, opt_size, num_sections)
    import_rva, _import_size = read_u32(data, data_directory_off + 8), read_u32(
        data, data_directory_off + 12
    )
    import_off = rva_to_file_offset(data, sections, import_rva)
    if import_off is None:
        return {}

    imports = {}
    cursor = import_off
    while cursor + 20 <= len(data):
        original_thunk, _, _, name_rva, first_thunk = struct.unpack_from(
            "<IIIII", data, cursor
        )
        if original_thunk == 0 and first_thunk == 0 and name_rva == 0:
            break

        dll_off = rva_to_file_offset(data, sections, name_rva)
        dll_name = read_c_string(data, dll_off) if dll_off is not None else "?"

        thunk_rva = original_thunk or first_thunk
        thunk_off = rva_to_file_offset(data, sections, thunk_rva)
        functions = []
        if thunk_off is not None:
            while True:
                if is_64:
                    if thunk_off + 8 > len(data):
                        break
                    entry = read_u64(data, thunk_off)
                    thunk_off += 8
                    if entry == 0:
                        break
                    if entry & 0x8000000000000000:
                        functions.append(f"#{entry & 0xFFFF}")
                        continue
                    name_ptr = rva_to_file_offset(
                        data, sections, entry & 0x7FFFFFFFFFFFFFFF
                    )
                else:
                    if thunk_off + 4 > len(data):
                        break
                    entry = read_u32(data, thunk_off)
                    thunk_off += 4
                    if entry == 0:
                        break
                    if entry & 0x80000000:
                        functions.append(f"#{entry & 0xFFFF}")
                        continue
                    name_ptr = rva_to_file_offset(
                        data, sections, entry & 0x7FFFFFFF
                    )

                if name_ptr is None or name_ptr + 2 > len(data):
                    functions.append("?")
                else:
                    functions.append(read_c_string(data, name_ptr + 2))

        imports[dll_name] = sorted(set(functions))
        cursor += 20

    return imports


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", help="PE files to inspect")
    parser.add_argument(
        "--all",
        action="store_true",
        help="print the full import table in addition to deny-list hits",
    )
    args = parser.parse_args(argv)

    deny = set(WIN7_DENY_SYMBOLS)
    found_any = False
    for raw_path in args.paths:
        path = pathlib.Path(raw_path)
        if not path.is_file():
            print(f"missing: {path}", file=sys.stderr)
            found_any = True
            continue

        try:
            imports = parse_imports(path.read_bytes())
        except ValueError as err:
            print(f"{path}: parse error: {err}", file=sys.stderr)
            found_any = True
            continue

        hits = []
        for dll, functions in sorted(imports.items()):
            for function in functions:
                if function in deny:
                    hits.append((dll, function))

        print(path)
        if args.all:
            for dll, functions in sorted(imports.items()):
                print(f"  {dll}")
                for function in functions:
                    print(f"    {function}")
        if hits:
            found_any = True
            for dll, function in sorted(hits):
                print(f"  DENY: {dll}!{function}")
        else:
            print("  OK: no deny-listed imports found")

    if found_any:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
