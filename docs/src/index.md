# JuliaStaticData.jl

Low-level toolkit for Julia package image (`.ji`/`.so`) manipulation.

## What It Does

Julia precompiles packages into binary cache files (`.ji` and `.so`). These files
contain serialized Julia objects, compiled native code, and metadata that ties them
to the exact Julia installation they were built on. JuliaStaticData gives you
direct access to this machinery:

- **Inspect** package image headers: see dependencies, build IDs, format metadata
- **Remap** build IDs: make a package image loadable against a different Julia
  installation (same version, different build)
- **Load** remapped images programmatically, bypassing the standard staleness checks
- **Analyze** information leakage from package images and apply mitigations

## Why You Might Need This

Julia package images are **not portable** across installations. Two copies of Julia
1.12.6 built at different times produce different sysimage build IDs (`module.c:512`
uses `jl_hrtime() + jl_rand()`). Every package compiled on installation A is
incompatible with installation B, even though the Julia version is identical.

This means:
- CI caches cannot be shared across runners with different Julia builds
- Precompiled packages cannot be deployed without the exact Julia binary
- Custom sysimages are tied to one specific Julia build

JuliaStaticData breaks this barrier by letting you rewrite the build IDs in package
image headers, making them compatible with any target installation.

## Architecture

```
                    JuliaStaticData.jl  (Julia package)
                    |   parse_header, inspect        -- header inspection
                    |   remap, remap!                -- build-id patching
                    |   load_package_image            -- custom loading
                    |   analyze_protection            -- security analysis
                    |
                    libjlstaticdata  (C library)
                    |   Layer 1: standalone .ji patcher (no libjulia dep)
                    |   Layer 2: libjulia-linked reserializer (future)
                    |
                    jlsd-remap  (CLI binary)
                        --inspect, --validate, --remap
```

## Quick Start

```julia
using JuliaStaticData

# Inspect a package image
inspect("/path/to/compiled/v1.12/Foo/abc123.ji")

# Remap a dependency to a different build-id
remap("Foo.ji", "Foo_remapped.ji", [
    RemapSpec("Core", nothing, target_core_build_id),
    RemapSpec("Base", nothing, target_base_build_id),
])

# Load the remapped image
mod = load_package_image("Foo_remapped.ji")
```

## Target Julia Versions

JuliaStaticData supports Julia 1.12.x and 1.13.x (both use `JI_FORMAT_VERSION = 12`).
The core build-ID architecture is preserved on Julia master (future 1.14-dev); line
numbers shift but the format is structurally identical.

## Contents

```@contents
Pages = ["guide.md", "cli.md", "api.md", "format.md", "internals.md", "protection.md"]
Depth = 2
```
