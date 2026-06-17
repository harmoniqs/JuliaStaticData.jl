/*
 * libjlstaticdata — Standalone C library for Julia package image manipulation.
 *
 * Layer 1: No libjulia dependency. Parses and patches .ji file headers.
 *
 * The .ji header format is defined by:
 *   write_header()                  staticdata_utils.c:505
 *   jl_write_header_for_incremental() staticdata.c:3465
 *   write_worklist_for_header()     staticdata_utils.c:531
 *   write_mod_list()                staticdata_utils.c:409
 */

#ifndef LIBJLSTATICDATA_H
#define LIBJLSTATICDATA_H

#include <stdint.h>
#include <stddef.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── Constants ───────────────────────────────────────────── */

#define JLSD_MAGIC "\373jli\r\n\032\n"
#define JLSD_MAGIC_LEN 8
#define JLSD_FORMAT_VERSION 12
#define JLSD_BOM 0xFEFF
#define JLSD_CHECKSUM_MAGIC 0xfafbfcfdULL

/* Remap flags */
#define JLSD_REMAP_MODLIST   0x01  /* Remap dependency build-ids (Section 4) */
#define JLSD_REMAP_WORKLIST  0x02  /* Remap worklist build-ids (Section 2) */

/* Error codes */
#define JLSD_OK              0
#define JLSD_ERR_IO         -1
#define JLSD_ERR_BAD_MAGIC  -2
#define JLSD_ERR_BAD_FORMAT -3
#define JLSD_ERR_BAD_BOM    -4
#define JLSD_ERR_ALLOC      -5
#define JLSD_ERR_NOT_FOUND  -6

/* ── Types ───────────────────────────────────────────────── */

typedef struct {
    uint64_t hi;
    uint64_t lo;
} jlsd_uuid_t;

typedef struct {
    uint64_t hi;
    uint64_t lo;
} jlsd_build_id_t;

/**
 * A module entry from the worklist or required-modules section.
 *
 * For worklist entries (Section 2), build_id.hi is 0 (not stored in header).
 * For required-module entries (Section 4), both halves are present.
 */
typedef struct {
    char            *name;         /* Module name (heap-allocated, null-terminated) */
    jlsd_uuid_t      uuid;
    jlsd_build_id_t  build_id;
    int64_t           file_offset_hi;  /* Byte offset of build_id.hi in file (-1 if N/A) */
    int64_t           file_offset_lo;  /* Byte offset of build_id.lo in file */
} jlsd_module_entry_t;

/**
 * Parsed .ji file header.
 */
typedef struct {
    /* Base header (write_header, staticdata_utils.c:505) */
    uint16_t  format_version;
    uint8_t   pointer_size;
    char     *build_uname;     /* Heap-allocated */
    char     *build_arch;      /* Heap-allocated */
    char     *julia_version;   /* Heap-allocated */
    char     *git_branch;      /* Heap-allocated */
    char     *git_commit;      /* Heap-allocated */
    uint8_t   pkgimage;
    uint64_t  checksum;        /* Raw value: crc32c | (JLSD_CHECKSUM_MAGIC << 32) */
    int64_t   data_start;
    int64_t   data_end;

    /* Incremental header */
    uint8_t   cache_flags;

    /* Worklist (Section 2) — only for .ji (pkgimage=0) */
    size_t                  worklist_count;
    jlsd_module_entry_t    *worklist;

    /* Dependency list byte range (Section 3, opaque) */
    int64_t   deplist_offset;
    int64_t   deplist_length;

    /* Required modules (Section 4 for .ji, Section 2 for .so) */
    size_t                  modlist_count;
    jlsd_module_entry_t    *modlist;
} jlsd_header_t;

/**
 * A single build-id remap entry.
 */
typedef struct {
    const char       *module_name;    /* Match by name (NULL = match by uuid only) */
    jlsd_uuid_t       module_uuid;   /* Ignored if module_name != NULL */
    jlsd_build_id_t   target_build_id;
} jlsd_remap_entry_t;

/* ── Parsing ─────────────────────────────────────────────── */

/**
 * Parse a .ji file header.
 *
 * @param filepath  Path to the .ji file.
 * @param out       Output header struct. Caller must call jlsd_header_free().
 * @return          JLSD_OK on success, negative error code on failure.
 */
int jlsd_header_parse(const char *filepath, jlsd_header_t *out);

/**
 * Parse a .ji header from an already-opened FILE*.
 *
 * @param f    Open file positioned at the start of the JI header.
 * @param out  Output header struct.
 * @return     JLSD_OK on success.
 */
int jlsd_header_parse_file(FILE *f, jlsd_header_t *out);

/**
 * Free all heap memory owned by a parsed header.
 */
void jlsd_header_free(jlsd_header_t *header);

/* ── Inspection ──────────────────────────────────────────── */

/**
 * Print header contents to a FILE* (human-readable).
 */
void jlsd_header_dump(const jlsd_header_t *header, FILE *out);

/**
 * Validate header integrity (magic, version, checksum magic marker).
 *
 * @return JLSD_OK if valid.
 */
int jlsd_header_validate(const jlsd_header_t *header);

/* ── Remapping ───────────────────────────────────────────── */

/**
 * Remap build-IDs in a .ji file.
 *
 * Patches build-id fields in the header in-place. Does not modify the data
 * blob, so the CRC32C checksum is unaffected (for JLSD_REMAP_MODLIST only).
 *
 * @param input_path   Source .ji file.
 * @param output_path  Destination file (may equal input_path for in-place).
 * @param remaps       Array of remap entries.
 * @param n_remaps     Number of entries.
 * @param flags        JLSD_REMAP_MODLIST | JLSD_REMAP_WORKLIST.
 * @return             JLSD_OK on success.
 */
int jlsd_remap(const char *input_path, const char *output_path,
               const jlsd_remap_entry_t *remaps, size_t n_remaps,
               uint32_t flags);

#ifdef __cplusplus
}
#endif

#endif /* LIBJLSTATICDATA_H */
