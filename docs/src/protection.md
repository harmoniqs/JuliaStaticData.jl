# Source Code Protection

This document analyzes what information is recoverable from Julia package images and
what mitigations are available. It is intended for developers distributing commercial
or IP-sensitive Julia code.

## The Short Answer

Julia package images **cannot fully hide source code**. Method names, type names, type
signatures, and module structure are always preserved regardless of stripping options.
These are required by Julia's runtime for dispatch, error reporting, and the GC.

What *can* be hidden: source text, Julia IR, file paths, line numbers, variable names,
debug info, unreachable code, and ELF function symbols.

## Information Inventory

### What's in a .ji File

| Information | Default | `--strip-ir` | `--strip-metadata` | Both |
|---|---|---|---|---|
| Source text (.jl files) | Present | Present | Present | Present |
| Julia IR (CodeInfo) | Present | **Removed** | Partial | **Removed** |
| Inferred IR (optimized) | Present | **Removed** | Present | **Removed** |
| Method names | Present | Present | Present | Present |
| Type names and signatures | Present | Present | Present | Present |
| Module hierarchy | Present | Present | Present | Present |
| Source file paths | Present | Present | **Removed** | **Removed** |
| Line numbers | Present | Present | **Removed** | **Removed** |
| Local variable names | Present | Present | **Replaced with "?"** | **Replaced** |
| Debug info | Present | Present | **Removed** | **Removed** |
| Call graph (edges) | Present | **Removed** | Present | **Removed** |
| Binding names | Present | Present | Present | Present |
| Build IDs | Present | Present | Present | Present |

Source: `staticdata.c:2728-2798` (stripping logic)

### What's in a .so File (Additional)

| Information | Default | After `strip -s` |
|---|---|---|
| Compiled machine code | Present | Present |
| ELF symbol table (~1000+ entries) | Present | **Removed** (~60 remain) |
| `julia_*` function name symbols | Present | **Removed** |
| Dynamic symbols (libjulia ABI) | Present (59) | Present (59) |
| Embedded data blob (everything in .ji) | Present | Present |

Source: `aotcompile.cpp:743` (symbol encoding), `aotcompile.cpp:2073` (data blob embedding)

## Threat Model

### Level 1: Julia REPL User (minutes)

After loading the package, an attacker can use:
- `names(M; all=true)` — all exported and internal binding names
- `methods(f)` — all method signatures with type parameters
- `fieldnames(T)` — struct field names
- `@code_lowered f(args...)` — Julia IR (unless `--strip-ir`)
- `@code_typed f(args...)` — type-inferred IR (unless `--strip-ir`)
- `@which f(args...)` — source file and line (unless `--strip-metadata`)

**Mitigated by**: `--strip-ir` (removes IR), `--strip-metadata` (removes source locations)

**Not mitigated**: method names, type names, struct fields, type signatures

### Level 2: Binary File Inspector (hours)

Without loading the package:
- `strings Foo.ji` — recovers source text, method names, type names, paths
- `strings Foo.so` — recovers embedded data strings + ELF symbol names
- `nm Foo.so` — lists all function names (`julia_Downloader_3451`, etc.)
- Hex editor — finds header metadata, build IDs, dependency names

**Mitigated by**: zeroing source text section, `strip -s` on .so

**Not mitigated**: embedded data blob in .so contains method/type names as binary data

### Level 3: Julia Internals Expert (days)

Using tools like JuliaStaticData or custom parsers:
- Parse the data blob to extract all serialized objects
- Reconstruct type definitions, method tables, binding tables
- Extract IR from CodeInfo objects (unless stripped)
- Map the full module dependency graph

**Mitigated by**: `--strip-ir` (removes CodeInfo), `--trim=safe` (removes unreachable code)

**Not mitigated**: type definitions, method names, binding names (always serialized)

### Level 4: Reverse Engineer (weeks)

Standard binary analysis of the `.so`:
- Disassemble `.text` section
- Reconstruct control flow and algorithms
- Identify library calls via PLT/GOT entries

**Difficulty**: comparable to reverse engineering any compiled binary (C, Rust, etc.)

## Mitigation Options

### Tier 1: Source Text Removal (Highest Impact, Easiest)

Source text is stored at a known offset in the `.ji` file (`srctextpos` section).
It can be zeroed without affecting package functionality.

```julia
# The source text section is only used by Base.read_srctext for display
# It is NOT needed for loading or execution
```

Impact: eliminates the trivial `strings Foo.ji | grep 'function'` attack.

### Tier 2: IR Stripping (`--strip-ir`)

Build with:
```bash
julia --strip-ir --output-ji=Foo.ji --output-o=Foo.o ...
```

Removes from `staticdata.c:2754-2776`:
- `jl_method_t.source` → set to `jl_nothing`
- `jl_method_t.roots` → set to NULL
- `jl_code_instance_t.inferred` → set to `jl_nothing`
- `jl_code_instance_t.edges` → set to empty svec

**Consequence**: `@code_lowered` and `@code_typed` return nothing. Runtime JIT for
methods without compiled native code will fail.

### Tier 3: Metadata Stripping (`--strip-metadata`)

Build with:
```bash
julia --strip-metadata --output-ji=Foo.ji --output-o=Foo.o ...
```

Removes from `staticdata.c:2778-2798`:
- `jl_method_t.file` → empty symbol
- `jl_method_t.line` → 0
- `jl_method_t.debuginfo` → `jl_nulldebuginfo`
- `CodeInfo.slotnames` → replaced with "?"

**Consequence**: stack traces show `"":0` instead of file:line. `@which` returns no path.

### Tier 4: ELF Symbol Stripping

```bash
strip -s Foo.so
```

Removes ~1,097 of ~1,156 symbols. The 59 dynamic symbols (libjulia ABI) cannot be
removed — they are needed for the dynamic linker.

### Tier 5: Dead Code Elimination (`--trim=safe`)

```bash
julia --experimental --trim=safe --output-ji=Foo.ji ...
```

Removes all code not provably reachable from annotated entry points:
- Module bindings reduced to modules + `__init__` + runtime essentials
- Method tables rebuilt with only compiled methods
- Backedges and scanned_methods cleared

**Consequence**: the package can only be used through its declared entry points.
Cannot be used as a general-purpose library.

**Limitation**: cannot verify dynamic dispatch (`invokelatest`, `Core._apply`, etc.)
See `Compiler/src/verifytrim.jl:235-250` for the unverifiable constructs.

### Combined: Maximum Protection

Build with all mitigations:
```bash
julia --experimental --trim=safe --strip-ir --strip-metadata \
    --output-ji=Foo.ji --output-o=Foo.o ...
# Then:
strip -s Foo.so
# Then zero source text in .ji via JuliaStaticData:
julia -e 'using JuliaStaticData; strip_image("Foo.ji", "Foo.ji")'
```

**What remains**: method names, type names, type signatures, module structure,
compiled machine code, 59 dynamic ELF symbols.

## The Fundamental Limitation

Julia's type system requires self-describing objects. Every type carries its name,
field names, and supertype chain. Every method carries its name and signature.
These are used by:

- Multiple dispatch (needs type names for method selection)
- Error messages (needs method/type names for reporting)
- The GC (needs type layout for traversal)
- Serialization (needs type identity for consistency)

**No amount of stripping can remove this information** while keeping the package
functional within Julia. If hiding the API surface is a hard requirement, consider:

1. **PackageCompiler.jl** with `--trim=safe` — produces a standalone executable
   with only entry-point functions visible
2. **C-callable interface** — expose only `@ccallable` functions, keeping Julia
   internals in the binary
3. **Service architecture** — run Julia server-side, expose only an API (HTTP, gRPC)

## Portability vs Security Summary

| Strategy | Portability | Security | Build-ID Remappable? |
|----------|-------------|----------|---------------------|
| .ji only (pkgimages=0) | High | Low | Yes (trivial) |
| .ji + .so (default) | Medium | Medium | .ji yes, .so difficult |
| .so only (custom loader) | Low | Medium-High | Requires Layer 2 |
| Stripped .so + minimal .ji | Low | Highest achievable | .ji yes, .so requires Layer 2 |

There is no format that provides both full portability and strong security. This is a
fundamental tension: portable formats must be self-describing, and self-describing
formats are introspectable.
