"""
Pure-Julia parser for `.ji` package image headers.

Replicates the logic from `_parse_cache_header` (base/loading.jl:3430)
and `read_module_list` (base/loading.jl:3416) without depending on Base internals.
"""

# ── Constants ───────────────────────────────────────────────

const JI_MAGIC = UInt8[0xfb, 0x6a, 0x6c, 0x69, 0x0d, 0x0a, 0x1a, 0x0a]  # "\373jli\r\n\032\n"
const JI_MAGIC_LEN = 8
const EXPECTED_BOM = 0xFEFF

# ── Internal helpers ────────────────────────────────────────

"""Read a null-terminated string from an IO stream."""
function _read_cstring(io::IO)
    buf = UInt8[]
    while !eof(io)
        b = read(io, UInt8)
        b == 0x00 && break
        push!(buf, b)
    end
    return String(buf)
end

"""
Read a module list in the format produced by `write_worklist_for_header`
(has_buildid_hi=false) or `write_mod_list` (has_buildid_hi=true).

Each entry: [namelen:Int32][name:bytes][uuid_hi:UInt64][uuid_lo:UInt64]
            [build_id_hi:UInt64 (if has_buildid_hi)][build_id_lo:UInt64]
Terminated by Int32(0).
"""
function _read_module_list(io::IO, has_buildid_hi::Bool)
    entries = []
    while true
        offset_before = position(io)
        n = read(io, Int32)
        n == 0 && break
        name = String(read(io, n))
        uuid_hi = read(io, UInt64)
        uuid_lo = read(io, UInt64)
        uuid = Base.UUID(UInt128(uuid_hi) << 64 | uuid_lo)

        if has_buildid_hi
            offset_hi = position(io)
            bid_hi = read(io, UInt64)
            offset_lo = position(io)
            bid_lo = read(io, UInt64)
            push!(entries, DepModEntry(name, uuid, bid_hi, bid_lo, offset_hi, offset_lo))
        else
            offset_lo = position(io)
            bid_lo = read(io, UInt64)
            push!(entries, WorklistEntry(name, uuid, bid_lo, offset_lo))
        end
    end
    return entries
end

# ── Public API ──────────────────────────────────────────────

"""
    parse_header(path::String) -> PkgImageHeader

Parse the header of a `.ji` or `.so` package image file.

For `.ji` files, reads the header directly from the file.
For `.so`/`.dylib`/`.dll` files (split images), loads the shared library via
`Libdl.dlopen`, locates the embedded JI header via `jl_image_pointers`, and
parses it from memory.

The parser replicates the binary format from:
- `write_header` (staticdata_utils.c:505-523)
- `jl_write_header_for_incremental` (staticdata.c:3465-3481)
- `read_module_list` (base/loading.jl:3416-3428)
- `_parse_cache_header` (base/loading.jl:3430-3491)

# Throws
- `ArgumentError` if the file is not a valid Julia package image
"""
function parse_header(path::String)
    if _is_shared_library(path)
        return _parse_so_header(path)
    end
    open(path, "r") do io
        return _parse_header_from_io(io, path)
    end
end

const _SO_EXTENSIONS = (".so", ".dylib", ".dll")

function _is_shared_library(path::String)
    lp = lowercase(path)
    return any(ext -> endswith(lp, ext), _SO_EXTENSIONS)
end

function _parse_so_header(path::String)
    # The .so embeds a JI header written by write_header(ff, 1) at staticdata.c:3530
    # followed by cache_flags and write_mod_list. It lives inside an ELF/MachO/PE
    # data section (jl_system_image_data). We locate it by scanning for the JI_MAGIC
    # signature with pkgimage=1.
    return _parse_so_header_by_scan(path)
end

function _parse_so_header_by_scan(path::String)
    # The .so's own JI header is written by write_header(ff, 1) at staticdata.c:3530
    # with pkgimage=1, followed by cache_flags and write_mod_list.
    # It also embeds the .ji data blob (which starts with pkgimage=0 header).
    # We need the .so's OWN header (pkgimage=1), not the embedded .ji data.
    data = read(path)

    # Scan for JI_MAGIC followed by valid format_version, BOM, and pkgimage=1
    offset = 1
    while true
        idx = _find_bytes(data, JI_MAGIC, offset)
        idx === nothing && throw(ArgumentError("No JI header (pkgimage=1) found in shared library: $path"))

        # Check: magic(8) + version(2) + bom(2) + ptrsize(1) = 13 bytes minimum after magic
        if idx + JI_MAGIC_LEN + 13 > length(data)
            offset = idx + 1
            continue
        end

        # Try parsing — if it's the right header (pkgimage=1), return it
        try
            io = IOBuffer(@view data[idx:end])
            hdr = _parse_header_from_io(io, path)
            if hdr.pkgimage
                # _parse_header_from_io recorded byte offsets via position(io),
                # which are RELATIVE to the IOBuffer view (i.e. to `idx`). Shift
                # them to ABSOLUTE file offsets so remap() patches the correct
                # bytes in the .so instead of clobbering the ELF/MachO headers.
                return _shift_header_offsets(hdr, idx - 1)
            end
        catch
            # Not a valid header at this offset — keep scanning
        end

        offset = idx + 1
    end
end

# Return a copy of `hdr` with all recorded file offsets shifted by `base`.
# Used to convert .so-relative offsets (parsed from an IOBuffer view) into
# absolute file offsets. (DepModEntry/WorklistEntry are immutable → rebuild.)
function _shift_header_offsets(hdr::PkgImageHeader, base::Int)
    base == 0 && return hdr
    wl = WorklistEntry[WorklistEntry(w.name, w.uuid, w.build_id_lo, w._file_offset + base)
                       for w in hdr.worklist]
    rm = DepModEntry[DepModEntry(d.name, d.uuid, d.build_id_hi, d.build_id_lo,
                                 d._file_offset_hi + base, d._file_offset_lo + base)
                     for d in hdr.required_modules]
    return PkgImageHeader(
        hdr.format_version, hdr.pointer_size, hdr.build_uname, hdr.build_arch,
        hdr.julia_version, hdr.git_branch, hdr.git_commit, hdr.pkgimage, hdr.checksum,
        hdr.data_start, hdr.data_end, hdr.cache_flags, wl, rm,
        hdr._deplist_start, hdr._deplist_end, hdr._path,
    )
end

function _find_bytes(haystack::Vector{UInt8}, needle::Vector{UInt8}, start::Int=1)
    nlen = length(needle)
    hlen = length(haystack)
    nlen > hlen && return nothing
    for i in start:(hlen - nlen + 1)
        match = true
        for j in 1:nlen
            if haystack[i + j - 1] != needle[j]
                match = false
                break
            end
        end
        match && return i
    end
    return nothing
end

function _parse_header_from_io(io::IO, path::String)
    # ── Section 0: Base header (write_header, staticdata_utils.c:505) ──

    magic = read(io, JI_MAGIC_LEN)
    if magic != JI_MAGIC
        throw(ArgumentError("Not a Julia .ji file: bad magic bytes in $path"))
    end

    format_version = read(io, UInt16)
    bom = read(io, UInt16)
    if bom != EXPECTED_BOM
        throw(ArgumentError("Bad byte-order marker in $path (expected 0x$(string(EXPECTED_BOM, base=16)), got 0x$(string(bom, base=16)))"))
    end

    pointer_size = read(io, UInt8)
    build_uname = _read_cstring(io)
    build_arch = _read_cstring(io)
    julia_version = _read_cstring(io)
    git_branch = _read_cstring(io)
    git_commit = _read_cstring(io)
    pkgimage_flag = read(io, UInt8)
    checksum = read(io, UInt64)
    data_start = read(io, Int64)
    data_end = read(io, Int64)

    # ── Section 1: Cache flags (staticdata.c:3468 / 3531) ──

    cache_flags = read(io, UInt8)

    # The .so split-image header (pkgimage=1) has a DIFFERENT, simpler format
    # than the .ji incremental header (pkgimage=0):
    #
    #   .ji (pkgimage=0):  base_header + cache_flags + worklist + deplist + mod_list
    #   .so (pkgimage=1):  base_header + cache_flags + mod_list
    #
    # See staticdata.c:3528-3532 for the split-image header vs 3465-3481 for .ji.

    worklist = WorklistEntry[]
    deplist_start = Int64(0)
    deplist_end = Int64(0)

    if pkgimage_flag == 0
        # ── .ji format: Sections 2-4 ──

        # Section 2: Worklist (write_worklist_for_header, staticdata_utils.c:531)
        worklist = _read_module_list(io, false)

        # Section 3: Dependency list (write_dependency_list, staticdata_utils.c:563)
        deplist_start = position(io)
        totbytes = read(io, UInt64)
        if totbytes > 0
            skip(io, totbytes)
        end
        deplist_end = position(io)
    end

    # Section 4 (.ji) / Section 2 (.so): Required modules (write_mod_list)
    required_modules = _read_module_list(io, true)

    return PkgImageHeader(
        format_version,
        pointer_size,
        build_uname,
        build_arch,
        julia_version,
        git_branch,
        git_commit,
        pkgimage_flag != 0,
        checksum,
        data_start,
        data_end,
        cache_flags,
        worklist,
        required_modules,
        deplist_start,
        deplist_end,
        path,
    )
end

"""
    inspect(path::String; io::IO=stdout)

Print a human-readable summary of a `.ji` file header.
"""
function inspect(path::String; io::IO=stdout)
    hdr = parse_header(path)
    inspect(hdr; io)
end

function inspect(hdr::PkgImageHeader; io::IO=stdout)
    println(io, "Julia Package Image Header")
    println(io, "==========================")
    println(io, "  File:            ", hdr._path)
    println(io, "  Format version:  ", hdr.format_version)
    println(io, "  Pointer size:    ", hdr.pointer_size)
    println(io, "  Julia version:   ", hdr.julia_version)
    println(io, "  Git:             ", hdr.git_branch, " @ ", hdr.git_commit)
    println(io, "  Platform:        ", hdr.build_uname, " / ", hdr.build_arch)
    println(io, "  Pkgimage:        ", hdr.pkgimage)
    println(io, "  Cache flags:     0x", string(hdr.cache_flags, base=16, pad=2))

    checksum_lo = UInt32(hdr.checksum & 0xFFFFFFFF)
    checksum_hi = UInt32((hdr.checksum >> 32) & 0xFFFFFFFF)
    println(io, "  Checksum:        0x", string(checksum_lo, base=16, pad=8),
            " (magic: 0x", string(checksum_hi, base=16, pad=8), ")")
    println(io, "  Data range:      ", hdr.data_start, " .. ", hdr.data_end,
            " (", hdr.data_end - hdr.data_start, " bytes)")

    println(io)
    println(io, "Worklist (", length(hdr.worklist), " modules):")
    for w in hdr.worklist
        println(io, "  ", w.name,
                " uuid=", w.uuid,
                " build_id.lo=0x", string(w.build_id_lo, base=16, pad=16))
    end

    println(io)
    println(io, "Required modules (", length(hdr.required_modules), " dependencies):")
    for d in hdr.required_modules
        bid = UInt128(d.build_id_hi) << 64 | d.build_id_lo
        println(io, "  ", d.name,
                " uuid=", d.uuid,
                " build_id=0x", string(bid, base=16, pad=32))
    end
end
