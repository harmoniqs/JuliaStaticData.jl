"""
Shared type definitions for JuliaStaticData.
"""

# ── Header types ────────────────────────────────────────────

"""
    WorklistEntry

A module entry from the worklist section of a `.ji` header.

The worklist records which modules are being serialized in this image.
Only `build_id_lo` is stored in the header; `build_id_hi` (the checksum)
is computed after the data blob is written and back-filled into the
checksum slot.
"""
struct WorklistEntry
    name::String
    uuid::Base.UUID
    build_id_lo::UInt64
    _file_offset::Int64   # byte offset of build_id_lo field in file
end

"""
    DepModEntry

A dependency module entry from the required-modules section of a `.ji` header.

Records the exact identity of each already-loaded module that the package
image links against. On load, `read_verify_mod_list` checks these fields
against the modules passed in `depmods`.
"""
struct DepModEntry
    name::String
    uuid::Base.UUID
    build_id_hi::UInt64
    build_id_lo::UInt64
    _file_offset_hi::Int64  # byte offset of build_id_hi field in file
    _file_offset_lo::Int64  # byte offset of build_id_lo field in file
end

"""
    PkgImageHeader

Parsed representation of a `.ji` package image file header.

Corresponds to the output of `write_header` (staticdata_utils.c:505) +
`jl_write_header_for_incremental` (staticdata.c:3465).

# Fields
- `format_version`: JI format version (12 for Julia 1.12/1.13)
- `pointer_size`: sizeof(void*) on the platform that created the image
- `julia_version`: Julia version string
- `git_branch`, `git_commit`: Git metadata
- `pkgimage`: Whether this is a split-image .so header
- `checksum`: Raw checksum value from header (includes 0xfafbfcfd magic in upper 32 bits)
- `data_start`, `data_end`: Byte offsets delimiting the data blob
- `cache_flags`: Compilation flags (opt level, debug level, bounds checking)
- `worklist`: Modules being serialized in this image
- `required_modules`: Dependency modules required for loading
"""
struct PkgImageHeader
    # Base header (write_header, staticdata_utils.c:505)
    format_version::UInt16
    pointer_size::UInt8
    build_uname::String
    build_arch::String
    julia_version::String
    git_branch::String
    git_commit::String
    pkgimage::Bool
    checksum::UInt64
    data_start::Int64
    data_end::Int64

    # Incremental header (jl_write_header_for_incremental, staticdata.c:3465)
    cache_flags::UInt8
    worklist::Vector{WorklistEntry}
    required_modules::Vector{DepModEntry}

    # Internal: byte range of the dependency list (opaque, for roundtripping)
    _deplist_start::Int64
    _deplist_end::Int64

    # File path this header was parsed from
    _path::String
end

# ── Remap types ─────────────────────────────────────────────

"""
    RemapSpec

Specifies a build-id remapping for a dependency module.

# Fields
- `name`: Module name to match in the header
- `uuid`: Optional UUID filter (nothing = match by name only)
- `target_build_id`: The 128-bit build-id to write (UInt128: hi<<64 | lo)
"""
struct RemapSpec
    name::String
    uuid::Union{Base.UUID, Nothing}
    target_build_id::UInt128
end

# ── Verification types ──────────────────────────────────────

"""
    VerificationReport

Result of `verify_image`, reporting which call targets are resolved
and which cannot be statically verified.
"""
struct VerificationReport
    resolved_count::Int
    unresolved::Vector{String}        # human-readable descriptions
    dynamic_dispatch::Vector{String}  # calls through _apply, invoke, invokelatest
    is_sound::Bool
end

# ── Closure verification types ──────────────────────────────

"""
    MissingDep

One unsatisfied dependency identity found by [`verify_closure`](@ref): a
`required_modules` entry of some image in the set that is provided neither by
another image in the set nor by an already-loaded module.

# Fields
- `required_by`: path of the image whose header records this dependency
- `name`, `uuid`: the dependency module's name and UUID
- `build_id`: the 128-bit identity the image records (`hi << 64 | lo`)
- `reason`:
  - `:absent` — no image in the set and no loaded module offers this module
    *name* at all. Loading would fail *cleanly* in `resolve_dep`.
  - `:mixed_lineage` — the name IS offered, but only under a **different**
    build-id. This is the dangerous case the closure law targets: mixing a
    stamped/new-lineage dep with an old-lineage consumer segfaults in
    `jl_validate_binding_partition` at restore time.
- `other_lineages`: the differing build-ids seen under `name` (evidence for a
  `:mixed_lineage` verdict; empty for `:absent`)
"""
struct MissingDep
    required_by::String
    name::String
    uuid::Base.UUID
    build_id::UInt128
    reason::Symbol
    other_lineages::Vector{UInt128}
end

"""
    ClosureReport

Result of [`verify_closure`](@ref): whether a set of package images is CLOSED
under `required_modules` — i.e. every non-sysimage/stdlib dependency identity any
image references is provided either by another image in the set or by an
already-loaded module.

Loading a set that is *not* closed risks a segfault in
`jl_validate_binding_partition` when lineages are mixed (some deps resolved from
stamped/new-lineage images, others from old-lineage ones), so this check is meant
to run BEFORE any `ccall` into the restore path.

# Fields
- `ok`: `true` iff every path parsed and every checked dependency is satisfied
- `paths`: the image set that was checked
- `provided`: number of distinct module identities offered by the set
- `required`: number of non-sysimage dependency references that were checked
- `missing`: the unsatisfied dependencies (see [`MissingDep`](@ref))
- `messages`: human-readable diagnostics (parse errors + one line per missing dep)
"""
struct ClosureReport
    ok::Bool
    paths::Vector{String}
    provided::Int
    required::Int
    missing::Vector{MissingDep}
    messages::Vector{String}
end

# ── Reference-translation types ──────────────────────────────

"""
    RefDescriptor

A **semantic** description of the object a private image's external reference
points at, in a *dependency* package image. Emitted by [`emit_sidecar`](@ref) on
the builder side (via live reflection) and resolved back to a live object by
[`translate!`](@ref) on the consumer side, so a ref word can be re-pointed at the
consumer's own rebuild of the dep without any blob archaeology.

The design finding of the bundle-v2 pipeline (leg5): 283/283 real targets are
semantically stable entities. `RefDescriptor` encodes them by *kind*:

- `:module`   — a dep root module or submodule. Resolved via
  `Base.root_module(PkgId)` then a `modpath` submodule walk.
- `:binding`  — a `Core.Binding`. Resolved via `jl_get_module_binding(owner, name)`.
- `:type`     — a named `DataType`/`UnionAll` bound to `name` in its module
  (resolved via `getglobal`).
- `:typename` — a `Core.TypeName`. Resolved as `Base.unwrap_unionall(T).name`
  for the named type `T`.
- `:function` — a function / singleton instance (resolved via `getglobal`).
- `:anchor`   — an anonymous object (`SimpleVector`, `UnionAll`, a cached tuple,
  a method signature) that has no name of its own. Described as a named `owner`
  descriptor plus a deterministic `fieldpath` walked from that owner to the
  target. This is leg5's "nearest named owner + field path" semantics.

# Fields
- `kind`: one of the symbols above
- `modpath`: submodule path from the dep root module (`Symbol[]` = the root itself)
- `name`: binding / type / typename / function name (unused, `Symbol("")`, for
  `:module` and `:anchor`)
- `owner`: for `:anchor`, the named descriptor of the object to start walking
  from; `nothing` for the named kinds
- `fieldpath`: for `:anchor`, the ordered walk steps `(op, arg)` where `op` is
  `:getfield` (`getfield(cur, arg)`), `:getindex` (`cur[arg]`, e.g. a
  `SimpleVector`), or `:property` (`getproperty(cur, arg)`, e.g. `T.parameters`)
"""
struct RefDescriptor
    kind::Symbol
    modpath::Vector{Symbol}
    name::Symbol
    owner::Union{RefDescriptor, Nothing}
    fieldpath::Vector{Tuple{Symbol, Any}}
end

RefDescriptor(kind::Symbol, modpath::Vector{Symbol}, name::Symbol) =
    RefDescriptor(kind, modpath, name, nothing, Tuple{Symbol, Any}[])

"""
    RefTarget

One distinct external-reference *target* in a private package image: a
`(depsidx, old_offset)` position in a dependency's linkage blob, the
[`RefDescriptor`](@ref) that names the live object there, and the payload
positions of every ref word that points at it (recorded for integrity).

# Fields
- `depsidx`: 1-based index into the image's `required_modules` (leg5 law:
  `depsidx d ≥ 1` = `required_modules[d]`; `depsidx 0` = sysimage, never a target)
- `dep_name`, `dep_uuid`: identity of the dependency the target lives in
- `old_offset`: byte offset of the target object into the dep's linkage blob, as
  seen on the builder side
- `descriptor`: the semantic description of the target object
- `expected_word`: the raw 64-bit ref word the builder saw (integrity check)
- `positions`: payload byte positions of the ref words pointing here
"""
struct RefTarget
    depsidx::Int
    dep_name::String
    dep_uuid::UInt128
    old_offset::Int
    descriptor::RefDescriptor
    expected_word::UInt64
    positions::Vector{Int}
end

"""
    ImageSidecar

The reference-translation sidecar for a single private package image: enough
semantic information for a consumer to re-point every cross-image reference at
its own rebuild of the dependencies. See [`emit_sidecar`](@ref).

# Fields
- `image_name`, `image_uuid`: identity of the private image (its worklist module)
- `julia_version`: the Julia version the sidecar was emitted under (translation
  is only valid for a byte-identical Julia)
- `n_words`: total pkgimage-dep ref words found in the image
- `targets`: the distinct [`RefTarget`](@ref)s (deduplicated by `depsidx`/offset)
"""
struct ImageSidecar
    image_name::String
    image_uuid::UInt128
    julia_version::String
    n_words::Int
    targets::Vector{RefTarget}
end

"""
    Sidecar

A reference-translation sidecar covering one or more private package images (see
[`emit_sidecar`](@ref), [`write_sidecar`](@ref), [`read_sidecar`](@ref)).
"""
struct Sidecar
    version::Int
    images::Vector{ImageSidecar}
end

"""
    TranslationReport

Result of [`translate!`](@ref) on one private image: how many ref words were
checked, how many were actually rewritten (only targets whose offset shifted
between builds change), which targets could not be resolved, and the new
self-consistent checksum.

# Fields
- `image`: path of the translated image
- `words_checked`: pkgimage-dep ref words examined
- `words_rewritten`, `words_unchanged`: split of `words_checked`
- `targets_resolved`: distinct targets resolved to a live consumer object
- `targets_failed`: human-readable descriptions of targets that could not be
  resolved (empty ⟺ full success)
- `old_checksum`, `new_checksum`: the image's embedded checksum before/after restamp
- `ok`: `true` iff every target resolved and the image was restamped
"""
struct TranslationReport
    image::String
    words_checked::Int
    words_rewritten::Int
    words_unchanged::Int
    targets_resolved::Int
    targets_failed::Vector{String}
    old_checksum::UInt64
    new_checksum::UInt64
    ok::Bool
end

"""
    CanonicalizeReport

Result of [`canonicalize!`](@ref): the post-load type-hash repair pass over a
freshly translated private module tree. Because `TypeName` hashes are salted with
the *builder's* per-build module nonce (`datatype.c:84`), a translated image's own
method signatures carry stale baked type hashes that break hash-consulting
dispatch paths; this pass re-interns them through live consumer-side constructors.

# Fields
- `methods_scanned`: private methods examined
- `sigs_reinterned`: signatures whose interned identity changed (pointer compare)
- `entries_reinserted`: dispatch entries re-inserted because the method table
  could no longer find the method for its own canonical signature
- `modules`: names of the private modules that were scanned
"""
struct CanonicalizeReport
    methods_scanned::Int
    sigs_reinterned::Int
    entries_reinserted::Int
    modules::Vector{String}
end

# ── Protection analysis types ───────────────────────────────

"""
    ProtectionReport

Result of `analyze_protection`, cataloging information
recoverable from a package image.
"""
struct ProtectionReport
    has_source_text::Bool
    has_ir::Bool
    has_debug_info::Bool
    has_metadata::Bool
    method_count::Int
    type_count::Int
    binding_count::Int
    elf_symbols::Bool   # .so only: ELF symbol table present
    recommendations::Vector{String}
end
