"""
Identity stamping and pre-load verification for `.ji`/`.so` package images.

`stamp_identity!` rewrites a module's own build-id *nonce* (`build_id.lo`) to a
caller-chosen value at every byte occurrence and, by default, recomputes the
CRC32C checksum so the image stays self-consistent and loadable. Unlike
`remap`, which patches *dependency* build-ids in the header (outside the CRC
range), the nonce lives in the serialized data blob, so changing it requires a
CRC recompute — the C restore path verifies the CRC (staticdata.c:4425), and a
stale checksum fails with "Error reading package image file."

`dry_verify` parses a header and sanity-checks it (worklist resolvable, CRC
self-consistent) *without loading*, so callers get a clean report instead of a
segfault or a cryptic C-level error.
"""

# ── Internal: physical layout of a package image header ─────────────
#
# Returns file-absolute offsets. For a `.ji` the embedded JI header starts at
# byte 0; for a split `.so` it starts at the `jl_system_image_data` symbol,
# which we locate by scanning for the pkgimage=1 JI_MAGIC. `data_start`/
# `data_end` in the header are relative to that image start, so the CRC-covered
# file range is `[magic_base + data_start, magic_base + data_end)`.
function _image_layout(path::String)
    data = read(path)
    idx = _is_shared_library(path) ? _find_pkgimage_magic(data) : 1
    base = idx - 1
    io = IOBuffer(@view data[idx:end])
    read(io, JI_MAGIC_LEN); read(io, UInt16); read(io, UInt16); read(io, UInt8)
    for _ in 1:5
        _read_cstring(io)
    end
    read(io, UInt8)                       # pkgimage flag
    checksum_off = base + position(io)    # file offset of the 8-byte checksum field
    checksum = read(io, UInt64)
    data_start = read(io, Int64)
    data_end = read(io, Int64)
    return (magic_base = base,
            checksum_off = checksum_off,
            checksum = checksum,
            data_start_file = base + data_start,
            data_end_file = base + data_end,
            has_data = data_end > data_start)
end

# Locate the first JI_MAGIC in a shared library whose header is a pkgimage
# (pkgimage flag != 0). Mirrors `_parse_so_header_by_scan`'s guard: fully parse
# each candidate and skip ones that do not validate.
function _find_pkgimage_magic(data::Vector{UInt8})
    offset = 1
    while true
        idx = _find_bytes(data, JI_MAGIC, offset)
        idx === nothing && throw(ArgumentError("no pkgimage (pkgimage=1) JI header found in shared library"))
        if idx + JI_MAGIC_LEN + 13 <= length(data)
            try
                io = IOBuffer(@view data[idx:end])
                hdr = _parse_header_from_io(io, "<scan>")
                hdr.pkgimage && return idx
            catch
                # not a valid header here — keep scanning
            end
        end
        offset = idx + 1
    end
end

# All little-endian 8-byte occurrences of `val` (byte-granular, unaligned).
function _find_u64(bytes::Vector{UInt8}, val::UInt64)
    tgt = reinterpret(UInt8, [val])
    offs = Int[]
    i = 1
    n = length(bytes)
    while i <= n - 7
        if @views bytes[i:i+7] == tgt
            push!(offs, i)
        end
        i += 1
    end
    return offs
end

# Current module nonce (build_id.lo) from the worklist-bearing header. For a
# split `.so` the worklist lives in the companion `.ji`.
function _current_nonce(ji::Union{String,Nothing}, so::Union{String,Nothing})
    for f in (ji, so)
        f === nothing && continue
        h = parse_header(f)
        isempty(h.worklist) || return h.worklist[end].build_id_lo
    end
    error("stamp_identity!: cannot determine the current build_id.lo — no worklist found " *
          "(a split .so needs its companion .ji present)")
end

# Resolve the split pair for a given image path (either half may be missing).
function _split_pair(path::String)
    stem = splitext(path)[1]
    ji = isfile(stem * ".ji") ? stem * ".ji" : nothing
    so = nothing
    for ext in _SO_EXTENSIONS
        cand = stem * ext
        if isfile(cand)
            so = cand
            break
        end
    end
    return ji, so
end

# Replace every occurrence of `old_lo` with `new_lo` in `f`; when `self_crc`
# and the file carries a data blob, recompute + write the self-consistent
# checksum. Returns the new checksum (or `nothing` if none was written).
function _stamp_file!(f::String, old_lo::UInt64, new_lo::UInt64; self_crc::Bool)
    bytes = read(f)
    for o in _find_u64(bytes, old_lo)
        bytes[o:o+7] .= reinterpret(UInt8, [new_lo])
    end
    lay = _image_layout(f)
    newck = nothing
    if self_crc && lay.has_data
        crc = crc32c(@view bytes[(lay.data_start_file + 1):lay.data_end_file])
        newck = (UInt64(0xfafbfcfd) << 32) | UInt64(crc)
        bytes[(lay.checksum_off + 1):(lay.checksum_off + 8)] .= reinterpret(UInt8, [newck])
    end
    write(f, bytes)
    return newck
end

function _write_checksum!(f::String, off::Int, checksum::UInt64)
    open(f, "r+") do io
        seek(io, off)
        write(io, checksum)
    end
    return checksum
end

# Rewrite the two trailer CRCs at the tail of a `.ji` so a stamped pair still
# passes Base's `stale_cachefile`/`isprecompiled` validation (base/loading.jl:
# `isvalid_file_crc` + `isvalid_pkgimage_crc`, v1.12.6:3358-3365):
#
#   [ ... ][ crc_so : UInt32 @ end-8 ][ crc_ji : UInt32 @ end-4 ]
#
#   crc_so = crc32c(whole `.so`)          — validated by `isvalid_pkgimage_crc`
#   crc_ji = crc32c(`.ji` bytes 1:end-4)  — validated by `isvalid_file_crc`
#
# Order matters: `crc_so` sits inside the `crc_ji` range, so it is written first.
# `crc_so` is only present/checked for split images; when `so === nothing`
# (a non-split `.ji`) only `crc_ji` is rewritten. Must run LAST, after every
# other byte edit to the pair (nonce, embedded header checksum) is final.
function _rewrite_ji_trailer!(ji::String, so::Union{String,Nothing})
    jb = read(ji)
    n = length(jb)
    n >= 8 || return nothing   # too small to carry a trailer; nothing to do
    if so !== nothing
        crc_so = crc32c(read(so))
        jb[(n - 7):(n - 4)] .= reinterpret(UInt8, [crc_so])
    end
    crc_ji = crc32c(@view jb[1:(n - 4)])
    jb[(n - 3):n] .= reinterpret(UInt8, [crc_ji])
    write(ji, jb)
    return (; crc_so = so === nothing ? nothing : reinterpret(UInt32, jb[(n - 7):(n - 4)])[1],
              crc_ji = crc_ji)
end

# ── Public API ──────────────────────────────────────────────

"""
    stamp_identity!(path::String; build_id_lo::UInt64, self_crc::Bool=true)

Rewrite a package image's own build-id nonce (`build_id.lo`) to `build_id_lo`,
in place, at every byte occurrence, and (by default) recompute the CRC32C
checksum so the image remains self-consistent and loadable.

Handles both layouts:
- **non-split `.ji`** (built with `--pkgimages=no`): the nonce appears in the
  worklist header field *and* in the data blob; both are rewritten and the
  `.ji`'s own CRC is recomputed.
- **split `.ji`+`.so`**: the nonce lives in the `.so` data blob (the `.so`
  header has no worklist). The `.so` is rewritten and its CRC recomputed; the
  companion `.ji`'s worklist field is rewritten too and its checksum mirrored
  from the `.so`, so both headers agree (as the builder writes them).

In both cases the `.ji`'s two **trailer CRCs** are also rewritten (whole-`.so`
CRC + `.ji`-self CRC, at the file tail — see `isvalid_file_crc` /
`isvalid_pkgimage_crc`, base/loading.jl:3358-3365 @ v1.12.6). JSD's own loader
bypasses these, but rewriting them keeps a stamped pair valid under Base's
`stale_cachefile`/`isprecompiled` path, so a depot-resident stamped image is not
seen as stale by ordinary `using`/`import`.

Pass either half of a split pair; the sibling is found automatically. With
`self_crc=false` no checksum is recomputed and the trailer is left untouched —
useful only for constructing a deliberately-stale image (which the loader will
reject).

Returns `(; build_id_lo, checksum, ji, so)` where `checksum` is the new
self-consistent 64-bit header checksum (or `nothing` if `self_crc=false`).

!!! note
    This changes the module's *identity*. A consumer image that recorded the
    old identity must be updated with [`remap!`](@ref) to the new build-id
    (`checksum` as hi, `build_id_lo` as lo) before it will load against the
    stamped image.
"""
function stamp_identity!(path::String; build_id_lo::UInt64, self_crc::Bool=true)
    ji, so = _split_pair(path)
    # If neither companion resolved (e.g. odd extension), operate on `path`.
    if ji === nothing && so === nothing
        _is_shared_library(path) ? (so = path) : (ji = path)
    end
    old_lo = _current_nonce(ji, so)
    old_lo == build_id_lo && @warn "stamp_identity!: build_id_lo unchanged (0x$(string(build_id_lo, base=16)))"

    datafile = so !== nothing ? so : ji
    metafile = (so !== nothing && ji !== nothing) ? ji : nothing   # split .ji, if any

    newck = _stamp_file!(datafile, old_lo, build_id_lo; self_crc=self_crc)

    if metafile !== nothing
        _stamp_file!(metafile, old_lo, build_id_lo; self_crc=false)  # worklist field only
        if newck !== nothing
            _write_checksum!(metafile, _image_layout(metafile).checksum_off, newck)
        end
    end

    # Rewrite the `.ji` trailer CRCs LAST (after every nonce/checksum edit is
    # final) so the stamped pair still passes Base's `stale_cachefile` /
    # `isprecompiled` validation. Only when keeping the image consistent
    # (`self_crc=true`); a deliberately-stale stamp leaves the trailer untouched.
    if self_crc && ji !== nothing
        _rewrite_ji_trailer!(ji, so)
    end

    return (; build_id_lo=build_id_lo, checksum=newck, ji=ji, so=so)
end

"""
    dry_verify(path::String) -> NamedTuple

Parse and sanity-check a `.ji`/`.so` package image **without loading it**, so
callers can fail fast with a clean diagnostic instead of a segfault or a
cryptic C-level "Error reading package image file."

Checks:
- the header parses,
- an effective worklist is resolvable (for a split `.so`, via its companion
  `.ji`) so a package name / `PkgId` can be inferred,
- the CRC32C over the data range matches the header checksum (and the checksum
  magic hi-32 is `0xfafbfcfd`). CRC is N/A (reported OK) for a split `.ji`,
  whose data blob lives in the `.so`.

Returns `(; ok, path, parse_ok, pkgimage, is_split, worklist_ok, crc_ok,
data_len, messages)`. `ok` is the AND of all applicable checks; `messages`
explains any failure. Never throws for a malformed image.
"""
function dry_verify(path::String)
    msgs = String[]
    if !isfile(path)
        return (; ok=false, path, parse_ok=false, pkgimage=false, is_split=false,
                  worklist_ok=false, crc_ok=false, data_len=0, messages=["file does not exist: $path"])
    end
    hdr = try
        parse_header(path)
    catch e
        return (; ok=false, path, parse_ok=false, pkgimage=false, is_split=false,
                  worklist_ok=false, crc_ok=false, data_len=0,
                  messages=["parse failed: " * sprint(showerror, e)])
    end

    wl = _effective_worklist(hdr, path)
    worklist_ok = !isempty(wl)
    worklist_ok || push!(msgs, "no resolvable worklist (empty header worklist and no companion .ji)")

    crc_ok = true
    data_len = 0
    lay = try
        _image_layout(path)
    catch e
        push!(msgs, "layout probe failed: " * sprint(showerror, e))
        crc_ok = false
        nothing
    end
    if lay !== nothing && lay.has_data
        data_len = lay.data_end_file - lay.data_start_file
        bytes = read(path)
        if lay.data_end_file <= length(bytes) && lay.data_start_file >= 0
            crc = crc32c(@view bytes[(lay.data_start_file + 1):lay.data_end_file])
            want = UInt32(lay.checksum & 0xffffffff)
            if crc != want
                crc_ok = false
                push!(msgs, "CRC mismatch: computed 0x$(string(crc, base=16)) header 0x$(string(want, base=16))")
            end
            if (lay.checksum >> 32) != 0xfafbfcfd
                crc_ok = false
                push!(msgs, "checksum magic (hi32) != 0xfafbfcfd")
            end
        else
            crc_ok = false
            push!(msgs, "data range [$(lay.data_start_file),$(lay.data_end_file)) exceeds file size $(length(bytes)) (truncated?)")
        end
    end

    ok = worklist_ok && crc_ok
    return (; ok, path, parse_ok=true, pkgimage=hdr.pkgimage, is_split=(_split_pair(path)[2] !== nothing),
              worklist_ok, crc_ok, data_len, messages=msgs)
end
