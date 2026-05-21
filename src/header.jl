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

Parse the header of a `.ji` package image file. Does not read the data blob.

The parser replicates the binary format from:
- `write_header` (staticdata_utils.c:505-523)
- `jl_write_header_for_incremental` (staticdata.c:3465-3481)
- `read_module_list` (base/loading.jl:3416-3428)
- `_parse_cache_header` (base/loading.jl:3430-3491)

# Throws
- `ArgumentError` if the file is not a valid `.ji` file
"""
function parse_header(path::String)
    open(path, "r") do io
        return _parse_header_from_io(io, path)
    end
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

    # ── Section 1: Cache flags (staticdata.c:3468) ──

    cache_flags = read(io, UInt8)

    # ── Section 2: Worklist (write_worklist_for_header, staticdata_utils.c:531) ──

    worklist = _read_module_list(io, false)

    # ── Section 3: Dependency list (write_dependency_list, staticdata_utils.c:563) ──
    # This section has variable format. The Julia-side parser reads totbytes
    # to know how much to skip. We read totbytes, then skip that many bytes
    # minus the 8 bytes we already read for totbytes itself.

    deplist_start = position(io)
    totbytes = read(io, UInt64)
    # totbytes counts from after itself to the end of the dependency list section
    # (includes file records, requires, preferences)
    if totbytes > 0
        skip(io, totbytes)
    end
    deplist_end = position(io)

    # ── Section 4: Required modules (write_mod_list, staticdata_utils.c:409) ──

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
