# User Guide

## Inspecting Package Images

Every `.ji` file has a header recording the package identity, its dependencies, and their
exact build IDs. Use [`parse_header`](@ref) to read it and [`inspect`](@ref) to display it:

```julia
using JuliaStaticData

hdr = parse_header("compiled/v1.12/Downloads/abc123.ji")
inspect(hdr)
```

Output:

```
Julia Package Image Header
==========================
  File:            compiled/v1.12/Downloads/abc123.ji
  Format version:  12
  Pointer size:    8
  Julia version:   1.12.6
  Pkgimage:        false
  Checksum:        0xf82efaed (magic: 0xfafbfcfd)

Worklist (1 modules):
  Downloads uuid=f43a241f-... build_id.lo=0x323bb62f25162e7a

Required modules (21 dependencies):
  Core uuid=00000000-... build_id=0xfdfcfbfaa980b2d4978d542146808636
  Base uuid=00000000-... build_id=0xfdfcfbfaa980b2d40bc5d8dcad34c7de
  ...
```

Split images (`.so` files) are also supported — the parser scans for the embedded JI
header with `pkgimage=true`:

```julia
hdr_so = parse_header("compiled/v1.12/Downloads/abc123.so")
# hdr_so.pkgimage == true
# hdr_so.data_start, hdr_so.data_end point to the embedded data blob
```

### Programmatic Access

The [`PkgImageHeader`](@ref) struct gives you direct access to all header fields:

```julia
hdr = parse_header("Foo.ji")

# Package being serialized
for w in hdr.worklist
    println(w.name, " uuid=", w.uuid, " build_id.lo=", w.build_id_lo)
end

# Dependencies this package links against
for dep in hdr.required_modules
    full_id = UInt128(dep.build_id_hi) << 64 | dep.build_id_lo
    println(dep.name, " build_id=", string(full_id, base=16))
end
```

## Remapping Build IDs

### The Problem

Every Julia installation creates sysimage modules (Core, Base, stdlibs) with unique
build IDs derived from `bitmix(jl_hrtime() + count, jl_rand())` (`module.c:512`).
Package images record these exact IDs. Moving a `.ji` file to a different Julia
installation fails because the IDs don't match.

### The Solution

[`remap`](@ref) patches the build-ID fields in the `.ji` header, making it compatible
with a target installation:

```julia
using JuliaStaticData

# Step 1: Get target build IDs from the target Julia session
# (run on the target machine)
target_core_id = Base.module_build_id(Core)   # UInt128
target_base_id = Base.module_build_id(Base)   # UInt128

# Step 2: Remap the .ji file
remap("Foo.ji", "Foo_remapped.ji", [
    RemapSpec("Core", nothing, target_core_id),
    RemapSpec("Base", nothing, target_base_id),
    # ... repeat for all sysimage dependencies
])
```

### Remapping an Entire Dependency Chain

For a package with many transitive dependencies, build a remap spec for every
module listed in `required_modules`:

```julia
hdr = parse_header("Foo.ji")

# Build a remap table from the target session's module build IDs
# target_ids is a Dict{String, UInt128} mapping module names to target build IDs
remaps = [RemapSpec(dep.name, dep.uuid, target_ids[dep.name])
          for dep in hdr.required_modules]

remap("Foo.ji", "Foo_target.ji", remaps)
```

### In-Place Remapping

Use [`remap!`](@ref) to modify a file in place:

```julia
remap!("Foo.ji", remaps)
```

### Worklist Remapping

By default, only dependency build IDs (Section 4 of the header) are patched.
To also patch the worklist module's `build_id.lo` (Section 2), pass
`remap_worklist=true`:

```julia
remap("Foo.ji", "Foo_out.ji", remaps; remap_worklist=true)
```

!!! warning
    Worklist remapping patches the header but NOT the `build_id.lo` inside the
    serialized module struct in the data blob. This creates an inconsistency that
    may cause issues with method root block keying. For full consistency, use the
    Layer 2 `reserialize()` function (future).

### Checksum Preservation

The CRC32C checksum in the header covers only the **data blob**, not the header
fields. Since `remap` only patches header bytes, the checksum is automatically
preserved. No recomputation is needed.

## Loading Remapped Images

### Parallel Loading Path

[`load_package_image`](@ref) provides a loading path parallel to `Base.require`,
calling the same C deserialization functions but with caller-controlled dependency
resolution:

```julia
using JuliaStaticData

mod = load_package_image("Foo_remapped.ji")
```

The function:
1. Parses the header to discover dependencies
2. Resolves each dependency against loaded modules via [`resolve_all_deps`](@ref)
3. Calls `ccall(:jl_restore_package_image_from_file, ...)` or
   `ccall(:jl_restore_incremental, ...)`
4. Registers the module with `Base.register_restored_modules`
5. Returns the loaded `Module`

### Manual Dependency Resolution

For finer control, resolve dependencies yourself:

```julia
hdr = parse_header("Foo_remapped.ji")
deps = [resolve_dep(entry) for entry in hdr.required_modules]
mod = load_package_image("Foo_remapped.ji"; depmods=deps)
```

[`resolve_dep`](@ref) searches `Base.loaded_precompiles`, `Base.loaded_modules`,
and the well-known modules (Core, Base, Main) for a module matching the given
name and build ID.

### Loading Without Registration

To load a module without registering it with Base (useful for inspection):

```julia
mod = load_package_image("Foo.ji"; register=false)
# mod is usable but not visible to `using` or `import`
```

## Transparent Loading (Hooks)

!!! warning "Experimental and Fragile"
    The hooks mechanism monkey-patches internal Base functions. It works on Julia
    1.12.x but may break on future versions. Prefer the parallel loading path for
    production use.

[`install_hooks!`](@ref) intercepts the standard `using`/`import` path to
transparently handle remapped images:

```julia
using JuliaStaticData

install_hooks!(;
    remap_table=Dict("Core" => target_core_id, "Base" => target_base_id),
    bypass_staleness=true,
)

using Foo  # transparently loads with remapped build IDs

uninstall_hooks!()  # restore original behavior
```

## Protection Analysis

[`analyze_protection`](@ref) scans a package image for information leakage:

```julia
report = analyze_protection("Foo.ji")
```

Output:

```
Protection Analysis: Foo.ji
============================================================
  Source text present:    YES (HIGH RISK)
  Julia IR present:      YES (assumed)
  Debug info present:    YES (assumed)
  Metadata present:      YES (assumed)
  ELF symbols present:   no / N/A

Recommendations:
  1. Strip source text: zero srctextpos section or use strip_image()
  2. Strip IR: rebuild with --strip-ir to remove CodeInfo/inferred code
  3. Strip metadata: rebuild with --strip-metadata to remove file paths/line numbers
  4. Consider --trim=safe to remove unreachable code
  5. Note: method names, type names, and module structure are ALWAYS preserved
```

[`strip_image`](@ref) creates a hardened copy with randomized build IDs:

```julia
strip_image("Foo.ji", "Foo_stripped.ji"; randomize_build_ids=true)
```

See [Source Code Protection](@ref) for a thorough analysis of what can and cannot
be hidden in Julia package images.
