/*
 * jlstaticdata_remap.c — Build-ID remapping for .ji files (Layer 1).
 *
 * Patches build-id fields in-place using file offsets recorded during parsing.
 * The CRC32C checksum is NOT recomputed because only header fields are changed
 * (the data blob is untouched).
 */

#include "libjlstaticdata.h"
#include <stdlib.h>
#include <string.h>
#include <errno.h>

/**
 * Copy a file. Returns 0 on success.
 */
static int copy_file(const char *src, const char *dst) {
    FILE *in = fopen(src, "rb");
    if (!in) return -1;
    FILE *out = fopen(dst, "wb");
    if (!out) { fclose(in); return -1; }

    char buf[8192];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), in)) > 0) {
        if (fwrite(buf, 1, n, out) != n) {
            fclose(in); fclose(out); return -1;
        }
    }
    fclose(in);
    fclose(out);
    return 0;
}

/**
 * Find a matching remap entry for a module entry.
 * Matches by name (if remap->module_name != NULL) or by uuid.
 * Returns NULL if no match.
 */
static const jlsd_remap_entry_t *find_remap(
    const jlsd_module_entry_t *entry,
    const jlsd_remap_entry_t *remaps, size_t n_remaps)
{
    for (size_t i = 0; i < n_remaps; i++) {
        const jlsd_remap_entry_t *r = &remaps[i];
        if (r->module_name != NULL) {
            if (strcmp(entry->name, r->module_name) == 0)
                return r;
        } else {
            if (entry->uuid.hi == r->module_uuid.hi &&
                entry->uuid.lo == r->module_uuid.lo)
                return r;
        }
    }
    return NULL;
}

/**
 * Write a uint64 at a specific file offset.
 */
static int write_uint64_at(FILE *f, int64_t offset, uint64_t value) {
    if (fseek(f, (long)offset, SEEK_SET) != 0) return -1;
    if (fwrite(&value, 8, 1, f) != 1) return -1;
    return 0;
}

int jlsd_remap(const char *input_path, const char *output_path,
               const jlsd_remap_entry_t *remaps, size_t n_remaps,
               uint32_t flags) {
    if (n_remaps == 0) return JLSD_OK;

    /* Parse header to get file offsets */
    jlsd_header_t hdr;
    int rc = jlsd_header_parse(input_path, &hdr);
    if (rc != JLSD_OK) return rc;

    /* Copy input to output if different paths */
    if (strcmp(input_path, output_path) != 0) {
        if (copy_file(input_path, output_path) != 0) {
            jlsd_header_free(&hdr);
            return JLSD_ERR_IO;
        }
    }

    /* Open output for read/write patching */
    FILE *f = fopen(output_path, "r+b");
    if (!f) {
        jlsd_header_free(&hdr);
        return JLSD_ERR_IO;
    }

    /* Patch required modules (Section 4) */
    if (flags & JLSD_REMAP_MODLIST) {
        for (size_t i = 0; i < hdr.modlist_count; i++) {
            const jlsd_remap_entry_t *r = find_remap(&hdr.modlist[i], remaps, n_remaps);
            if (!r) continue;

            if (hdr.modlist[i].file_offset_hi >= 0) {
                if (write_uint64_at(f, hdr.modlist[i].file_offset_hi, r->target_build_id.hi) != 0)
                    goto err_io;
            }
            if (write_uint64_at(f, hdr.modlist[i].file_offset_lo, r->target_build_id.lo) != 0)
                goto err_io;
        }
    }

    /* Patch worklist (Section 2) */
    if (flags & JLSD_REMAP_WORKLIST) {
        for (size_t i = 0; i < hdr.worklist_count; i++) {
            const jlsd_remap_entry_t *r = find_remap(&hdr.worklist[i], remaps, n_remaps);
            if (!r) continue;

            /* Worklist only stores build_id.lo */
            if (write_uint64_at(f, hdr.worklist[i].file_offset_lo, r->target_build_id.lo) != 0)
                goto err_io;
        }
    }

    fclose(f);
    jlsd_header_free(&hdr);
    return JLSD_OK;

err_io:
    fclose(f);
    jlsd_header_free(&hdr);
    return JLSD_ERR_IO;
}
