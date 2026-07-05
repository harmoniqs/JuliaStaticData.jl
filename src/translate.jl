"""
Reference translation: re-point a private package image's cross-image references
at a *consumer's own rebuild* of its dependencies, using live reflection on both
sides instead of blob archaeology.

This is the productization of the bundle-v2 research pipeline (Piccolissimo
`experiments/bundle-v2-tracer`, legs 4-5). The flow:

  builder (its own depot)                 consumer (its own depot)
  ─────────────────────                   ────────────────────────
  emit_sidecar(images) ───► Sidecar ────► translate!(image_copy, sidecar)
                                          load_package_image(...)
                                          canonicalize!(mod)

Each pointer that crosses into another loaded image is serialized inline in the
data blob as an 8-byte reloc *target word*
(`(5<<61) | (depsidx<<40) | (byte_offset÷8)`, staticdata.c:1204/2170 @ v1.12.6).
Refs into the sysimage (`depsidx == 0`) are stable across depots (identical Julia
⇒ identical sys image) and need no translation — measured 98.8% of refs. Only
refs into separately-precompiled *pkgimage* deps can shift.

- [`emit_sidecar`](@ref): parse each private image's ref words, resolve each
  pkgimage-dep target to the *live* object in the builder's own loaded deps (via
  `jl_linkage_blobs` blob base + offset), and emit a semantic
  [`RefDescriptor`](@ref) for it.
- [`translate!`](@ref): resolve every descriptor to a live object in the
  consumer's rebuilt deps, compute its new offset in the owning blob, rewrite the
  word, and restamp the checksums (reusing the [`stamp_identity!`](@ref)
  restamp internals).
- [`canonicalize!`](@ref): the post-load type-hash repair (leg5 wall #5).
- [`load_translated`](@ref): the top-level convenience chaining all of the above.
"""

# ── Reloc word / payload constants (staticdata.c @ v1.12.6) ──────────
#
# See leg4/RESULTS.md for the full payload layout map with source citations.
const _RELOC_TAG_OFFSET = 61
const _DEPS_IDX_OFFSET = 40
const _SYS_EXTERNAL_LINK_UNIT = 8
const _JL_CACHE_BYTE_ALIGNMENT = 64

const _DATAREF = 0
const _CONSTDATAREF = 1
const _TAGREF = 2
const _SYMBOLREF = 3
const _FUNCTIONREF = 4
const _SYSIMAGE_LINKAGE = 5
const _EXTERNAL_LINKAGE = 6

# ── Little-endian word helpers ───────────────────────────────────────

@inline function _read_u32(P::Vector{UInt8}, off::Int)
    return (UInt32(P[off + 1]) | UInt32(P[off + 2]) << 8 |
            UInt32(P[off + 3]) << 16 | UInt32(P[off + 4]) << 24)
end

@inline function _read_u64le(P::Vector{UInt8}, off::Int)
    v = UInt64(0)
    @inbounds for k in 0:7
        v |= UInt64(P[off + 1 + k]) << (8k)
    end
    return v
end

@inline function _write_u64le!(P::Vector{UInt8}, off::Int, v::UInt64)
    @inbounds for k in 0:7
        P[off + 1 + k] = UInt8((v >> (8k)) & 0xff)
    end
    return nothing
end

_align(x::Int, a::Int) = (x + a - 1) & ~(a - 1)

# ── Payload section parse ────────────────────────────────────────────
#
# The CRC-covered payload spans header [data_start, data_end). We reuse JSD's
# `parse_header`/`_image_layout` for the header, then walk the section chain
# (`jl_save_system_image_to_stream`, staticdata.c:3338-3434) to locate the
# gctags/relocs offsetlists and the gvar/delayed-root words — the sections that
# can carry external reloc words. Ported from leg5/blobparse2.jl.

struct _PayloadImage
    bytes::Vector{UInt8}       # whole file
    payload_base::Int          # 0-based file offset of payload byte 0
    P::Vector{UInt8}           # payload copy (payload_base .. data_end)
    blob_lo::Int               # 8
    blob_hi::Int               # 8 + sizeof_sysdata
    const_lo::Int
    const_hi::Int              # sizeof_sysimg (linkage-blob end)
    gctags::Vector{Int}
    relocs::Vector{Int}
    gvar_start::Int
    ngvars::Int
    external_fns_begin::Int
    droot_start::Int
    link_gctags::Vector{UInt32}
    link_relocs::Vector{UInt32}
    link_gvars::Vector{UInt32}
    link_extfn::Vector{UInt32}
    required::Vector{DepModEntry}
end

function _decode_offsetlist(P::Vector{UInt8}, start::Int)
    positions = Int[]
    last_pos = 0
    off = start
    while true
        pos_diff = 0
        cnt = 0
        while true
            b = P[off + 1]
            off += 1
            pos_diff |= Int(b & 0x7f) << (7 * cnt)
            cnt += 1
            (b & 0x80) == 0 && break
        end
        pos_diff == 0 && break
        last_pos += pos_diff
        push!(positions, last_pos)
    end
    return positions, off
end

# Parse the payload sections of a `.so`/`.ji` package image (staticdata.c:3338).
function _parse_payload(path::String)
    hdr = parse_header(path)
    lay = _image_layout(path)
    lay.has_data || throw(ArgumentError("no data blob in $path (a split .ji has its blob in the .so)"))
    bytes = read(path)
    ds = lay.data_start_file
    de = lay.data_end_file
    P = bytes[(ds + 1):de]
    p = 0
    sizeof_sysdata = Int(_read_u64le(P, p)); p += 8
    blob_lo = 8
    blob_hi = 8 + sizeof_sysdata
    p = blob_hi
    sizeof_const = Int(_read_u64le(P, p)); p += 8
    p = _align(p, _JL_CACHE_BYTE_ALIGNMENT); const_lo = p; p += sizeof_const
    const_hi = p
    sizeof_syms = Int(_read_u64le(P, p)); p += 8
    p = _align(p, 8); p += sizeof_syms
    sizeof_relocs = Int(_read_u64le(P, p)); p += 8
    p = _align(p, 8); relocs_start = p; p += sizeof_relocs
    sizeof_gvar = Int(_read_u64le(P, p)); p += 8
    p = _align(p, 8); gvar_start = p; p += sizeof_gvar
    sizeof_fptr = Int(_read_u64le(P, p)); p += 8
    p = _align(p, 8); p += sizeof_fptr
    p = _align(p, 8)
    droot_start = p
    p += 6 * 8
    n_gct = Int(_read_u32(P, p)); p += 4; link_gct = UInt32[_read_u32(P, p + 4k) for k in 0:(n_gct - 1)]; p += 4 * n_gct
    n_rel = Int(_read_u32(P, p)); p += 4; link_rel = UInt32[_read_u32(P, p + 4k) for k in 0:(n_rel - 1)]; p += 4 * n_rel
    n_gv = Int(_read_u32(P, p)); p += 4; link_gv = UInt32[_read_u32(P, p + 4k) for k in 0:(n_gv - 1)]; p += 4 * n_gv
    n_ef = Int(_read_u32(P, p)); p += 4; link_ef = UInt32[_read_u32(P, p + 4k) for k in 0:(n_ef - 1)]; p += 4 * n_ef
    external_fns_begin = Int(_read_u32(P, p)); p += 4
    chain_end = p
    chain_end == length(P) ||
        throw(ArgumentError("payload section chain did not land at payload end " *
                            "($chain_end vs $(length(P))) in $path — format mismatch?"))
    gctags, o1 = _decode_offsetlist(P, relocs_start)
    relocs, _ = _decode_offsetlist(P, o1)
    ngvars = sizeof_gvar ÷ 8
    return _PayloadImage(bytes, ds, P, blob_lo, blob_hi, const_lo, const_hi,
                         gctags, relocs, gvar_start, ngvars, external_fns_begin,
                         droot_start, link_gct, link_rel, link_gv, link_ef,
                         hdr.required_modules)
end

@inline function _decode_reloc_word(v::UInt64)
    tag = Int(v >> _RELOC_TAG_OFFSET)
    if tag == _SYSIMAGE_LINKAGE
        depsidx = Int((v >> _DEPS_IDX_OFFSET) &
                      ((UInt64(1) << (_RELOC_TAG_OFFSET - _DEPS_IDX_OFFSET)) - 1))
        offu = Int(v & ((UInt64(1) << _DEPS_IDX_OFFSET) - 1))
        return tag, depsidx, offu * _SYS_EXTERNAL_LINK_UNIT
    elseif tag == _EXTERNAL_LINKAGE
        offu = Int(v & ((UInt64(1) << _RELOC_TAG_OFFSET) - 1))
        return tag, -1, offu * _SYS_EXTERNAL_LINK_UNIT
    else
        return tag, -1, -1
    end
end

# Every external reloc word in the image, across the external-capable sections
# (gctags, relocs, gvars, external-fns, delayed roots). Returns
# `(; pos, kind, depsidx, byte_offset, word)` where `pos` is the payload byte
# position of the 8-byte word (the rewrite site).
function _external_refs(img::_PayloadImage)
    out = NamedTuple[]
    for (poslist, links) in ((img.gctags, img.link_gctags), (img.relocs, img.link_relocs))
        li = 1
        for pos in poslist
            v = _read_u64le(img.P, pos)
            tag, dep, boff = _decode_reloc_word(v)
            if tag == _SYSIMAGE_LINKAGE
                push!(out, (; pos, kind = tag, depsidx = dep, byte_offset = boff, word = v))
            elseif tag == _EXTERNAL_LINKAGE
                dep2 = li <= length(links) ? Int(links[li]) : -1
                li += 1
                push!(out, (; pos, kind = tag, depsidx = dep2, byte_offset = boff, word = v))
            end
        end
    end
    li_gv = 1; li_ef = 1
    for i in 0:(img.ngvars - 1)
        pos = img.gvar_start + 8i
        v = _read_u64le(img.P, pos)
        tag, dep, boff = _decode_reloc_word(v)
        if tag == _SYSIMAGE_LINKAGE
            push!(out, (; pos, kind = tag, depsidx = dep, byte_offset = boff, word = v))
        elseif tag == _EXTERNAL_LINKAGE
            if i < img.external_fns_begin
                dep2 = li_gv <= length(img.link_gvars) ? Int(img.link_gvars[li_gv]) : -1
                li_gv += 1
            else
                dep2 = li_ef <= length(img.link_extfn) ? Int(img.link_extfn[li_ef]) : -1
                li_ef += 1
            end
            push!(out, (; pos, kind = tag, depsidx = dep2, byte_offset = boff, word = v))
        end
    end
    for k in 0:5
        pos = img.droot_start + 8k
        v = _read_u64le(img.P, pos)
        tag, dep, boff = _decode_reloc_word(v)
        tag == _SYSIMAGE_LINKAGE &&
            push!(out, (; pos, kind = tag, depsidx = dep, byte_offset = boff, word = v))
    end
    return out
end

# ── Live-reflection helpers (leg5/sess_common.jl) ────────────────────
#
# `jl_linkage_blobs` is an arraylist of (lo, hi) pointer pairs, one per loaded
# image, readable from stock Julia via cglobal. A dep's blob base is the `lo` of
# the blob that contains the dep's root module pointer; an object at builder-side
# `byte_offset` is `unsafe_pointer_to_objref(lo + byte_offset)`.

function _blob_table()
    p = cglobal(:jl_linkage_blobs, UInt)
    len = unsafe_load(Ptr{UInt}(p), 1)
    items = unsafe_load(Ptr{Ptr{UInt}}(p + 2 * sizeof(UInt)))
    return [(unsafe_load(items, 2i + 1), unsafe_load(items, 2i + 2)) for i in 0:(len ÷ 2 - 1)]
end

function _blob_of(tbl, ptr::UInt)
    for (i, (lo, hi)) in enumerate(tbl)
        lo <= ptr < hi && return (i, lo, hi)   # 1-based index, base, end
    end
    return (0, UInt(0), UInt(0))
end

_vptr(x) = UInt(ccall(:jl_value_ptr, Ptr{Cvoid}, (Any,), x))

# The linkage blob [lo, hi) that holds a dep's root module, or `nothing`.
function _dep_blob(tbl, m::Module)
    i, lo, hi = _blob_of(tbl, _vptr(m))
    i == 0 && return nothing
    return (lo, hi)
end

# A dependency's live linkage blob span `[lo, hi)` paired with its parsed package
# image (`.so`), used by content descriptors to enumerate the blob's own objects
# (gctag boundaries) and const region. Defined here so `_describe_target` can name
# it in its signature.
struct _DepCtx
    lo::UInt
    hi::UInt
    img::_PayloadImage
end

# ── Descriptor emission (builder side) ───────────────────────────────
#
# Describe a live object semantically. Priority: named entities (module,
# binding, type, typename, function) first; then an anchor (named owner + a
# deterministic field path found by a bounded walk); else `nothing` (caller
# errors loudly — a builder-side failure is cheap, a consumer-side one is not).

# The (modpath, name) of a module relative to a dep root: [] for the root itself,
# else the chain of sub-module names. Returns `nothing` if `m` is not under `root`.
function _module_path(root::Module, m::Module)
    m === root && return Symbol[]
    chain = Symbol[]
    cur = m
    while cur !== root
        pm = parentmodule(cur)
        pm === cur && return nothing        # reached a top module that isn't root
        pushfirst!(chain, nameof(cur))
        cur = pm
    end
    return chain
end

# Is `v` the object bound to `name` in `mod` (unwrapping UnionAll for types)?
function _is_named_as(v, mod::Module, name::Symbol)
    isdefined(mod, name) || return false
    b = try
        getglobal(mod, name)
    catch
        return false
    end
    return _vptr(b) == _vptr(v)
end

# Try to describe `obj` as a NAMED entity owned by module `owner_mod` (which is
# under dep root `root`). Returns a RefDescriptor or `nothing`.
function _describe_named(obj, root::Module, owner_mod::Module)
    mp = _module_path(root, owner_mod)
    mp === nothing && return nothing

    if obj isa Module
        omp = _module_path(root, obj)
        omp === nothing && return nothing
        return RefDescriptor(:module, omp, Symbol(""))
    elseif obj isa Core.Binding
        gr = obj.globalref
        bmp = _module_path(root, gr.mod)
        bmp === nothing && return nothing
        return RefDescriptor(:binding, bmp, gr.name)
    elseif obj isa Core.TypeName
        # A typename is reached via its wrapper type's name binding.
        w = obj.wrapper
        base = Base.unwrap_unionall(w)
        base isa DataType || return nothing
        tnm = base.name.name
        tmod = base.name.module
        tmp = _module_path(root, tmod)
        (tmp === nothing || !_is_named_as(w, tmod, tnm)) && return nothing
        return RefDescriptor(:typename, tmp, tnm)
    elseif obj isa DataType || obj isa UnionAll
        base = Base.unwrap_unionall(obj)
        base isa DataType || return nothing
        tnm = base.name.name
        tmod = base.name.module
        tmp = _module_path(root, tmod)
        tmp === nothing && return nothing
        # Only when `obj` IS the module's named wrapper (not a parameterization).
        _is_named_as(obj, tmod, tnm) || return nothing
        return RefDescriptor(:type, tmp, tnm)
    else
        # Function / singleton instance.
        T = typeof(obj)
        if isdefined(T, :instance) && getfield(T, :instance) === obj
            fmod = parentmodule(obj)
            fnm = nameof(obj)
            fmp = _module_path(root, fmod)
            (fmp === nothing || !_is_named_as(obj, fmod, fnm)) && return nothing
            return RefDescriptor(:function, fmp, fnm)
        end
    end
    return nothing
end

# Which module (under `root`) most plausibly *owns* `obj`, for a first
# named-description attempt.
function _owning_module(obj, root::Module)
    if obj isa Module
        return obj
    elseif obj isa Core.Binding
        return obj.globalref.mod
    elseif obj isa Core.TypeName
        return obj.module
    elseif obj isa DataType
        return obj.name.module
    elseif obj isa UnionAll
        b = Base.unwrap_unionall(obj)
        return b isa DataType ? b.name.module : root
    else
        return try
            parentmodule(obj)
        catch
            root
        end
    end
end

# Deterministic child-navigation steps of an object, for anchor field paths.
# Each step is (op, arg, child). Kept structural (never hash/iteration-ordered):
# a rebuild lays these fields out differently but produces the SAME structure, so
# the consumer replays the same path to the corresponding object.
function _child_steps(obj)
    steps = Tuple{Symbol, Any, Any}[]
    if obj isa Core.SimpleVector
        for i in 1:length(obj)
            isassigned(obj, i) || continue
            push!(steps, (:getindex, i, obj[i]))
        end
    elseif obj isa DataType
        # Structurally-stable children (the parameters/types svecs, super, name).
        for f in (:parameters, :types, :super, :name)
            isdefined(obj, f) || continue
            c = try
                getfield(obj, f)
            catch
                continue
            end
            push!(steps, (:getfield, f, c))
        end
    elseif obj isa UnionAll
        push!(steps, (:getfield, :var, obj.var))
        push!(steps, (:getfield, :body, obj.body))
    elseif obj isa Core.TypeofVararg
        isdefined(obj, :T) && push!(steps, (:getfield, :T, obj.T))
    elseif isstructtype(typeof(obj)) && !(obj isa Module)
        T = typeof(obj)
        for i in 1:fieldcount(T)
            isdefined(obj, i) || continue
            f = try
                getfield(obj, i)
            catch
                continue
            end
            push!(steps, (:getfield, i, f))
        end
    end
    return steps
end

# Bounded BFS from named roots in `owner_mod`'s dep to find `obj` by pointer
# identity, returning an :anchor descriptor (owner + field path) or `nothing`.
function _describe_anchor(obj, root::Module, tbl, blob_lo::UInt, blob_hi::UInt;
                          max_nodes::Int = 20_000, max_depth::Int = 6)
    target = _vptr(obj)
    # Seed queue with named roots (bindings) of the whole dep module tree.
    seeds = Tuple{Any, RefDescriptor}[]
    for m in _dep_modules(root)
        mp = _module_path(root, m)
        mp === nothing && continue
        for nm in names(m; all = true, imported = false)
            isdefined(m, nm) || continue
            v = try
                getglobal(m, nm)
            catch
                continue
            end
            # Only in-blob objects can be the owner of an in-blob target.
            (v isa Module || v isa Function || v isa Type) || continue
            p = _vptr(v)
            (blob_lo <= p < blob_hi) || continue
            d = _describe_named(v, root, _owning_module(v, root))
            d === nothing && continue
            push!(seeds, (v, d))
            p == target && return RefDescriptor(:anchor, Symbol[], Symbol(""), d, Tuple{Symbol, Any}[])
        end
    end
    # BFS over structural children, tracking the path back to a seed.
    visited = Set{UInt}()
    Q = Tuple{Any, RefDescriptor, Vector{Tuple{Symbol, Any}}, Int}[]
    for (v, d) in seeds
        push!(Q, (v, d, Tuple{Symbol, Any}[], 0))
        push!(visited, _vptr(v))
    end
    nnodes = 0
    while !isempty(Q)
        cur, owner, path, depth = popfirst!(Q)
        nnodes += 1
        (nnodes > max_nodes || depth >= max_depth) && continue
        for (op, arg, child) in _child_steps(cur)
            child === nothing && continue
            cp = _vptr(child)
            newpath = vcat(path, Tuple{Symbol, Any}[(op, arg)])
            if cp == target
                return RefDescriptor(:anchor, Symbol[], Symbol(""), owner, newpath)
            end
            (blob_lo <= cp < blob_hi) || continue   # stay inside this dep's blob
            cp in visited && continue
            push!(visited, cp)
            push!(Q, (child, owner, newpath, depth + 1))
        end
    end
    return nothing
end

# All modules in a dep's tree (root + submodules), for descriptor search.
function _dep_modules(root::Module)
    mods = Module[root]
    stack = Module[root]
    seen = Set{Module}([root])
    while !isempty(stack)
        m = pop!(stack)
        for nm in names(m; all = true)
            isdefined(m, nm) || continue
            v = try
                getglobal(m, nm)
            catch
                continue
            end
            if v isa Module && v ∉ seen && parentmodule(v) === m
                push!(seen, v); push!(mods, v); push!(stack, v)
            end
        end
    end
    return mods
end

# Describe a live object: a named entity if possible, else an anchor, else
# `nothing`. (No throw — the caller decides how to report an undescribable one.)
function _describe_object(obj, root::Module, tbl, blob_lo::UInt, blob_hi::UInt)
    d = _describe_named(obj, root, _owning_module(obj, root))
    d !== nothing && return d
    return _describe_anchor(obj, root, tbl, blob_lo, blob_hi)
end

# Describe the live object at (dep root `root`, blob `[lo,hi)`, `byte_offset`).
# Errors loudly if it cannot be described — a builder-side failure is cheap,
# a consumer-side one is not.
function _describe_target(root::Module, tbl, blob_lo::UInt, blob_hi::UInt,
                          byte_offset::Int, dep_name::AbstractString;
                          dep_ctx::Union{_DepCtx, Nothing} = nothing)
    ptr = blob_lo + UInt(byte_offset)
    (blob_lo <= ptr < blob_hi) ||
        error("emit_sidecar: target offset $byte_offset out of $dep_name blob " *
              "[$blob_lo, $blob_hi) — depsidx mapping wrong?")
    obj = unsafe_pointer_to_objref(Ptr{Cvoid}(ptr))
    d = _describe_object(obj, root, tbl, blob_lo, blob_hi)
    d !== nothing && return d
    # No name and no build-stable anchor path: fall back to an order-independent
    # CONTENT descriptor for the two kinds leg5 proved are semantically stable but
    # positionally volatile — anonymous svecs and interned const-data strings.
    if dep_ctx !== nothing
        if obj isa Core.SimpleVector
            return _describe_svec_content(obj, dep_ctx, byte_offset, dep_name)
        elseif obj isa String
            return _describe_const_data(obj, dep_ctx, byte_offset, dep_name)
        elseif obj isa Method
            return _describe_method(obj, dep_ctx, byte_offset, dep_name, root)
        elseif obj isa Type
            return _describe_type_content(obj, dep_ctx, byte_offset, dep_name)
        end
    end
    error("emit_sidecar: cannot describe target in $dep_name at offset $byte_offset " *
          "(kind $(typeof(obj))): no named entity, no anchor+field-path, and no " *
          "content descriptor. repr=" * _safe_repr(obj))
end

function _safe_repr(obj)
    s = try
        sprint(show, obj; context = :limit => true)
    catch
        string(typeof(obj))
    end
    return length(s) > 200 ? s[1:200] : s
end

# ── Content descriptors: order-independent svec / const-data (leg5 §6) ─
#
# Some targets are anonymous objects with NO build-stable field path to a named
# owner (the anchor BFS cannot reach them at any depth): type-cache / format-spec /
# method-sig `SimpleVector`s and interned const-data `String`s. Their blob offset
# shifts between builds AND the path that reaches them (type-cache slot order) is
# build-volatile — so neither a raw offset nor an anchor descriptor is portable.
#
# They ARE describable by CONTENT, which is semantically stable: an svec's elements
# are types / isbits leaves; a const `String`'s value is its text. We ship the
# content and, on the consumer, reconstruct the element values and locate the live
# object in the *consumer's* rebuilt dep blob whose content matches — by structure,
# not by offset or order. Structurally-identical duplicates are pinned by their rank
# within the equal-content cohort (blob-offset order), which leg5 measured stable for
# the Altissimo cohorts.

_pack(x)::Vector{UInt8} = (io = IOBuffer(); Serialization.serialize(io, x); take!(io))
_unpack(b::Vector{UInt8}) = Serialization.deserialize(IOBuffer(b))

# Interning-independent element equality: mutual subtyping for type elements (a
# rebuild may hand back a non-`===` but structurally-identical type — esp. Tuple
# types, which are not interned), value equality (+ exact type) for leaves.
function _elem_eq(a, b)
    if a isa Type && b isa Type
        return a <: b && b <: a
    elseif a isa Type || b isa Type
        return false
    else
        return typeof(a) === typeof(b) && isequal(a, b)
    end
end

function _svec_matches(sv::Core.SimpleVector, content)
    length(sv) == length(content) || return false
    @inbounds for i in eachindex(content)
        (isassigned(sv, i) && _elem_eq(sv[i], content[i])) || return false
    end
    return true
end

# An svec element is describable-by-content iff it is a type or a serializable,
# structurally-comparable leaf. (Types serialize by module+name+params and
# reconstruct against the consumer's caches; leaves are self-describing.)
_portable_leaf(x) = x isa Type || x isa Symbol || x isa AbstractString ||
                    x isa Char || x isa Bool || x isa Number

# The consumer-side (or builder-side) `.so` package image for a *loaded* module,
# matched to that module's build-id. Needed to enumerate the dep blob's objects
# (gctag boundaries) and const region for content matching.
function _dep_so_path(pid::Base.PkgId, m::Module)
    wanthi = UInt64(Base.module_build_id(m) >> 64)
    cands = try
        Base.find_all_in_cache_path(pid)
    catch
        String[]
    end
    for ji in cands
        got = try
            open(Base.isvalid_cache_header, ji)
        catch
            UInt64(0)
        end
        (got == 0 || got != wanthi) && continue
        so = splitext(ji)[1] * ".so"
        isfile(so) && return so
    end
    # Single unambiguous candidate: accept its companion .so even if the header
    # probe was inconclusive.
    if length(cands) == 1
        so = splitext(cands[1])[1] * ".so"
        isfile(so) && return so
    end
    return nothing
end

# Offsets (dep-blob byte offsets) of every live in-blob svec whose content matches.
# Enumerates objects at the dep image's own gctag boundaries (object header at
# `gp`, object data at `gp+8` = the reloc byte offset).
function _match_svec_offsets(ctx::_DepCtx, content)
    offs = Int[]
    for gp in ctx.img.gctags
        boff = gp + 8
        ptr = ctx.lo + UInt(boff)
        (ctx.lo <= ptr < ctx.hi) || continue
        obj = try
            unsafe_pointer_to_objref(Ptr{Cvoid}(ptr))
        catch
            continue
        end
        (obj isa Core.SimpleVector && _svec_matches(obj, content)) && push!(offs, boff)
    end
    return sort!(offs)
end

# Offsets of every const-region `String` object whose serialized image
# (`[len:8][bytes][NUL]`) matches `s`. The object offset IS the length-prefix
# position (a `String`'s objref points at its length field).
function _match_const_string_offsets(ctx::_DepCtx, s::AbstractString)
    P = ctx.img.P
    body = codeunits(String(s))
    n = length(body)
    pat = Vector{UInt8}(undef, 8 + n + 1)
    let L = UInt64(n)
        @inbounds for k in 0:7
            pat[k + 1] = UInt8((L >> (8k)) & 0xff)
        end
    end
    @inbounds for k in 1:n
        pat[8 + k] = body[k]
    end
    pat[end] = 0x00
    m = length(pat)
    offs = Int[]
    lo = ctx.img.const_lo
    hi = ctx.img.const_hi
    p = lo
    @inbounds while p <= hi - m
        ok = true
        for k in 1:m
            if P[p + k] != pat[k]
                ok = false
                break
            end
        end
        ok && push!(offs, p)
        p += 1
    end
    return offs
end

# Pick the matched offset for a target given its cohort rank. A single match is
# taken directly; an equal-content cohort is pinned by rank iff the consumer cohort
# has the same size (otherwise a set-delta made it ambiguous — fail loudly rather
# than guess a structurally-identical but semantically-wrong sibling).
function _pick_ranked(offs::Vector{Int}, rank::Int, cohort::Int, what::AbstractString)
    isempty(offs) && error("$what: no content match in consumer dep blob")
    if length(offs) == 1 && (cohort <= 1 || rank == 1)
        return offs[1]
    end
    (cohort >= 1 && length(offs) == cohort && 1 <= rank <= cohort) &&
        return offs[rank]
    error("$what: content match is ambiguous (consumer found $(length(offs)) " *
          "candidates; builder cohort=$cohort rank=$rank) — cannot disambiguate")
end

# Builder-side: describe an undescribable target by content, WITH a self-check that
# the reconstructed content re-locates the very object we are describing (so a lossy
# content encoding fails cheaply here, never on the consumer).
function _describe_svec_content(obj::Core.SimpleVector, ctx::_DepCtx, boff::Int,
                                dep_name::AbstractString)
    n = length(obj)
    content = Vector{Any}(undef, n)
    for i in 1:n
        isassigned(obj, i) ||
            error("emit_sidecar: $dep_name svec@$boff has an undefined element $i")
        e = obj[i]
        _portable_leaf(e) ||
            error("emit_sidecar: $dep_name svec@$boff element $i is not " *
                  "content-describable ($(typeof(e))): " * _safe_repr(e))
        content[i] = e
    end
    # Self-check against the *round-tripped* payload — exactly the reconstruction
    # the consumer will match against — so a lossy encoding (e.g. a free TypeVar,
    # which a fresh deserialize renames and structural match then misses) fails
    # cheaply HERE, never as a silent mis-resolve on the consumer.
    payload = _pack(content)
    content2 = _unpack(payload)
    offs = _match_svec_offsets(ctx, content2)
    r = findfirst(==(boff), offs)
    r === nothing &&
        error("emit_sidecar: $dep_name svec@$boff — content self-check failed " *
              "(round-tripped content did not re-locate the target; matches=$offs). " *
              "The svec is not faithfully content-describable (free type variables?). " *
              "svec=" * _safe_repr(obj))
    return RefDescriptor(:svec_content, Symbol[], Symbol(""), nothing,
                         Tuple{Symbol, Any}[], payload, r, length(offs))
end

function _describe_const_data(obj, ctx::_DepCtx, boff::Int, dep_name::AbstractString)
    obj isa String ||
        error("emit_sidecar: $dep_name const-data target@$boff is a " *
              "$(typeof(obj)); only interned Strings are content-describable")
    payload = _pack(obj)
    offs = _match_const_string_offsets(ctx, _unpack(payload)::String)
    r = findfirst(==(boff), offs)
    r === nothing &&
        error("emit_sidecar: $dep_name const String@$boff — content self-check " *
              "failed (byte image did not re-locate; matches=$offs)")
    return RefDescriptor(:const_data, Symbol[], Symbol(""), nothing,
                         Tuple{Symbol, Any}[], payload, r, length(offs))
end

# Structural (interning-independent) type equality via mutual subtyping.
function _type_eq(a, b)
    (a isa Type && b isa Type) || return false
    return try
        a <: b && b <: a
    catch
        false
    end
end

# Offsets of every in-blob TYPE object structurally equal to `T` (a Union / an
# anonymous UnionAll / an un-named DataType parameterization — content-describable
# by its own structure, but with no name and no build-stable anchor path).
function _match_type_offsets(ctx::_DepCtx, T)
    offs = Int[]
    for gp in ctx.img.gctags
        boff = gp + 8
        ptr = ctx.lo + UInt(boff)
        (ctx.lo <= ptr < ctx.hi) || continue
        obj = try
            unsafe_pointer_to_objref(Ptr{Cvoid}(ptr))
        catch
            continue
        end
        (obj isa Type && _type_eq(obj, T)) && push!(offs, boff)
    end
    return sort!(offs)
end

function _describe_type_content(obj, ctx::_DepCtx, boff::Int, dep_name::AbstractString)
    payload = _pack(obj)
    T2 = _unpack(payload)
    offs = _match_type_offsets(ctx, T2)
    r = findfirst(==(boff), offs)
    r === nothing &&
        error("emit_sidecar: $dep_name type@$boff — content self-check failed " *
              "(round-tripped type did not re-locate; matches=$offs). type=" * _safe_repr(obj))
    return RefDescriptor(:type_content, Symbol[], Symbol(""), nothing,
                         Tuple{Symbol, Any}[], payload, r, length(offs))
end

# Resolve a method by (defining-module path, name, structural signature): among the
# world's methods whose ftype-signature admits `sig`, the one defined in `ownermod`
# as `name` with a structurally-identical `sig`. Returns its blob byte offset.
function _resolve_method_offset(sig, root::Module, mp::Vector{Symbol}, name::Symbol, ctx::_DepCtx)
    ownermod = _resolve_module(root, mp)
    cands = Base._methods_by_ftype(sig, -1, Base.get_world_counter())
    cands === false && error("method: _methods_by_ftype failed for $(_safe_repr(sig))")
    hits = Method[]
    for mm in cands
        meth = mm.method
        (meth.name === name && meth.module === ownermod) || continue
        (meth.sig <: sig && sig <: meth.sig) || continue
        push!(hits, meth)
    end
    isempty(hits) && error("method: no live method matches $(name) in $(nameof(ownermod)) with sig $(_safe_repr(sig))")
    length(hits) > 1 && error("method: ambiguous ($(length(hits)) live methods match) for $(name)")
    off = Int(_vptr(hits[1]) - ctx.lo)
    (0 <= off < Int(ctx.hi - ctx.lo)) ||
        error("method: resolved method offset $off out of blob for $(name)")
    return off
end

function _describe_method(m::Method, ctx::_DepCtx, boff::Int, dep_name::AbstractString,
                          root::Module)
    mp = _module_path(root, m.module)
    mp === nothing &&
        error("emit_sidecar: $dep_name method@$boff — defining module $(m.module) " *
              "not under dep root $(nameof(root))")
    payload = _pack(m.sig)
    off = _resolve_method_offset(_unpack(payload), root, mp, m.name, ctx)
    off == boff ||
        error("emit_sidecar: $dep_name method@$boff — self-check found offset $off " *
              "(method $(m.name), sig $(_safe_repr(m.sig)))")
    return RefDescriptor(:method, mp, m.name, nothing, Tuple{Symbol, Any}[], payload, 0, 0)
end

# ── Descriptor resolution (consumer side) ────────────────────────────

function _resolve_module(root::Module, modpath::Vector{Symbol})
    m = root
    for s in modpath
        (isdefined(m, s) && getglobal(m, s) isa Module) ||
            error("translate!: submodule $s not found under $(nameof(m))")
        m = getglobal(m, s)::Module
    end
    return m
end

# Resolve a descriptor to the live consumer object it names.
function _resolve_descriptor(d::RefDescriptor, root::Module)
    if d.kind === :module
        return _resolve_module(root, d.modpath)
    elseif d.kind === :binding
        m = _resolve_module(root, d.modpath)
        b = ccall(:jl_get_module_binding, Any, (Any, Any, Cint), m, d.name, 1)
        return b
    elseif d.kind === :type
        m = _resolve_module(root, d.modpath)
        return getglobal(m, d.name)
    elseif d.kind === :typename
        m = _resolve_module(root, d.modpath)
        T = getglobal(m, d.name)
        return Base.unwrap_unionall(T).name
    elseif d.kind === :function
        m = _resolve_module(root, d.modpath)
        return getglobal(m, d.name)
    elseif d.kind === :anchor
        cur = _resolve_descriptor(d.owner::RefDescriptor, root)
        for (op, arg) in d.fieldpath
            cur = _walk_step(cur, op, arg)
        end
        return cur
    elseif d.kind === :svec_content || d.kind === :const_data ||
           d.kind === :type_content || d.kind === :method
        error("translate!: $(d.kind) is a content descriptor — resolve it against a " *
              "dep blob with `_resolve_new_offset`, not `_resolve_descriptor` " *
              "(it has no live object to return, only a matched offset)")
    else
        error("translate!: unknown descriptor kind $(d.kind)")
    end
end

function _walk_step(cur, op::Symbol, arg)
    if op === :getindex
        return cur[arg]
    elseif op === :getfield
        return getfield(cur, arg)
    else
        error("translate!: unknown walk op $op")
    end
end

# Resolve a CONTENT descriptor (`:svec_content` / `:const_data`) to the new byte
# offset of the matching object in the consumer dep blob `ctx`. (Named/anchor kinds
# resolve to a live object whose offset is `jl_value_ptr - blob_base`; content kinds
# must instead SEARCH the consumer blob, since the object has no name and no stable
# path — see `_match_svec_offsets` / `_match_const_string_offsets`.)
function _resolve_new_offset(t::RefTarget, root::Module, ctx::_DepCtx)
    d = t.descriptor
    tag = "$(t.dep_name)@$(t.old_offset)"
    if d.kind === :svec_content
        content = _unpack(d.payload)
        offs = _match_svec_offsets(ctx, content)
        return _pick_ranked(offs, d.rank, d.cohort, "svec_content $tag")
    elseif d.kind === :const_data
        s = _unpack(d.payload)
        offs = _match_const_string_offsets(ctx, s)
        return _pick_ranked(offs, d.rank, d.cohort, "const_data $tag")
    elseif d.kind === :type_content
        T = _unpack(d.payload)
        offs = _match_type_offsets(ctx, T)
        return _pick_ranked(offs, d.rank, d.cohort, "type_content $tag")
    elseif d.kind === :method
        return _resolve_method_offset(_unpack(d.payload), root, d.modpath, d.name, ctx)
    else
        error("translate!: _resolve_new_offset called on non-content descriptor $(d.kind)")
    end
end

# ── emit_sidecar (builder) ───────────────────────────────────────────

"""
    emit_sidecar(images::Vector{String}; depot=nothing, require::Bool=true) -> Sidecar

Emit a reference-translation [`Sidecar`](@ref) for a set of private package
`images` (`.so`/`.ji` paths), using **live reflection** on the builder's own
loaded dependencies.

For each private image, `emit_sidecar` parses every external reloc word
(staticdata.c encoding), **skips** the ones that target the sysimage
(`depsidx == 0`, stable across depots — measured 98.8%), and for each word into a
separately-precompiled *pkgimage* dependency:

1. loads the dep normally (`Base.require(PkgId)` — it is one of the builder's own
   images) unless `require=false`,
2. finds the dep's linkage blob via `jl_linkage_blobs` (`base + byte_offset` =
   the live target object),
3. emits a semantic [`RefDescriptor`](@ref) for that object — a named entity
   (module / binding / type / typename / function) where possible; otherwise a
   nearest-named-owner **anchor** with a deterministic field path; otherwise, for
   the two kinds leg5 proved are semantically stable but positionally volatile —
   anonymous `SimpleVector`s (format-spec / method-sig / type-cache svecs) and
   interned const-data `String`s — an **order-independent content descriptor**
   (`:svec_content` / `:const_data`): the target's element values / string content,
   which the consumer reconstructs and re-locates in its *own* rebuilt dep blob by
   structural content match (see [`RefDescriptor`](@ref)). Each content descriptor
   is self-checked at emit time against its own round-tripped payload, so a target
   that is not faithfully content-describable (e.g. a svec with free type
   variables) fails HERE rather than mis-resolving on the consumer.

If a target can be described by none of the above, `emit_sidecar` errors loudly
(a builder-side failure is cheap; a consumer-side one is not).

# Arguments
- `depot`: if given, prepended to `JULIA_DEPOT_PATH` is *not* done here — the
  caller must already run in the builder's depot/project so the deps are
  `Base.require`-able. `depot` is recorded for diagnostics only.
- `require`: when `true` (default), `Base.require` each pkgimage dep before
  resolving; set `false` if the caller has already loaded them.

Returns a [`Sidecar`](@ref); persist it with [`write_sidecar`](@ref).

!!! warning
    Must run under the *same* Julia build the consumer will use — external
    offsets and the reloc encoding are Julia-version specific.
"""
function emit_sidecar(images::Vector{String}; depot = nothing, require::Bool = true)
    depot === nothing || @debug "emit_sidecar: builder depot" depot
    image_sidecars = ImageSidecar[]
    dep_root_cache = Dict{Tuple{String, UInt128}, Module}()

    for path in images
        img = _parse_payload(path)
        hdr = parse_header(path)
        refs = filter(r -> r.depsidx > 0, _external_refs(img))

        # Group words by (depsidx, byte_offset): one distinct target each.
        bytarget = Dict{Tuple{Int, Int}, Vector{Int}}()
        wordval = Dict{Tuple{Int, Int}, UInt64}()
        order = Tuple{Int, Int}[]
        for r in refs
            key = (r.depsidx, r.byte_offset)
            if !haskey(bytarget, key)
                bytarget[key] = Int[]
                wordval[key] = r.word
                push!(order, key)
            end
            push!(bytarget[key], r.pos)
        end

        # Require + resolve each referenced pkgimage dep once.
        if require
            for (depsidx, _) in order
                dep = img.required[depsidx]
                get!(dep_root_cache, (dep.name, UInt128(dep.build_id_hi) << 64 | dep.build_id_lo)) do
                    Base.require(Base.PkgId(dep.uuid, dep.name))
                end
            end
        end
        # Fresh blob table AFTER this image's deps are required (later images may
        # load more deps, appending blobs; a cached table would miss them).
        tbl = _blob_table()

        # Blob base + parsed image per depsidx (against the fresh blob table). The
        # parsed dep image (its own `.so`) supplies the gctag boundaries / const
        # region that content descriptors search when a target has no name/anchor.
        blobinfo = Dict{Int, Tuple{Module, UInt, UInt, Union{_DepCtx, Nothing}}}()
        targets = RefTarget[]
        for key in order
            depsidx, boff = key
            dep = img.required[depsidx]
            info = get!(blobinfo, depsidx) do
                m = Base.root_module(Base.PkgId(dep.uuid, dep.name))
                bl = _dep_blob(tbl, m)
                bl === nothing && error("emit_sidecar: no linkage blob for dep $(dep.name) " *
                                        "(depsidx $depsidx) — is it loaded?")
                ctx = nothing
                sop = _dep_so_path(Base.PkgId(dep.uuid, dep.name), m)
                if sop !== nothing
                    ctx = try
                        _DepCtx(bl[1], bl[2], _parse_payload(sop))
                    catch
                        nothing
                    end
                end
                (m, bl[1], bl[2], ctx)
            end
            m, lo, hi, ctx = info
            d = _describe_target(m, tbl, lo, hi, boff, dep.name; dep_ctx = ctx)
            push!(targets, RefTarget(depsidx, dep.name,
                                     UInt128(dep.uuid.value), boff, d,
                                     wordval[key], sort!(bytarget[key])))
        end

        w = isempty(hdr.worklist) ? _effective_worklist(hdr, path) : hdr.worklist
        iname = isempty(w) ? splitext(basename(path))[1] : w[end].name
        iuuid = isempty(w) ? UInt128(0) : UInt128(w[end].uuid.value)
        push!(image_sidecars, ImageSidecar(iname, iuuid, string(VERSION),
                                           length(refs), targets))
    end
    return Sidecar(1, image_sidecars)
end

# ── translate! (consumer) ────────────────────────────────────────────

"""
    translate!(image_path::String, sidecar; depot=nothing, require::Bool=true,
               restamp::Bool=true) -> TranslationReport

Rewrite a **copy** of a private package image so its cross-image references point
into the *consumer's own* rebuild of the dependencies, using the semantic
[`RefDescriptor`](@ref)s in `sidecar` (a [`Sidecar`](@ref) or a path to one).

For the matching image in the sidecar, `translate!`:

1. resolves each descriptor to a live object in the consumer's loaded deps
   (`Base.require` them first unless `require=false`),
2. computes the object's offset in its owning linkage blob
   (`jl_value_ptr - blob_base`, the `jl_linkage_blobs` technique in reverse),
3. rewrites every ref word for that target in place
   (`(5<<61) | (depsidx<<40) | (new_offset÷8)`),
4. restamps the image's checksums (embedded `.so` checksum + mirrored `.ji`
   header checksum + `.ji` trailer CRCs — reusing the [`stamp_identity!`](@ref)
   restamp path) unless `restamp=false`.

`image_path` **must** be a writable copy; the file is modified in place. Each
word's decoded `(depsidx, offset)` and raw value are checked against the sidecar
before rewriting (integrity), so a mismatched image fails loudly.

Header dependency-identity remapping is *not* done here — do it at load time with
[`remap!`](@ref) / [`load_package_image`](@ref) against the actually-loaded
consumer modules, or use [`load_translated`](@ref) which chains everything.

Returns a [`TranslationReport`](@ref).
"""
function translate!(image_path::String, sidecar; depot = nothing,
                    require::Bool = true, restamp::Bool = true)
    sc = sidecar isa Sidecar ? sidecar : read_sidecar(String(sidecar))
    depot === nothing || @debug "translate!: consumer depot" depot

    img = _parse_payload(image_path)
    # Match this image to its sidecar entry by worklist name.
    hdr = parse_header(image_path)
    w = isempty(hdr.worklist) ? _effective_worklist(hdr, image_path) : hdr.worklist
    iname = isempty(w) ? splitext(basename(image_path))[1] : w[end].name
    isc = findfirst(s -> s.image_name == iname, sc.images)
    isc === nothing && error("translate!: no sidecar entry for image '$iname'")
    entry = sc.images[isc]
    entry.julia_version == string(VERSION) ||
        @warn "translate!: sidecar emitted under Julia $(entry.julia_version), running $(VERSION)"

    if require
        # Require every dependency the image records (not only the ones that own a
        # target): a content descriptor's element types can name *any* required
        # module (e.g. an LLVM svec whose element is `Tuple{Printf.Spec{Val{'s'}}}`),
        # and those modules must be loaded before the content is reconstructed.
        for dep in img.required
            _is_sysimage_dep(dep) && continue
            try
                Base.require(Base.PkgId(dep.uuid, dep.name))
            catch e
                @warn "translate!: could not require dep $(dep.name)" exception = e
            end
        end
    end
    tbl = _blob_table()

    # Per-dep resolution context: blob base `lo` (always, for named/anchor targets)
    # plus the parsed dep image `ctx` (only needed for content descriptors, which
    # enumerate the dep blob's own objects to locate a content match).
    depinfo = Dict{Int, NamedTuple{(:m, :lo, :ctx),
                    Tuple{Union{Module, Nothing}, UInt, Union{_DepCtx, Nothing}}}}()
    getinfo(t) = get!(depinfo, t.depsidx) do
        pid = Base.PkgId(Base.UUID(t.dep_uuid), t.dep_name)
        m = try
            Base.root_module(pid)
        catch
            nothing
        end
        # Fall back to loaded_precompiles for an upstream private loaded via
        # `load_package_image` (not registered in loaded_modules / root_module).
        m === nothing && (m = _loaded_module_by_pid(pid))
        m === nothing && return (m = nothing, lo = UInt(0), ctx = nothing)
        bl = _dep_blob(tbl, m)
        bl === nothing && return (m = m, lo = UInt(0), ctx = nothing)
        ctx = nothing
        sop = _dep_so_path(pid, m)
        if sop !== nothing
            ctx = try
                _DepCtx(bl[1], bl[2], _parse_payload(sop))
            catch
                nothing
            end
        end
        return (m = m, lo = bl[1], ctx = ctx)
    end

    so = copy(img.bytes)            # edit the raw file bytes (payload_base offset)
    words_rewritten = 0
    words_unchanged = 0
    words_checked = 0
    resolved = 0
    failed = String[]

    for t in entry.targets
        info = getinfo(t)
        if info.lo == 0
            push!(failed, "$(t.dep_name)@$(t.old_offset): dep not loaded")
            continue
        end
        is_content = t.descriptor.kind === :svec_content ||
                     t.descriptor.kind === :const_data ||
                     t.descriptor.kind === :type_content ||
                     t.descriptor.kind === :method
        if is_content && info.ctx === nothing
            push!(failed, "$(t.dep_name)@$(t.old_offset): content descriptor but " *
                          "dep package image not found for blob enumeration")
            continue
        end
        newoff = try
            if is_content
                _resolve_new_offset(t, info.m::Module, info.ctx::_DepCtx)
            else
                obj = _resolve_descriptor(t.descriptor, info.m::Module)
                Int(_vptr(obj) - info.lo)
            end
        catch e
            push!(failed, "$(t.dep_name)@$(t.old_offset): $(sprint(showerror, e))")
            continue
        end
        newoff >= 0 && newoff % 8 == 0 ||
            (push!(failed, "$(t.dep_name)@$(t.old_offset): bad new offset $newoff"); continue)
        resolved += 1
        newword = (UInt64(_SYSIMAGE_LINKAGE) << _RELOC_TAG_OFFSET) |
                  (UInt64(t.depsidx) << _DEPS_IDX_OFFSET) | UInt64(newoff ÷ 8)
        for pos in t.positions
            fpos = img.payload_base + pos
            words_checked += 1
            v = _read_u64le(so, fpos)
            v == t.expected_word ||
                error("translate!: integrity check failed at payload pos $pos " *
                      "(word 0x$(string(v, base=16)) != expected 0x$(string(t.expected_word, base=16)))")
            if newword == v
                words_unchanged += 1
            else
                _write_u64le!(so, fpos, newword)
                words_rewritten += 1
            end
        end
    end

    write(image_path, so)
    _is_shared_library(image_path) && chmod(image_path, 0o755)

    old_ck = UInt64(0); new_ck = UInt64(0)
    if restamp
        old_ck = _image_layout(image_path).checksum
        new_ck = _restamp_checksums!(image_path)
    end

    ok = isempty(failed) && (!restamp || new_ck != 0)
    return TranslationReport(image_path, words_checked, words_rewritten,
                             words_unchanged, resolved, failed, old_ck, new_ck, ok)
end

# Recompute an image's embedded checksum over its data blob, mirror it into the
# companion `.ji` header, and rewrite the `.ji` trailer CRCs — reusing the
# `stamp_identity!` restamp internals. Returns the new 64-bit checksum.
function _restamp_checksums!(image_path::String)
    ji, so = _split_pair(image_path)
    if ji === nothing && so === nothing
        _is_shared_library(image_path) ? (so = image_path) : (ji = image_path)
    end
    datafile = so !== nothing ? so : ji
    lay = _image_layout(datafile)
    bytes = read(datafile)
    crc = crc32c(@view bytes[(lay.data_start_file + 1):lay.data_end_file])
    newck = (UInt64(0xfafbfcfd) << 32) | UInt64(crc)
    _write_checksum!(datafile, lay.checksum_off, newck)
    if so !== nothing && ji !== nothing
        _write_checksum!(ji, _image_layout(ji).checksum_off, newck)
    end
    ji === nothing || _rewrite_ji_trailer!(ji, so)
    return newck
end

# ── Sidecar persistence ──────────────────────────────────────────────

"""
    write_sidecar(path::String, sc::Sidecar)

Serialize a [`Sidecar`](@ref) to `path` (Julia `Serialization`; only valid for
the same Julia build, which is exactly the translation constraint anyway).
"""
function write_sidecar(path::String, sc::Sidecar)
    open(path, "w") do io
        Serialization.serialize(io, sc)
    end
    return path
end

"""
    read_sidecar(path::String) -> Sidecar

Deserialize a [`Sidecar`](@ref) written by [`write_sidecar`](@ref).
"""
function read_sidecar(path::String)
    sc = open(Serialization.deserialize, path)
    sc isa Sidecar || throw(ArgumentError("$path is not a JSD Sidecar"))
    return sc
end

# ── canonicalize! (post-load type-hash repair) ───────────────────────
#
# leg5 wall #5: TypeName hashes are salted with the owning module's per-build
# `build_id.lo` nonce (datatype.c:84), so a translated image's own method
# signatures carry stale baked type hashes; `typeintersect` / type-cache probes /
# `objectid` then silently miss even though the refs point at the right objects.
# Repair = re-intern each private method sig through live consumer constructors
# (POINTER compare, `===` lies for types here) and re-insert ONLY the dispatch
# entries that are genuinely broken (unconditional re-insert causes ambiguities).

function _canonsig(t)
    if t isa UnionAll
        b = _canonsig(t.body)
        return b === t.body ? t : UnionAll(t.var, b)
    elseif t isa Core.TypeofVararg
        isdefined(t, :T) || return t
        T2 = _canonsig(t.T)
        return isdefined(t, :N) ? Vararg{T2, t.N} : Vararg{T2}
    elseif t isa DataType
        isempty(t.parameters) && return t
        ps = Any[p isa Type || p isa Core.TypeofVararg ? _canonsig(p) : p for p in t.parameters]
        if t.name.name === :Tuple
            # Tuple types are NOT interned, so `Tuple{ps...}` yields a fresh
            # object every call — rebuilding unconditionally makes the pass
            # non-idempotent (and re-allocates every method sig on each run). Only
            # rebuild when a parameter's identity actually changed (a salted
            # component was canonicalized); otherwise keep the original, so a
            # method sig with no salted components is a fixpoint.
            changed = any(i -> _vptr(ps[i]) != _vptr(t.parameters[i]), eachindex(ps))
            return changed ? Tuple{ps...} : t
        end
        # Interned (cached) types: re-instantiate through the wrapper so a
        # builder-salted duplicate is replaced by the consumer-canonical object
        # (returns the same pointer when already canonical → idempotent).
        return try
            t.name.wrapper{ps...}
        catch
            t
        end
    else
        return t
    end
end

"""
    canonicalize!(mods::Module...) -> CanonicalizeReport

Post-load type-hash repair for freshly [`translate!`](@ref)d private modules
(leg5 wall #5). Idempotent.

`TypeName` hashes are salted with the owning module's per-build `build_id.lo`
nonce (`datatype.c:84` @ v1.12.6), so a translated image's own method signatures
carry stale baked type hashes valid only in the *builder's* nonce universe;
hash-consulting dispatch paths (type-cache probes, `typeintersect`, `objectid`)
then silently miss and dispatch fails with a paradoxical `MethodError` even
though the listed candidate matches.

This pass walks every method defined by `mods` (and their submodules),
reconstructs each `Method.sig` through the live consumer-side type constructors —
which intern against the consumer's canonical type caches — compares by pointer
(`===` is structural and *lies* here), patches the field, and re-inserts only the
dispatch entries the method table can no longer find for their own canonical
signature.

Returns a [`CanonicalizeReport`](@ref).
"""
# Whether dispatch can find `meth` when queried with signature `probe`. A
# nonce-salted (stale-hash) method is the pathology leg5 wall #5 describes: `===` /
# subtyping still hold (structural), but the hash-consulting cache probe inside
# `_methods_by_ftype` MISSES. Crucially the query must use a **freshly-reconstructed**
# (consumer-hash) signature: probing with the method's OWN stale-hashed sig would
# still match the stale-stored table entry and falsely report health. Probing with a
# fresh-hash sig reveals the mismatch — and makes the repair idempotent (a re-inserted
# method is stored under the fresh hash, so the next pass's fresh-hash probe finds it).
function _sig_findable(meth::Method, probe)
    return try
        found = false
        for mm in Base._methods_by_ftype(probe, -1, Base.get_world_counter())
            if mm.method === meth
                found = true
                break
            end
        end
        found
    catch
        true   # cannot probe (odd sig) → treat as healthy, leave it alone
    end
end

# Reconstruct a signature so its (and its components') type hashes are recomputed in
# the CONSUMER's nonce universe. Interned parametric components go through
# `_canonsig` (idempotent — returns the same pointer once canonical); the sig's own
# `Tuple` wrapper is rebuilt UNCONDITIONALLY, because Tuple types are not interned so
# the only way to refresh a stale baked hash is to construct a fresh one.
function _recanon_sig(t)
    if t isa UnionAll
        return UnionAll(t.var, _recanon_sig(t.body))
    elseif t isa DataType && t.name.name === :Tuple
        ps = Any[(p isa Type || p isa Core.TypeofVararg) ? _canonsig(p) : p for p in t.parameters]
        return Tuple{ps...}
    else
        return _canonsig(t)
    end
end

function canonicalize!(mods::Module...)
    allmods = Set{Module}()
    for r in mods
        union!(allmods, _dep_modules(r))
    end
    sigidx = findfirst(==(:sig), fieldnames(Method))
    nseen = 0; nfix = 0; nreins = 0
    visited = Set{UInt}()
    for m in allmods, n in names(m; all = true, imported = true)
        isdefined(m, n) || continue
        v = try
            getglobal(m, n)
        catch
            continue
        end
        (v isa Function || v isa Type) || continue
        ml = try
            methods(v)
        catch
            continue
        end
        for meth in ml
            meth.module in allmods || continue
            objectid(meth) in visited && continue
            push!(visited, objectid(meth)); nseen += 1
            # Reconstruct the sig with consumer-universe hashes, then gate strictly on
            # brokenness (idempotent: a healthy/repaired method is found by the
            # fresh-hash probe and skipped). Unconditional re-interning of every sig
            # is slow and — for re-insertion — dangerous (duplicate dispatch entries →
            # spurious ambiguities).
            cs = try
                _recanon_sig(meth.sig)
            catch
                continue
            end
            _sig_findable(meth, cs) && continue          # dispatch already finds it → healthy
            same = try                                   # alpha-equivalent same signature
                cs <: meth.sig && meth.sig <: cs
            catch
                false
            end
            same || continue
            try
                if _vptr(cs) != _vptr(meth.sig)
                    ccall(:jl_set_nth_field, Cvoid, (Any, Csize_t, Any), meth, sigidx - 1, cs)
                    nfix += 1
                end
                # Broken ⇒ the stored dispatch entry is under a stale hash; re-insert
                # so the method is reachable under its consumer-hash signature.
                mt = ccall(:jl_method_table_for, Any, (Any,), cs)
                if mt !== nothing
                    ccall(:jl_method_table_insert, Cvoid, (Any, Any, Ptr{Cvoid}), mt, meth, C_NULL)
                    nreins += 1
                end
            catch e
                @debug "canonicalize!: sig-fix failed" file = meth.file line = meth.line exception = e
            end
        end
    end
    return CanonicalizeReport(nseen, nfix, nreins, String[string(nameof(m)) for m in mods])
end

# Remap an image's header dependency identities to the build-ids of the
# currently-loaded consumer modules of the same (uuid, name) — leg5's
# consumer-side header algorithm. A translated private image adopts new
# checksums, and its downstream headers must carry the loaded deps' identities
# (private-to-private entries INCLUDED — do not skip them). Returns the specs
# that were applied.
function _remap_to_loaded!(image_path::String)
    hdr = parse_header(image_path)
    specs = RemapSpec[]
    for dep in hdr.required_modules
        _is_sysimage_dep(dep) && continue
        pid = Base.PkgId(dep.uuid, dep.name)
        # Consult loaded_precompiles too: an upstream private already loaded via
        # `load_package_image` (e.g. a translated Altissimo) lands there, not in
        # loaded_modules — and a downstream private's header MUST be remapped to
        # its NEW (restamped) build-id or the closure check flags mixed lineage.
        m = _loaded_module_by_pid(pid)
        m === nothing && continue
        bid = Base.module_build_id(m)
        cur = (UInt128(dep.build_id_hi) << 64) | UInt128(dep.build_id_lo)
        bid == cur && continue
        push!(specs, RemapSpec(dep.name, dep.uuid, bid))
    end
    if !isempty(specs)
        ji, so = _split_pair(image_path)
        (ji === nothing && so === nothing) &&
            (_is_shared_library(image_path) ? (so = image_path) : (ji = image_path))
        ji === nothing || remap!(ji, specs)
        so === nothing || remap!(so, specs)
    end
    return specs
end

# ── load_translated (top-level convenience) ──────────────────────────

"""
    load_translated(image_path::String, sidecar; depot=nothing,
                    check_closure::Bool=true, canonicalize::Bool=true,
                    remap::Bool=true, translated::Bool=false)
        -> (mod, translate_report, canon_report)

End-to-end consumer path for a translated private image, chaining
[`translate!`](@ref) → header remap-to-loaded → [`verify_closure`](@ref) →
[`load_package_image`](@ref) → [`canonicalize!`](@ref).

Steps:
1. **translate** (unless `translated=true`): [`translate!`](@ref) rewrites the
   cross-image ref words and restamps the checksums. The file is modified in
   place — pass a writable *copy*. `translate!` also `Base.require`s the
   consumer's rebuilt deps, so they are loaded for the next step.
2. **remap** (when `remap=true`): rewrite the image's header dependency
   identities to the build-ids of the now-loaded consumer deps, so
   `resolve_dep` finds them (leg5's consumer-side header algorithm; private↔
   private entries included).
3. **load**: [`load_package_image`](@ref) with `check_closure` (turns a
   mixed-lineage segfault into a clean error).
4. **canonicalize** (when `canonicalize=true`): the post-load type-hash repair.

Returns `(mod, translate_report, canon_report)`; the report fields are `nothing`
when the corresponding step is skipped.
"""
function load_translated(image_path::String, sidecar; depot = nothing,
                         check_closure::Bool = true, canonicalize::Bool = true,
                         remap::Bool = true, translated::Bool = false)
    trep = translated ? nothing : translate!(image_path, sidecar; depot = depot)
    trep === nothing || trep.ok ||
        @warn "load_translated: translate! reported failures" trep.targets_failed
    remap && _remap_to_loaded!(image_path)
    mod = load_package_image(image_path; check_closure = check_closure)
    crep = canonicalize ? canonicalize!(mod) : nothing
    return (mod, trep, crep)
end
