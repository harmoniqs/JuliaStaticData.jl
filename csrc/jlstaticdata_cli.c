/*
 * jlstaticdata_cli.c — CLI for .ji header inspection and build-id remapping.
 *
 * Usage:
 *   jlsd-remap --inspect --input <file>
 *   jlsd-remap --input <file> --output <file> --remap "ModuleName=hi:lo"
 */

#include "libjlstaticdata.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_REMAPS 64

static void usage(const char *prog) {
    fprintf(stderr,
        "Usage: %s [OPTIONS]\n"
        "\n"
        "OPTIONS:\n"
        "  --input <FILE>         Input .ji file\n"
        "  --output <FILE>        Output file (may equal input for in-place)\n"
        "  --remap <SPEC>         Remap spec: \"ModuleName=hi:lo\" (hex uint64)\n"
        "                         May be repeated (max %d)\n"
        "  --remap-worklist       Also remap worklist build_id.lo\n"
        "  --inspect              Print parsed header and exit\n"
        "  --validate             Validate header integrity and exit\n"
        "  --quiet                Suppress informational output\n"
        "  --version              Print version and exit\n"
        "  --help                 Show this help\n"
        "\n"
        "EXAMPLES:\n"
        "  %s --inspect --input Foo.ji\n"
        "  %s --input Foo.ji --output Foo_remapped.ji --remap \"Base=deadbeef:01234567\"\n",
        prog, MAX_REMAPS, prog, prog);
}

/**
 * Parse a remap spec string: "ModuleName=hi:lo"
 * Returns 0 on success.
 */
static int parse_remap_spec(const char *spec, jlsd_remap_entry_t *out) {
    /* Find '=' separator */
    const char *eq = strchr(spec, '=');
    if (!eq || eq == spec) {
        fprintf(stderr, "Error: invalid remap spec (expected ModuleName=hi:lo): %s\n", spec);
        return -1;
    }

    /* Extract module name */
    size_t name_len = eq - spec;
    char *name = (char *)malloc(name_len + 1);
    if (!name) return -1;
    memcpy(name, spec, name_len);
    name[name_len] = '\0';
    out->module_name = name;

    /* Parse "hi:lo" */
    const char *rest = eq + 1;
    const char *colon = strchr(rest, ':');
    if (!colon) {
        fprintf(stderr, "Error: invalid remap spec (expected hi:lo after =): %s\n", spec);
        free(name);
        return -1;
    }

    char hi_str[32], lo_str[32];
    size_t hi_len = colon - rest;
    size_t lo_len = strlen(colon + 1);
    if (hi_len >= sizeof(hi_str) || lo_len >= sizeof(lo_str)) {
        fprintf(stderr, "Error: hex value too long in remap spec: %s\n", spec);
        free(name);
        return -1;
    }
    memcpy(hi_str, rest, hi_len); hi_str[hi_len] = '\0';
    memcpy(lo_str, colon + 1, lo_len); lo_str[lo_len] = '\0';

    out->target_build_id.hi = strtoull(hi_str, NULL, 16);
    out->target_build_id.lo = strtoull(lo_str, NULL, 16);
    out->module_uuid.hi = 0;
    out->module_uuid.lo = 0;

    return 0;
}

int main(int argc, char **argv) {
    const char *input = NULL;
    const char *output = NULL;
    int do_inspect = 0;
    int do_validate = 0;
    int quiet = 0;
    int remap_worklist = 0;
    jlsd_remap_entry_t remaps[MAX_REMAPS];
    size_t n_remaps = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            usage(argv[0]);
            return 0;
        } else if (strcmp(argv[i], "--version") == 0) {
            printf("jlsd-remap 0.1.0 (JI format version %d)\n", JLSD_FORMAT_VERSION);
            return 0;
        } else if (strcmp(argv[i], "--input") == 0 && i + 1 < argc) {
            input = argv[++i];
        } else if (strcmp(argv[i], "--output") == 0 && i + 1 < argc) {
            output = argv[++i];
        } else if (strcmp(argv[i], "--inspect") == 0) {
            do_inspect = 1;
        } else if (strcmp(argv[i], "--validate") == 0) {
            do_validate = 1;
        } else if (strcmp(argv[i], "--quiet") == 0) {
            quiet = 1;
        } else if (strcmp(argv[i], "--remap-worklist") == 0) {
            remap_worklist = 1;
        } else if (strcmp(argv[i], "--remap") == 0 && i + 1 < argc) {
            if (n_remaps >= MAX_REMAPS) {
                fprintf(stderr, "Error: too many --remap entries (max %d)\n", MAX_REMAPS);
                return 1;
            }
            if (parse_remap_spec(argv[++i], &remaps[n_remaps]) != 0)
                return 1;
            n_remaps++;
        } else {
            fprintf(stderr, "Error: unknown option: %s\n", argv[i]);
            usage(argv[0]);
            return 1;
        }
    }

    if (!input) {
        fprintf(stderr, "Error: --input is required\n");
        usage(argv[0]);
        return 1;
    }

    /* Inspect mode */
    if (do_inspect) {
        jlsd_header_t hdr;
        int rc = jlsd_header_parse(input, &hdr);
        if (rc != JLSD_OK) {
            fprintf(stderr, "Error: failed to parse header (code %d)\n", rc);
            return 1;
        }
        jlsd_header_dump(&hdr, stdout);
        jlsd_header_free(&hdr);
        return 0;
    }

    /* Validate mode */
    if (do_validate) {
        jlsd_header_t hdr;
        int rc = jlsd_header_parse(input, &hdr);
        if (rc != JLSD_OK) {
            fprintf(stderr, "INVALID: parse error (code %d)\n", rc);
            return 1;
        }
        rc = jlsd_header_validate(&hdr);
        if (rc != JLSD_OK) {
            fprintf(stderr, "INVALID: validation error (code %d)\n", rc);
            jlsd_header_free(&hdr);
            return 1;
        }
        if (!quiet)
            fprintf(stdout, "VALID: %s (format v%u, %zu deps)\n",
                    input, hdr.format_version, hdr.modlist_count);
        jlsd_header_free(&hdr);
        return 0;
    }

    /* Remap mode */
    if (n_remaps > 0) {
        if (!output) output = input;  /* in-place by default */

        uint32_t flags = JLSD_REMAP_MODLIST;
        if (remap_worklist) flags |= JLSD_REMAP_WORKLIST;

        int rc = jlsd_remap(input, output, remaps, n_remaps, flags);

        /* Free remap names */
        for (size_t i = 0; i < n_remaps; i++)
            free((void *)remaps[i].module_name);

        if (rc != JLSD_OK) {
            fprintf(stderr, "Error: remap failed (code %d)\n", rc);
            return 1;
        }
        if (!quiet)
            fprintf(stdout, "Remapped %zu entries in %s -> %s\n", n_remaps, input, output);
        return 0;
    }

    fprintf(stderr, "Error: no action specified. Use --inspect, --validate, or --remap.\n");
    usage(argv[0]);
    return 1;
}
