# Package Image Format

This document describes the binary layout of Julia v1.12/v1.13 package image files.
All references are to the Julia v1.12.6 source at tag `v1.12.6`.

## Overview

Julia produces two file types when precompiling a package with `use_pkgimages=1`
(the default):

| File | Extension | Contains | Portable? |
|------|-----------|----------|-----------|
| Cache header | `.ji` | Header metadata, dependency list, source text | Yes (flat binary) |
| Native image | `.so`/`.dylib`/`.dll` | Compiled machine code + embedded data blob | No (ELF/MachO/PE) |

With `use_pkgimages=0`, only a `.ji` file is produced containing both the header and
the data blob (no native code).

## .ji File Layout

### Non-Split Mode (`pkgimages=0`)

```
 Offset  Section                          Written by
 ------  -------                          ----------
 0       Base Header                      write_header (staticdata_utils.c:505)
         8B  magic "\373jli\r\n\032\n"
         2B  format_version (uint16, = 12)
         2B  BOM (uint16, = 0xFEFF)
         1B  pointer_size (uint8, = 8)
         var build_uname (null-terminated)
         var build_arch (null-terminated)
         var julia_version (null-terminated)
         var git_branch (null-terminated)
         var git_commit (null-terminated)
         1B  pkgimage_flag (uint8, = 0)
         8B  checksum slot (uint64, backfilled)
         8B  data_start (int64, backfilled)
         8B  data_end (int64, backfilled)

         Cache Flags                      staticdata.c:3468
         1B  cache_flags (uint8)

         Worklist                         write_worklist_for_header
         [per module]:                    (staticdata_utils.c:531)
           4B  name_len (int32)
           var name (char[])
           8B  uuid.hi (uint64)
           8B  uuid.lo (uint64)
           8B  build_id.lo (uint64)        <- PATCHABLE
         4B  terminator (int32 = 0)

         Dependency List                  write_dependency_list
         8B  totbytes (uint64)            (staticdata_utils.c:563)
         var source records, requires,
             preferences (opaque)

         Required Modules                 write_mod_list
         [per dependency]:                (staticdata_utils.c:409)
           4B  name_len (int32)
           var name (char[])
           8B  uuid.hi (uint64)
           8B  uuid.lo (uint64)
           8B  build_id.hi (uint64)        <- PATCHABLE
           8B  build_id.lo (uint64)        <- PATCHABLE
         4B  terminator (int32 = 0)

         Clone Targets                    staticdata.c:3554
         4B  int32(0) (no targets)
         var padding (to JL_CACHE_BYTE_ALIGNMENT)

         ============ DATA BLOB ============

         Serialized Object Graph          jl_save_system_image_to_stream
         var sysimg                       (staticdata.c:3045)
         var const_data
         var symbols
         var relocs
         var gvar_record
         var fptr_record

         Trailer
         var worklist, init_order,
             methods, edges, link_ids

         ============ END DATA BLOB ========

         Source Text                       write_srctext (precompile.c:24)
         [per source file]:
           4B  filename_len (int32)
           var filename (char[])
           8B  text_len (uint64)
           var text (char[])

         File CRC                         (appended by compilecache)
```

### Split Mode (`pkgimages=1`, Default)

The `.ji` file is a thin header — no data blob:

```
 Offset  Section
 ------  -------
 0       Base Header (pkgimage_flag = 0, data_start = 0, data_end = 0)
         Cache Flags
         Worklist
         Dependency List
         Required Modules
         Clone Targets (non-empty: CPU dispatch data)
         Source Text
         File CRC + .so CRC
         (NO data blob)
```

## .so File Layout

The `.so` is a platform-native shared library (ELF on Linux, Mach-O on macOS):

```
 ELF Header (64 bytes)
 Program Headers
 Section Headers

 .rodata section:
   JI Header (pkgimage_flag = 1)      write_header(ff, 1)
     (same base header format)        (staticdata.c:3530)
     data_start, data_end are NON-ZERO
     Followed by: cache_flags + mod_list ONLY
     (no worklist, no dependency list)

   jl_system_image_data               aotcompile.cpp:2073
     Full serialized data blob
     (same content as non-split .ji data blob)

   jl_image_pointers                  aotcompile.cpp:2286
     jl_image_header_t (nshards, nfvars, ngvars)
     jl_image_shard_t[] (per-thread tables)
     Target dispatch data

   jl_fvar_offsets / jl_gvar_offsets  aotcompile.cpp:244
     int32[] offset tables for PIC

 .text section:
   Compiled machine code
   Multi-versioned clones (SSE, AVX2, AVX-512)
   Dispatch thunks (j_*_gfthunk)

 .symtab section (removable with strip -s):
   ~1000+ symbol entries
   julia_* function names
   Compiler intrinsics

 .dynsym section (NOT removable):
   ~60 symbols (libjulia ABI)
   ijl_apply_generic, ijl_box_int64, etc.
```

## Build ID Structure

Every Julia module carries a 128-bit build ID stored as two 64-bit halves:

```c
typedef struct {           // julia.h:801
    uint64_t hi;
    uint64_t lo;
} jl_uuid_t;               // also used for build_id
```

| Half | Set When | Value | Deterministic? |
|------|----------|-------|----------------|
| `build_id.lo` | Module creation (`module.c:512`) | `bitmix(jl_hrtime() + count, jl_rand())` | No (time + random) |
| `build_id.hi` | Image deserialization (`staticdata.c:4243`) | CRC32C of data blob | Yes (for same blob) |

The combined 128-bit value is `(UInt128(hi) << 64) \| lo`, accessible via
`Base.module_build_id(m)` (`loading.jl:2532`).

## Checksum

The checksum field in the header is a 64-bit value:

```
Upper 32 bits: magic marker 0xfafbfcfd
Lower 32 bits: CRC32C of data blob
```

Written at `staticdata.c:3577`:
```c
write_uint64(ff, checksum | ((uint64_t)0xfafbfcfd << 32));
```

For split images, the `.ji` gets the checksum backfilled but `data_start` and
`data_end` remain 0 (the data blob is in the `.so`). The `.so` gets all three
fields backfilled.

## Validation Flow

On load, Julia validates the header at two levels:

**C-side** (`staticdata_utils.c:838`): `jl_read_verify_header` checks magic,
format version, BOM, pointer size, platform strings, and Julia version.

**C-side** (`staticdata_utils.c:797`): `read_verify_mod_list` checks each
dependency's `(name, uuid, build_id.hi, build_id.lo)` against the `depmods`
array with **exact equality** (line 821-822).

**Julia-side** (`loading.jl:3971`): `stale_cachefile` performs 10+ additional
checks including source file freshness, preferences hash, and concrete dependency
versions.

Build-ID remapping targets the C-side `write_mod_list`/`read_verify_mod_list`
boundary: by writing the target's build IDs into the header, the C-side validation
passes when the image is loaded against the target installation's modules.

## Format Versioning

The format version (`JI_FORMAT_VERSION`) is checked during header validation.
Package images built with a different version are rejected.

| Julia Version | JI_FORMAT_VERSION | Compatible? |
|---------------|-------------------|-------------|
| 1.12.x | 12 | Yes |
| 1.13.x (rc1) | 12 | Yes |
| master (future 1.14-dev) | 13-14 | No (header changes) |
