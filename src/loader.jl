"""
Custom package image loading path, parallel to Base's loading infrastructure.

Calls the same C deserialization functions (`jl_restore_package_image_from_file`,
`jl_restore_incremental`) but with caller-controlled dependency resolution,
bypassing Base's staleness checks.
"""

"""
    resolve_dep(entry::DepModEntry) -> Module

Find a loaded module matching the given dependency entry's name, uuid, and build_id.

Searches `Base.loaded_precompiles` and `Base.loaded_modules` for a module
whose `Base.module_build_id` matches the entry's build_id.
"""
function resolve_dep(entry::DepModEntry)
    target_build_id = UInt128(entry.build_id_hi) << 64 | entry.build_id_lo
    return resolve_dep(entry.name, target_build_id)
end

"""
    resolve_dep(name::String, build_id::UInt128) -> Module

Find a loaded module by name and build_id.
"""
function resolve_dep(name::String, build_id::UInt128)
    mod = _find_loaded_module(name, build_id)
    mod === nothing && error("Cannot resolve dependency: module '$name' with " *
        "build_id=0x$(string(build_id, base=16, pad=32)) not found in loaded modules")
    return mod
end

# Non-throwing sibling of `resolve_dep`: find a loaded module matching `name` and
# 128-bit `build_id`, or `nothing`. Searches the same universe the C restore path
# resolves against (`loaded_precompiles`, `loaded_modules`, and the well-known
# roots), so `verify_closure` can pre-check against exactly what a real load sees.
function _find_loaded_module(name::AbstractString, build_id::UInt128)
    # Search loaded_precompiles first (may have multiple versions)
    for (_, mods) in Base.loaded_precompiles
        for mod in mods
            if String(nameof(mod)) == name && Base.module_build_id(mod) == build_id
                return mod
            end
        end
    end
    # Fall back to loaded_modules
    for (_, mod) in Base.loaded_modules
        if String(nameof(mod)) == name && Base.module_build_id(mod) == build_id
            return mod
        end
    end
    # Check well-known modules (Core, Base, Main)
    for mod in (Core, Base, Main)
        if String(nameof(mod)) == name && Base.module_build_id(mod) == build_id
            return mod
        end
    end
    return nothing
end

# The loaded module for a `PkgId`, searching `loaded_precompiles` (where
# `load_package_image` registers restored modules) as well as `loaded_modules` and
# the well-known roots. A private image loaded via `load_package_image` lands in
# `loaded_precompiles` but NOT `loaded_modules`, so a plain `root_module`/
# `loaded_modules` lookup misses it — this finds it (used when translating a
# downstream private that depends on an already-loaded private, and when remapping
# headers to the loaded universe).
function _loaded_module_by_pid(pid::Base.PkgId)
    m = get(Base.loaded_modules, pid, nothing)
    m === nothing || return m
    for (p, mods) in Base.loaded_precompiles
        (p.uuid === pid.uuid && p.name == pid.name) || continue
        isempty(mods) || return last(mods)
    end
    for mod in (Core, Base, Main)
        (pid.name == String(nameof(mod))) && return mod
    end
    return nothing
end

# All 128-bit build-ids under which a module `name` is currently loaded (across
# `loaded_precompiles` and `loaded_modules`). Used to distinguish a genuinely
# `:absent` dependency from a `:mixed_lineage` one (name present, wrong build-id).
function _loaded_build_ids(name::AbstractString)
    ids = UInt128[]
    for (_, mods) in Base.loaded_precompiles
        for mod in mods
            String(nameof(mod)) == name && push!(ids, Base.module_build_id(mod))
        end
    end
    for (_, mod) in Base.loaded_modules
        String(nameof(mod)) == name && push!(ids, Base.module_build_id(mod))
    end
    return ids
end

"""
    load_package_image(path::String;
                       depmods::Vector{Any}=Any[],
                       register::Bool=true,
                       run_init::Bool=true,
                       check_closure::Bool=false,
                       pkgname::Union{String,Nothing}=nothing) -> Module

Load a package image from `path`, bypassing Base's staleness checks.

# Arguments
- `path`: Path to `.ji` or `.so` file
- `depmods`: Pre-resolved dependency modules. Must match the header's required_modules.
  Use `resolve_dep` or `resolve_all_deps` to construct this array.
- `register`: If true, register loaded modules with Base via `register_restored_modules`.
- `run_init`: If true, run `__init__` callbacks. Only meaningful if `register=true`.
- `check_closure`: If true, run [`verify_closure`](@ref) on `[path]` before the
  `ccall` and throw a clean `ArgumentError` (listing the missing / mixed-lineage
  dependencies) instead of risking a segfault in `jl_validate_binding_partition`.
  Defaults to `false`, leaving single-image loads unchanged. When loading a
  *set* of stamped/remapped images together, prefer calling
  `verify_closure(paths)` on the whole set up front.
- `pkgname`: Package name (inferred from header if not provided).
"""
function load_package_image(path::String;
                            depmods::Vector{Any}=Any[],
                            register::Bool=true,
                            run_init::Bool=true,
                            check_closure::Bool=false,
                            pkgname::Union{String,Nothing}=nothing)
    hdr = parse_header(path)

    if check_closure
        rep = verify_closure([path])
        rep.ok || throw(ArgumentError("load_package_image: dependency closure check failed for " *
            "$path (loading anyway risks a segfault in jl_validate_binding_partition):\n  " *
            join(rep.messages, "\n  ")))
    end

    # Infer package name from worklist if not provided. A split `.so` header has
    # no worklist (it lives in the companion `.ji`), so fall back to that.
    if pkgname === nothing
        wl = _effective_worklist(hdr, path)
        isempty(wl) && error("Cannot infer package name: worklist is empty in $path " *
                             "(and no companion .ji with a worklist was found)")
        pkgname = wl[end].name
    end

    # Auto-resolve depmods from header if not provided
    if isempty(depmods) && !isempty(hdr.required_modules)
        depmods = resolve_all_deps(hdr)
    end

    # Determine if this is a pkgimage (.so) or incremental (.ji)
    is_pkgimage = hdr.pkgimage || _has_companion_so(path)

    sv = @lock Base.require_lock begin
        unlock(Base.require_lock)
        result = try
            if is_pkgimage
                ocachepath = _find_ocachepath(path)
                ccall(:jl_restore_package_image_from_file, Any,
                      (Cstring, Any, Cint, Cstring, Cint),
                      ocachepath, depmods, false, pkgname, false)
            else
                ccall(:jl_restore_incremental, Any,
                      (Cstring, Any, Cint, Cstring),
                      path, depmods, false, pkgname)
            end
        finally
            lock(Base.require_lock)
        end
        result
    end

    if sv isa Exception
        throw(sv)
    end

    sv = sv::Core.SimpleVector

    if register
        pkg = _infer_pkgid(hdr, path)
        restored = @lock Base.require_lock Base.register_restored_modules(sv, pkg, path)

        if !run_init
            # register_restored_modules already ran __init__; we can't undo that.
            # This is a limitation: __init__ always runs during registration.
        end

        # Find and return the main module
        for M in restored
            M = M::Module
            if Base.is_root_module(M) && String(nameof(M)) == pkgname
                return M
            end
        end
    end

    # Return the first restored module if not registering
    restored = sv[1]::Vector{Any}
    isempty(restored) && error("No modules restored from $path")
    return restored[end]::Module
end

"""
    resolve_all_deps(hdr::PkgImageHeader) -> Vector{Any}

Resolve all required modules from a parsed header against the current session.
"""
function resolve_all_deps(hdr::PkgImageHeader)
    depmods = Vector{Any}(undef, length(hdr.required_modules))
    for (i, dep) in enumerate(hdr.required_modules)
        depmods[i] = resolve_dep(dep)
    end
    return depmods
end

# The 128-bit identity a package image *provides* for a worklist module:
# `checksum << 64 | build_id.lo`, i.e. exactly what `Base.module_build_id`
# returns once the image is loaded (the hi half is the image's own checksum,
# the lo half is the nonce). This is the key `resolve_dep` matches against.
_provided_build_id(hdr::PkgImageHeader, w::WorklistEntry) =
    (UInt128(hdr.checksum) << 64) | UInt128(w.build_id_lo)

# A dependency baked into the running system's base lineage (Base/Core and
# sysimage stdlibs). Such identities are always available and stable across a
# Julia build, so they are never a closure concern for a stamped/remapped set.
_is_sysimage_dep(dep::DepModEntry) = Base.in_sysimage(Base.PkgId(dep.uuid, dep.name))

"""
    verify_closure(paths::Vector{String}; check_loaded::Bool=true) -> ClosureReport

Check that a set of package images is CLOSED under `required_modules`: every
non-sysimage/stdlib dependency identity any image references must be provided
either by another image in `paths` or (when `check_loaded=true`) by an
already-loaded module.

This encodes a hard-won loading law: when loading images whose identities were
stamped/remapped, the set must be closed. A *mixed universe* — where some deps
resolve from stamped/new-lineage images and others from old-lineage ones —
segfaults in `jl_validate_binding_partition` inside the C restore path. Running
`verify_closure` first turns that crash into a clean, actionable
[`ClosureReport`](@ref) listing the missing / mixed-lineage dependencies, BEFORE
any `ccall`.

The check is pure header parsing (no image is loaded), and it never throws for a
malformed image: a parse failure is recorded in `messages` and drives `ok=false`.

Each image *provides* the identity `checksum << 64 | build_id.lo` for its
worklist module(s) — exactly the 128-bit build-id `resolve_dep` matches. A
dependency is satisfied when its recorded build-id equals a provided one (in the
set) or a loaded module's build-id. Otherwise it is reported as `:absent` (name
offered nowhere — a clean `resolve_dep` failure) or `:mixed_lineage` (name
offered, but only under a different build-id — the segfault-class violation).

See also [`ClosureReport`](@ref), [`MissingDep`](@ref), [`load_package_image`](@ref).
"""
function verify_closure(paths::Vector{String}; check_loaded::Bool=true)
    msgs = String[]
    parse_ok = true

    # 1. Gather the identities the set provides, from each image's worklist
    #    (a split `.so` borrows its worklist from the companion `.ji`).
    provided = Dict{String, Set{UInt128}}()
    headers = Tuple{String, PkgImageHeader}[]
    for p in paths
        if !isfile(p)
            push!(msgs, "file does not exist: $p"); parse_ok = false; continue
        end
        hdr = try
            parse_header(p)
        catch e
            push!(msgs, "parse failed ($p): " * sprint(showerror, e)); parse_ok = false; continue
        end
        push!(headers, (p, hdr))
        for w in _effective_worklist(hdr, p)
            push!(get!(Set{UInt128}, provided, w.name), _provided_build_id(hdr, w))
        end
    end
    nprovided = sum(length, values(provided); init=0)

    # 2. Check every non-sysimage dependency reference against the provided set
    #    and (optionally) the loaded universe.
    missing_deps = MissingDep[]
    nrequired = 0
    for (p, hdr) in headers
        for dep in hdr.required_modules
            _is_sysimage_dep(dep) && continue
            nrequired += 1
            bid = (UInt128(dep.build_id_hi) << 64) | UInt128(dep.build_id_lo)

            in_set = get(provided, dep.name, nothing)
            (in_set !== nothing && bid in in_set) && continue                 # (a) another image
            (check_loaded && _find_loaded_module(dep.name, bid) !== nothing) && continue  # (b) loaded

            # Unsatisfied — classify absent vs mixed-lineage.
            others = UInt128[]
            in_set === nothing || for b in in_set
                b == bid || push!(others, b)
            end
            if check_loaded
                for b in _loaded_build_ids(dep.name)
                    (b == bid || b in others) || push!(others, b)
                end
            end
            reason = isempty(others) ? :absent : :mixed_lineage
            push!(missing_deps, MissingDep(p, dep.name, dep.uuid, bid, reason, others))
        end
    end

    # 3. Human-readable diagnostics, one per missing dep.
    for m in missing_deps
        if m.reason == :mixed_lineage
            got = join(("0x" * string(b, base=16, pad=32) for b in m.other_lineages), ", ")
            push!(msgs, "MIXED LINEAGE: $(m.name) required @ 0x$(string(m.build_id, base=16, pad=32)) " *
                        "by $(m.required_by), but the set/loaded universe offers it @ [$got] " *
                        "— loading this mix risks a segfault in jl_validate_binding_partition")
        else
            push!(msgs, "ABSENT: $(m.name) @ 0x$(string(m.build_id, base=16, pad=32)) " *
                        "required by $(m.required_by) is provided by no image in the set and no loaded module")
        end
    end

    ok = parse_ok && isempty(missing_deps)
    return ClosureReport(ok, copy(paths), nprovided, nrequired, missing_deps, msgs)
end

# ── Internal helpers ────────────────────────────────────────

# The worklist that identifies the package(s) in this image. A split `.so`
# header carries none (it lives only in the companion `.ji`), so resolve it
# from the sibling `.ji` when the header's own worklist is empty. This lets
# `load_package_image(some.so)` work directly instead of erroring on pkgname /
# PkgId inference.
function _effective_worklist(hdr::PkgImageHeader, path::String)
    isempty(hdr.worklist) || return hdr.worklist
    if hdr.pkgimage || _is_shared_library(path)
        ji = splitext(path)[1] * ".ji"
        if isfile(ji) && abspath(ji) != abspath(path)
            return parse_header(ji).worklist
        end
    end
    return hdr.worklist
end

function _infer_pkgid(hdr::PkgImageHeader, path::String)
    wl = _effective_worklist(hdr, path)
    isempty(wl) && error("Cannot infer PkgId: empty worklist in $path " *
                         "(and no companion .ji with a worklist was found)")
    w = wl[end]
    return Base.PkgId(w.uuid, w.name)
end

function _has_companion_so(ji_path::String)
    # Check for .so/.dylib/.dll companion
    base = splitext(ji_path)[1]
    for ext in (".so", ".dylib", ".dll")
        isfile(base * ext) && return true
    end
    return false
end

function _find_ocachepath(ji_path::String)
    base = splitext(ji_path)[1]
    for ext in (".so", ".dylib", ".dll")
        p = base * ext
        isfile(p) && return p
    end
    # Fall back to the .ji path itself if no companion found
    return ji_path
end
