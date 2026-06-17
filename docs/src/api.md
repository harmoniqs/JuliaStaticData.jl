# API Reference

## Types

```@docs
PkgImageHeader
WorklistEntry
DepModEntry
RemapSpec
VerificationReport
ProtectionReport
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
