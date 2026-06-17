# Julia Internals

This document explains how Julia's package precompilation and loading infrastructure
works, providing the context needed to understand JuliaStaticData's operations.

All references are to Julia v1.12.6 source code.

## The Precompilation Pipeline

When Julia precompiles a package, three code paths converge:

### 1. Julia Side: `compilecache` (`loading.jl:3193`)

The master process:
1. Builds `concrete_deps` from `_concrete_dependencies` + `loaded_modules` (line 3203)
   - Core, Base, Main are **excluded** (line 3205)
   - Loaded stdlibs and packages are **included** with their `module_build_id`
2. Spawns a worker process via `create_expr_cache` (line 3062) with
   `--output-ji` and `--output-o` flags
3. The worker executes `include_package_for_output` (line 3003):
   - Sets `Base._concrete_dependencies` (line 3016)
   - Loads the package source via `include` (line 3028)
   - Calls `ccall(:jl_set_newly_inferred)` to track inference results (line 3026)
4. On worker exit, `jl_write_compiler_output` (precompile.c:98) is called

### 2. C Side: `jl_create_system_image` (`staticdata.c:3483`)

The serialization orchestrator:
1. Selects compilation path:
   - `jl_precompile_worklist()` for incremental builds (line 3524)
   - `jl_precompile()` for fresh sysimages (line 3543)
   - `jl_precompile_trimmed()` for `--trim` mode (line 3541)
2. **Disables concurrent Julia execution** (line 3548) — serialization is single-threaded
3. Writes the header via `jl_write_header_for_incremental` (line 3528)
4. Serializes the object graph via `jl_save_system_image_to_stream` (line 3564)
5. Backfills the checksum, `data_start`, `data_end` (lines 3575-3579)

### 3. C++ Side: `jl_dump_native_impl` (`aotcompile.cpp:1984`)

The native code emitter (for `.so` files):
1. Receives compiled LLVM modules from `jl_emit_native_impl` (line 768)
2. Partitions across N threads for parallel optimization (line 1242)
3. Writes object files, bitcode, and metadata to an archive
4. Embeds the data blob as `jl_system_image_data` (line 2073)

## The Loading Pipeline

### Julia Side: `require` (`loading.jl:2359`)

```
require(mod)
  -> __require(mod)
  -> _require_prelocked(uuidkey)
  -> __require_prelocked(pkg, env)
     -> _require_search_from_serialized(pkg, sourcepath, build_id)
        -> find_all_in_cache_path(pkg)          # discover .ji files
        -> stale_cachefile(pkg, build_id, ...)   # 10+ staleness checks
        -> _tryrequire_from_serialized(pkg, path, ocachepath)
           -> parse_cache_header(io, path)       # read header on Julia side
           -> recursively load deps via _tryrequire_from_serialized
           -> _include_from_serialized(pkg, path, ocachepath, depmods)
              -> ccall(:jl_restore_package_image_from_file, ...) # split image
              OR ccall(:jl_restore_incremental, ...)              # .ji only
              -> register_restored_modules(sv, pkg, path)
                 -> run __init__ callbacks
```

### C Side: `jl_restore_package_image_from_file` (`staticdata.c:4541`)

1. `jl_dlopen(fname)` — memory-map the `.so` (line 4543)
2. `get_image_buf()` — extract data sections (line 4556)
3. `jl_restore_package_image_from_stream` (line 4392):
   - `jl_validate_cache_file` — magic, version, architecture checks (line 4399)
   - `read_verify_mod_list` — **exact build-ID match** for every dependency (line 4388)
   - CRC32C verification of data blob (line 4425)
   - `jl_restore_system_image_from_stream_` — full deserialization (line 4434)
   - `jl_copy_roots` — method root block insertion (line 4439)
   - `jl_activate_methods` — world counter management (line 4461)

## The Linkage Mechanism

This is the key architectural insight that makes build-ID remapping feasible.

### Indices, Not IDs

The serialized data blob does **not** contain build IDs. External references use
a two-level indirection through positional indices:

```
serialized pointer  ->  depsidx (index into depmods array)
                            |
                            v
                 buildid_depmods_idxs[depsidx]  ->  blob_index
                            |
                            v
                 jl_linkage_blobs.items[2*blob_index]  ->  memory address
```

This is implemented in `add_external_linkage` (`staticdata.c:1204`):
- `external_blob_index(v)` finds which loaded image contains the pointer (Eytzinger tree)
- `buildid_depmods_idxs[blob_idx]` maps to the depmods array position
- The depmods index is encoded as a `SysimageLinkage` or `ExternalLinkage` relocation tag

### Why This Enables Remapping

Build IDs appear **only in the header** — in `write_mod_list` (dependency verification)
and `write_worklist_for_header` (worklist identity). The data blob uses positional
indices that are reconstructed at load time from the `depmods` array order.

Therefore, patching the header's build IDs is sufficient to make an image load against
modules with different build IDs, as long as the modules are structurally compatible.

## Sysimage Module Build IDs

All sysimage modules (Core, Base, Main, and all stdlibs) share the same `build_id.hi`
because they are part of the same serialized image, sharing the same CRC32C checksum.
Each has a unique `build_id.lo` from its creation timestamp.

Empirically verified on Julia 1.12.6:
- `Core.build_id.hi = Base.build_id.hi = Main.build_id.hi = LinearAlgebra.build_id.hi`
  = `0xfdfcfbfaa980b2d4`
- Each `build_id.lo` is unique (e.g., Core = `0x978d...`, Base = `0x0bc5...`)

This means a single Julia build produces a consistent set of build IDs. All package
images compiled on that build share the same sysimage dependency IDs. When remapping
for a target installation, you need the target's sysimage build IDs — extractable via:

```julia
# Run on target machine:
for mod in (Core, Base, Main)
    println(nameof(mod), " = ", repr(Base.module_build_id(mod)))
end
```

## Method Table Consistency

The `worklist_key` (`staticdata_utils.c:73`) is `topmod->build_id.lo`. It is used
to key method root blocks during serialization (`staticdata.c:944-960`) and
deserialization (`staticdata_utils.c:770`).

If you remap a worklist module's `build_id.lo` in the header but not in the data blob,
the root block keys won't match. This is safe for **dependency-only remapping** (the
common case) because only the dependency modules' build IDs are in the `write_mod_list`
section — the worklist module's `build_id.lo` in the data blob is not checked against
the header.

For full consistency when remapping the worklist module itself, use Layer 2
(re-serialization), which temporarily patches `mod->build_id.lo` before calling
`jl_create_system_image`, ensuring the data blob, root blocks, and header are all
consistent.
