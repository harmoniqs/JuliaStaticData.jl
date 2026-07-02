# JuliaStaticData.jl

Low-level toolkit for Julia package image (`.ji` / `.so`) manipulation: inspect
them, rewrite their dependency build-IDs, load them outside Base's normal
staleness checks, and analyze what they leak.

Julia's precompilation caches ("package images") are keyed by **build-IDs**: a
package image records the exact build-ID of every dependency image it was
compiled against, and Base refuses to load an image whose recorded dependencies
don't match what's on disk. That makes package images precise — and makes them
nearly impossible to relocate: an image built on one machine won't load against
the same package versions precompiled on another machine.

JuliaStaticData removes that restriction, deliberately and explicitly. It is
the machinery for **shipping compiled Julia code without shipping its
sources**: distribute a package as its compiled image, let the consumer
precompile the (public) dependencies locally, remap the shipped image's
dependency build-IDs to match, and load it.

## What it provides

- **Header inspection** — parse and display `.ji` package image headers
  (`parse_header`, `inspect`): worklist, dependency module list, build-IDs,
  checksums.
- **Build-ID remapping** — patch dependency build-IDs in an image header so it
  loads against different builds of the same packages (`remap`, `remap!`).
  Header-only patching; the data blob and its CRC32C checksum are untouched.
- **Custom loading** — load a (remapped) package image with caller-controlled
  dependency resolution, bypassing Base's staleness checks
  (`load_package_image`, `resolve_dep`, `resolve_all_deps`). Calls the same C
  deserialization entry points Base uses.
- **Hooks** — optional monkey-patch mode that installs the custom resolution
  into Base's loading path (`install_hooks!`, `uninstall_hooks!`).
- **Protection analysis** — catalog what a `.ji`/`.so` leaks (source text,
  Julia IR, debug info, symbol tables) and strip it
  (`analyze_protection`, `strip_image`).

## Quick start

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

## C library and CLI

`csrc/` contains a small C implementation of the header parser and remapper
(`libjlstaticdata`) plus a standalone CLI, for use in build pipelines that
shouldn't boot Julia:

```
jlsd-remap --inspect --input Foo.ji
jlsd-remap --input Foo.ji --output Foo_remapped.ji --remap "SomePackage=hi:lo"
```

Build with `make -C csrc`.

## Intended use: source-free package bundles

This package is the loader underneath **package-image bundles** — a
distribution format where a Julia package ships as its compiled images plus
`Project.toml`/`Manifest.toml` pins, and no source. The consumer flow:

1. Provision the exact Julia the images were built with (build-IDs are
   patch-version-specific).
2. `Pkg.instantiate()` the pinned manifest — public dependencies download and
   precompile locally.
3. Remap the shipped images' dependency build-IDs to the locally precompiled
   images.
4. `load_package_image` the result.

`strip_image` / `analyze_protection` support the complementary concern:
verifying the shipped images actually contain no source text or recoverable IR.

## Caveats

- **Julia-version-sensitive by nature.** This package reads and patches
  serialization internals; it targets Julia 1.12 (see `Project.toml` compat)
  and needs revalidation against new minor versions.
- **Remapping asserts compatibility rather than proving it.** A remapped image
  is only sound if the substituted dependency builds are ABI-compatible with
  the originals (same package version and Julia patch built locally). The
  regression tests in `test/` cover the supported flows; stepping outside them
  can crash the loading process rather than error cleanly.
- Header-only `remap` does not rewrite build-ID references inside the data
  blob or method-root keys; full reserialization is a separate (extension)
  layer.

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Harmoniqs, Inc.
