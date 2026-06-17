# CLI Reference

JuliaStaticData includes `jlsd-remap`, a standalone C binary for `.ji` file inspection
and build-ID remapping. It has no Julia dependency and can be used in CI pipelines,
Docker builds, or any environment with a C runtime.

## Building

```bash
cd JuliaStaticData.jl/csrc
make        # builds build/jlsd-remap, build/libjlstaticdata.{so,a}
```

Requirements: C99 compiler (gcc, clang). No external dependencies.

## Commands

### Inspect

Print a parsed `.ji` file header:

```bash
jlsd-remap --inspect --input path/to/Foo.ji
```

Output:

```
Julia Package Image Header
==========================
  Format version:  12
  Pointer size:    8
  Julia version:   1.12.6
  Git:             HEAD @ 15346901f0...
  Platform:        Linux / x86_64
  Pkgimage:        false
  Cache flags:     0xa3
  Checksum:        0xf82efaed (magic: 0xfafbfcfd)
  Data range:      0 .. 0 (0 bytes)

Worklist (1 modules):
  Downloads  build_id.lo=0x323bb62f25162e7a

Required modules (21 dependencies):
  Core  build_id=0xfdfcfbfaa980b2d4978d542146808636
  Base  build_id=0xfdfcfbfaa980b2d40bc5d8dcad34c7de
  ...
```

### Validate

Check header integrity (magic bytes, format version, checksum marker):

```bash
jlsd-remap --validate --input path/to/Foo.ji
# Output: VALID: path/to/Foo.ji (format v12, 21 deps)
```

### Remap

Patch dependency build IDs in a `.ji` file:

```bash
jlsd-remap \
    --input Foo.ji \
    --output Foo_remapped.ji \
    --remap "Core=deadbeefcafe1234:0123456789abcdef" \
    --remap "Base=aabbccdd11223344:5566778899aabbcc"
```

The `--remap` format is `ModuleName=hi:lo` where `hi` and `lo` are hexadecimal
uint64 values (no `0x` prefix).

Multiple `--remap` entries can be specified (up to 64).

### Remap Worklist

To also patch the worklist module's `build_id.lo`:

```bash
jlsd-remap \
    --input Foo.ji \
    --output Foo_remapped.ji \
    --remap "Foo=0:aaaaaaaaaaaaaaaa" \
    --remap-worklist
```

### In-Place Patching

Set `--output` to the same path as `--input`:

```bash
jlsd-remap --input Foo.ji --output Foo.ji --remap "Core=aa:bb"
```

## Options Summary

| Option | Description |
|--------|-------------|
| `--input <FILE>` | Input `.ji` file (required) |
| `--output <FILE>` | Output file; defaults to input (in-place) |
| `--remap <SPEC>` | Remap spec: `ModuleName=hi:lo` (repeatable) |
| `--remap-worklist` | Also patch worklist `build_id.lo` |
| `--inspect` | Print header and exit |
| `--validate` | Validate header and exit |
| `--quiet` | Suppress informational output |
| `--version` | Print version |
| `--help` | Show help |

## C Library API

The CLI is built on `libjlstaticdata`, which can be linked into other C/C++ programs.
See `csrc/libjlstaticdata.h` for the full API:

- `jlsd_header_parse(path, &hdr)` — Parse a `.ji` header
- `jlsd_header_free(&hdr)` — Free parsed header
- `jlsd_header_dump(&hdr, stdout)` — Print header
- `jlsd_header_validate(&hdr)` — Validate integrity
- `jlsd_remap(input, output, remaps, n, flags)` — Remap build IDs

Error codes: `JLSD_OK` (0), `JLSD_ERR_IO` (-1), `JLSD_ERR_BAD_MAGIC` (-2),
`JLSD_ERR_BAD_FORMAT` (-3), `JLSD_ERR_BAD_BOM` (-4), `JLSD_ERR_ALLOC` (-5).
