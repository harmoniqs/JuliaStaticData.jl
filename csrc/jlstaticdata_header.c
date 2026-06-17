/*
 * jlstaticdata_header.c — .ji header parser for Layer 1.
 *
 * Parses the binary format produced by:
 *   write_header()                  (staticdata_utils.c:505)
 *   jl_write_header_for_incremental() (staticdata.c:3465)
 *   write_worklist_for_header()     (staticdata_utils.c:531)
 *   write_dependency_list()         (staticdata_utils.c:563)
 *   write_mod_list()                (staticdata_utils.c:409)
 */

#include "libjlstaticdata.h"
#include <stdlib.h>
#include <string.h>
#include <errno.h>

/* ── Internal I/O helpers ────────────────────────────────── */

static int read_uint8(FILE *f, uint8_t *out) {
    return fread(out, 1, 1, f) == 1 ? 0 : -1;
}

static int read_uint16(FILE *f, uint16_t *out) {
    return fread(out, 2, 1, f) == 1 ? 0 : -1;
}

static int read_int32(FILE *f, int32_t *out) {
    return fread(out, 4, 1, f) == 1 ? 0 : -1;
}

static int read_uint64(FILE *f, uint64_t *out) {
    return fread(out, 8, 1, f) == 1 ? 0 : -1;
}

static int read_int64(FILE *f, int64_t *out) {
    return fread(out, 8, 1, f) == 1 ? 0 : -1;
}

/**
 * Read a null-terminated C string from a FILE*.
 * Returns a heap-allocated copy. Caller must free().
 */
static char *read_cstring(FILE *f) {
    size_t cap = 64, len = 0;
    char *buf = (char *)malloc(cap);
    if (!buf) return NULL;

    int ch;
    while ((ch = fgetc(f)) != EOF && ch != '\0') {
        if (len + 1 >= cap) {
            cap *= 2;
            char *tmp = (char *)realloc(buf, cap);
            if (!tmp) { free(buf); return NULL; }
            buf = tmp;
        }
        buf[len++] = (char)ch;
    }
    buf[len] = '\0';
    return buf;
}

/**
 * Read a module list in write_worklist_for_header or write_mod_list format.
 *
 * Format per entry:
 *   int32  name_len
 *   char[] name (name_len bytes, NOT null-terminated)
 *   uint64 uuid_hi
 *   uint64 uuid_lo
 *   [uint64 build_id_hi]  (only if has_buildid_hi)
 *   uint64 build_id_lo
 * Terminated by int32(0).
 *
 * @param f              Open file at the start of the list.
 * @param has_buildid_hi Whether each entry includes build_id.hi.
 * @param out_entries    Output array (heap-allocated). Caller must free.
 * @param out_count      Number of entries read.
 * @return               JLSD_OK or error.
 */
static int read_module_list(FILE *f, int has_buildid_hi,
                            jlsd_module_entry_t **out_entries, size_t *out_count) {
    size_t cap = 8, count = 0;
    jlsd_module_entry_t *entries = (jlsd_module_entry_t *)calloc(cap, sizeof(jlsd_module_entry_t));
    if (!entries) return JLSD_ERR_ALLOC;

    while (1) {
        int32_t name_len;
        if (read_int32(f, &name_len) != 0) goto err_io;
        if (name_len == 0) break;  /* terminator */

        if (count >= cap) {
            cap *= 2;
            jlsd_module_entry_t *tmp = (jlsd_module_entry_t *)realloc(entries, cap * sizeof(jlsd_module_entry_t));
            if (!tmp) goto err_alloc;
            entries = tmp;
        }

        jlsd_module_entry_t *e = &entries[count];
        memset(e, 0, sizeof(*e));

        /* Name */
        e->name = (char *)malloc(name_len + 1);
        if (!e->name) goto err_alloc;
        if (fread(e->name, 1, name_len, f) != (size_t)name_len) goto err_io;
        e->name[name_len] = '\0';

        /* UUID */
        if (read_uint64(f, &e->uuid.hi) != 0) goto err_io;
        if (read_uint64(f, &e->uuid.lo) != 0) goto err_io;

        /* Build ID */
        if (has_buildid_hi) {
            e->file_offset_hi = (int64_t)ftell(f);
            if (read_uint64(f, &e->build_id.hi) != 0) goto err_io;
        } else {
            e->file_offset_hi = -1;
            e->build_id.hi = 0;
        }
        e->file_offset_lo = (int64_t)ftell(f);
        if (read_uint64(f, &e->build_id.lo) != 0) goto err_io;

        count++;
    }

    *out_entries = entries;
    *out_count = count;
    return JLSD_OK;

err_alloc:
    for (size_t i = 0; i < count; i++) free(entries[i].name);
    free(entries);
    return JLSD_ERR_ALLOC;

err_io:
    for (size_t i = 0; i < count; i++) free(entries[i].name);
    free(entries);
    return JLSD_ERR_IO;
}

/* ── Public API ──────────────────────────────────────────── */

int jlsd_header_parse_file(FILE *f, jlsd_header_t *out) {
    memset(out, 0, sizeof(*out));

    /* Section 0: Base header (write_header, staticdata_utils.c:505) */
    char magic[JLSD_MAGIC_LEN];
    if (fread(magic, 1, JLSD_MAGIC_LEN, f) != JLSD_MAGIC_LEN)
        return JLSD_ERR_IO;
    if (memcmp(magic, JLSD_MAGIC, JLSD_MAGIC_LEN) != 0)
        return JLSD_ERR_BAD_MAGIC;

    if (read_uint16(f, &out->format_version) != 0) return JLSD_ERR_IO;

    uint16_t bom;
    if (read_uint16(f, &bom) != 0) return JLSD_ERR_IO;
    if (bom != JLSD_BOM) return JLSD_ERR_BAD_BOM;

    if (read_uint8(f, &out->pointer_size) != 0) return JLSD_ERR_IO;

    out->build_uname   = read_cstring(f); if (!out->build_uname)   return JLSD_ERR_IO;
    out->build_arch    = read_cstring(f); if (!out->build_arch)    return JLSD_ERR_IO;
    out->julia_version = read_cstring(f); if (!out->julia_version) return JLSD_ERR_IO;
    out->git_branch    = read_cstring(f); if (!out->git_branch)    return JLSD_ERR_IO;
    out->git_commit    = read_cstring(f); if (!out->git_commit)    return JLSD_ERR_IO;

    if (read_uint8(f, &out->pkgimage) != 0) return JLSD_ERR_IO;
    if (read_uint64(f, &out->checksum) != 0) return JLSD_ERR_IO;
    if (read_int64(f, &out->data_start) != 0) return JLSD_ERR_IO;
    if (read_int64(f, &out->data_end) != 0) return JLSD_ERR_IO;

    /* Section 1: Cache flags */
    if (read_uint8(f, &out->cache_flags) != 0) return JLSD_ERR_IO;

    if (out->pkgimage == 0) {
        /* .ji format: worklist + deplist + modlist */

        /* Section 2: Worklist */
        int rc = read_module_list(f, 0, &out->worklist, &out->worklist_count);
        if (rc != JLSD_OK) return rc;

        /* Section 3: Dependency list (skip over) */
        out->deplist_offset = (int64_t)ftell(f);
        uint64_t totbytes;
        if (read_uint64(f, &totbytes) != 0) return JLSD_ERR_IO;
        if (totbytes > 0) {
            if (fseek(f, (long)totbytes, SEEK_CUR) != 0) return JLSD_ERR_IO;
        }
        out->deplist_length = (int64_t)ftell(f) - out->deplist_offset;
    } else {
        /* .so format: just cache_flags + modlist (no worklist/deplist) */
        out->worklist = NULL;
        out->worklist_count = 0;
        out->deplist_offset = 0;
        out->deplist_length = 0;
    }

    /* Section 4 (.ji) or Section 2 (.so): Required modules */
    int rc = read_module_list(f, 1, &out->modlist, &out->modlist_count);
    if (rc != JLSD_OK) return rc;

    return JLSD_OK;
}

int jlsd_header_parse(const char *filepath, jlsd_header_t *out) {
    FILE *f = fopen(filepath, "rb");
    if (!f) return JLSD_ERR_IO;
    int rc = jlsd_header_parse_file(f, out);
    fclose(f);
    return rc;
}

void jlsd_header_free(jlsd_header_t *header) {
    free(header->build_uname);
    free(header->build_arch);
    free(header->julia_version);
    free(header->git_branch);
    free(header->git_commit);

    if (header->worklist) {
        for (size_t i = 0; i < header->worklist_count; i++)
            free(header->worklist[i].name);
        free(header->worklist);
    }
    if (header->modlist) {
        for (size_t i = 0; i < header->modlist_count; i++)
            free(header->modlist[i].name);
        free(header->modlist);
    }

    memset(header, 0, sizeof(*header));
}

int jlsd_header_validate(const jlsd_header_t *header) {
    if (header->format_version < JLSD_FORMAT_VERSION)
        return JLSD_ERR_BAD_FORMAT;
    uint32_t magic_hi = (uint32_t)(header->checksum >> 32);
    if (magic_hi != 0 && magic_hi != (uint32_t)JLSD_CHECKSUM_MAGIC)
        return JLSD_ERR_BAD_FORMAT;
    return JLSD_OK;
}

void jlsd_header_dump(const jlsd_header_t *header, FILE *out) {
    fprintf(out, "Julia Package Image Header\n");
    fprintf(out, "==========================\n");
    fprintf(out, "  Format version:  %u\n", header->format_version);
    fprintf(out, "  Pointer size:    %u\n", header->pointer_size);
    fprintf(out, "  Julia version:   %s\n", header->julia_version);
    fprintf(out, "  Git:             %s @ %s\n", header->git_branch, header->git_commit);
    fprintf(out, "  Platform:        %s / %s\n", header->build_uname, header->build_arch);
    fprintf(out, "  Pkgimage:        %s\n", header->pkgimage ? "true" : "false");
    fprintf(out, "  Cache flags:     0x%02x\n", header->cache_flags);

    uint32_t crc = (uint32_t)(header->checksum & 0xFFFFFFFF);
    uint32_t magic_hi = (uint32_t)(header->checksum >> 32);
    fprintf(out, "  Checksum:        0x%08x (magic: 0x%08x)\n", crc, magic_hi);
    fprintf(out, "  Data range:      %ld .. %ld (%ld bytes)\n",
            (long)header->data_start, (long)header->data_end,
            (long)(header->data_end - header->data_start));

    fprintf(out, "\nWorklist (%zu modules):\n", header->worklist_count);
    for (size_t i = 0; i < header->worklist_count; i++) {
        const jlsd_module_entry_t *e = &header->worklist[i];
        fprintf(out, "  %s  build_id.lo=0x%016llx\n",
                e->name, (unsigned long long)e->build_id.lo);
    }

    fprintf(out, "\nRequired modules (%zu dependencies):\n", header->modlist_count);
    for (size_t i = 0; i < header->modlist_count; i++) {
        const jlsd_module_entry_t *e = &header->modlist[i];
        fprintf(out, "  %s  build_id=0x%016llx%016llx\n",
                e->name,
                (unsigned long long)e->build_id.hi,
                (unsigned long long)e->build_id.lo);
    }
}
