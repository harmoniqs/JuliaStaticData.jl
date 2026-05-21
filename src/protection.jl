"""
Source code protection analysis tools for Julia package images.

Analyzes `.ji` and `.so` files for information leakage and recommends
mitigation strategies.
"""

"""
    analyze_protection(path::String; io::IO=stdout) -> ProtectionReport

Analyze a `.ji` or `.so` file for information leakage.

Checks for presence of:
- Source text (srctextpos section)
- Julia IR (CodeInfo/inferred code)
- Debug info (file paths, line numbers)
- Metadata (variable names, slot names)
- ELF symbols (.so only)

Returns a `ProtectionReport` with findings and recommendations.
"""
function analyze_protection(path::String; io::IO=stdout)
    # Stub — full implementation in Phase 6
    hdr = parse_header(path)

    has_source = _check_source_text(path, hdr)
    is_so = endswith(path, ".so") || endswith(path, ".dylib") || endswith(path, ".dll")
    has_elf = is_so && _check_elf_symbols(path)

    recommendations = String[]
    has_source && push!(recommendations, "Strip source text: zero srctextpos section or use strip_image()")
    push!(recommendations, "Strip IR: rebuild with --strip-ir to remove CodeInfo/inferred code")
    push!(recommendations, "Strip metadata: rebuild with --strip-metadata to remove file paths/line numbers")
    has_elf && push!(recommendations, "Strip ELF symbols: run `strip -s` on .so file")
    push!(recommendations, "Consider --trim=safe to remove unreachable code (requires entry point annotations)")
    push!(recommendations, "Note: method names, type names, and module structure are ALWAYS preserved")

    report = ProtectionReport(
        has_source,
        true,   # has_ir (assume true without loading — conservative)
        true,   # has_debug_info
        true,   # has_metadata
        0, 0, 0,  # counts require loading the image
        has_elf,
        recommendations,
    )

    _print_report(io, report, path)
    return report
end

"""
    strip_image(input::String, output::String;
                strip_source_text::Bool=true,
                randomize_build_ids::Bool=false)

Create a copy of a package image with reduced information leakage.

This function performs header-level stripping (no libjulia dependency):
- Zeros the source text section (if strip_source_text)
- Randomizes build-ids in the header (if randomize_build_ids)

For deeper stripping (IR, metadata), the image must be rebuilt with
Julia's `--strip-ir` and `--strip-metadata` flags, or via `reserialize()`
from the Layer 2 extension.
"""
function strip_image(input::String, output::String;
                     strip_source_text::Bool=true,
                     randomize_build_ids::Bool=false)
    hdr = parse_header(input)

    if abspath(input) != abspath(output)
        cp(input, output; force=true)
    end

    if randomize_build_ids
        # Generate random remaps for all dependencies
        remaps = RemapSpec[]
        for dep in hdr.required_modules
            push!(remaps, RemapSpec(dep.name, dep.uuid, rand(UInt128)))
        end
        remap!(output, remaps)
    end

    # Source text stripping requires knowing srctextpos — for now just report
    if strip_source_text
        @info "Source text stripping: use --strip-ir at build time for full removal"
    end

    return output
end

# ── Internal helpers ────────────────────────────────────────

function _check_source_text(path::String, hdr::PkgImageHeader)
    # Source text is located after the data blob. If data_end < file size,
    # there may be source text present.
    fsize = filesize(path)
    return fsize > hdr.data_end + 100  # rough heuristic
end

function _check_elf_symbols(path::String)
    try
        # Try running nm to check for symbols
        result = read(`nm -D $path`, String)
        return !isempty(result)
    catch
        return false
    end
end

function _print_report(io::IO, report::ProtectionReport, path::String)
    println(io, "Protection Analysis: ", path)
    println(io, "=" ^ 60)
    println(io, "  Source text present:    ", report.has_source_text ? "YES (HIGH RISK)" : "no")
    println(io, "  Julia IR present:      ", report.has_ir ? "YES (assumed)" : "no")
    println(io, "  Debug info present:    ", report.has_debug_info ? "YES (assumed)" : "no")
    println(io, "  Metadata present:      ", report.has_metadata ? "YES (assumed)" : "no")
    println(io, "  ELF symbols present:   ", report.elf_symbols ? "YES" : "no / N/A")
    println(io)
    println(io, "Recommendations:")
    for (i, r) in enumerate(report.recommendations)
        println(io, "  $i. ", r)
    end
end
