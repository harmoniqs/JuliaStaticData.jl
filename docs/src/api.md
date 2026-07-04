# API Reference

## Types

```@docs
PkgImageHeader
WorklistEntry
DepModEntry
RemapSpec
VerificationReport
ProtectionReport
ClosureReport
MissingDep
RefDescriptor
RefTarget
ImageSidecar
Sidecar
TranslationReport
CanonicalizeReport
```

## Header Inspection

```@docs
parse_header
inspect
```

## Build-ID Remapping

```@docs
remap
remap!
```

## Package Image Loading

```@docs
load_package_image
resolve_dep
resolve_all_deps
verify_closure
```

## Reference Translation

Re-point a private package image's cross-image references at a *consumer's own
rebuild* of its dependencies, using live reflection on both sides (the
productization of the bundle-v2 research pipeline, legs 4-5). The builder emits a
semantic [`Sidecar`](@ref); the consumer translates a copy of the image against
it, loads it, and runs the post-load type-hash repair.

Each target is described by a [`RefDescriptor`](@ref): a **named** entity
(`:module` / `:binding` / `:type` / `:typename` / `:function`), a nearest-named
`:anchor` + field path, or — for anonymous objects with no build-stable path
(format-spec / method-sig / type-cache svecs, interned const-data strings) — an
**order-independent content descriptor** (`:svec_content` / `:const_data`) that
the consumer re-locates in its own rebuilt dep blob by structural content match
rather than by offset or cache order.

```@docs
emit_sidecar
translate!
canonicalize!
load_translated
write_sidecar
read_sidecar
```

## Transparent Loading Hooks

```@docs
install_hooks!
uninstall_hooks!
```

## Protection Analysis

```@docs
analyze_protection
strip_image
```
