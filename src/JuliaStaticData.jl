"""
    JuliaStaticData

Low-level toolkit for Julia package image (`.ji`/`.so`) manipulation.

Provides:
- **Header inspection**: Parse and display `.ji` file headers
- **Build-ID remapping**: Patch dependency build-IDs so images load against
  different builds of the same packages
- **Custom loading**: Load remapped images with caller-controlled dependency
  resolution, bypassing Base's staleness checks
- **Protection analysis**: Catalog information leakage from package images
  and recommend mitigations

# Quick Start

```julia
using JuliaStaticData

# Inspect a package image header
inspect("~/.julia/compiled/v1.12/Foo/abc123.ji")

# Remap a dependency's build-id
remap("Foo.ji", "Foo_remapped.ji", [
    RemapSpec("SomePackage", nothing, target_build_id)
])

# Load the remapped image
mod = load_package_image("Foo_remapped.ji")
```

See also: [`parse_header`](@ref), [`remap`](@ref), [`load_package_image`](@ref),
[`analyze_protection`](@ref).
"""
module JuliaStaticData

using Base: UUID
using CRC32c: crc32c

# Types (must be loaded first — other modules depend on these)
include("types.jl")

# Header parsing (pure Julia)
include("header.jl")

# Build-ID remapping (pure Julia, patches file bytes)
include("remap.jl")

# Custom loading path (parallel to Base)
include("loader.jl")

# Identity stamping (nonce + self-consistent CRC) and pre-load verification
include("identity.jl")

# Optional monkey-patch mode
include("hooks.jl")

# Protection analysis
include("protection.jl")

# ── Exports ─────────────────────────────────────────────────

# Types
export PkgImageHeader, WorklistEntry, DepModEntry
export RemapSpec
export VerificationReport, ProtectionReport

# Header
export parse_header, inspect

# Remap
export remap, remap!

# Loader
export load_package_image, resolve_dep, resolve_all_deps

# Identity stamping + verification
export stamp_identity!, dry_verify

# Hooks
export install_hooks!, uninstall_hooks!

# Protection
export analyze_protection, strip_image

end # module JuliaStaticData
