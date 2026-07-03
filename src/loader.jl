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
    # Search loaded_precompiles first (may have multiple versions)
    for (pkg, mods) in Base.loaded_precompiles
        for mod in mods
            if String(nameof(mod)) == name && Base.module_build_id(mod) == build_id
                return mod
            end
        end
    end

    # Fall back to loaded_modules
    for (pkg, mod) in Base.loaded_modules
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

    error("Cannot resolve dependency: module '$name' with build_id=0x$(string(build_id, base=16, pad=32)) not found in loaded modules")
end

"""
    load_package_image(path::String;
                       depmods::Vector{Any}=Any[],
                       register::Bool=true,
                       run_init::Bool=true,
                       pkgname::Union{String,Nothing}=nothing) -> Module

Load a package image from `path`, bypassing Base's staleness checks.

# Arguments
- `path`: Path to `.ji` or `.so` file
- `depmods`: Pre-resolved dependency modules. Must match the header's required_modules.
  Use `resolve_dep` or `resolve_all_deps` to construct this array.
- `register`: If true, register loaded modules with Base via `register_restored_modules`.
- `run_init`: If true, run `__init__` callbacks. Only meaningful if `register=true`.
- `pkgname`: Package name (inferred from header if not provided).
"""
function load_package_image(path::String;
                            depmods::Vector{Any}=Any[],
                            register::Bool=true,
                            run_init::Bool=true,
                            pkgname::Union{String,Nothing}=nothing)
    hdr = parse_header(path)

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
