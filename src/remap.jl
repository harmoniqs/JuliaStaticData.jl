"""
Build-ID remapping for `.ji` package image files.

Patches build-id fields in the header without modifying the data blob.
The CRC32C checksum is unaffected because it covers only the data portion.
"""

"""
    remap(input::String, output::String, remaps::Vector{RemapSpec};
          remap_worklist::Bool=false)

Remap dependency build-IDs in a `.ji` file header.

Patches build-id fields in the `write_mod_list` section (Section 4 of the
header). If `remap_worklist=true`, also patches the worklist section's
`build_id.lo` entries.

The data blob is NOT modified. The CRC32C checksum is unaffected.

For full consistency (including `build_id.lo` inside the data blob and
method root block keys), use `reserialize()` from the Layer 2 extension.
"""
function remap(input::String, output::String, remaps::Vector{RemapSpec};
               remap_worklist::Bool=false)
    isempty(remaps) && return nothing

    hdr = parse_header(input)

    # Copy input to output if different files
    if abspath(input) != abspath(output)
        cp(input, output; force=true)
    end

    open(output, "r+") do io
        # Patch required modules (Section 4: write_mod_list)
        for dep in hdr.required_modules
            spec = _find_matching_remap(dep, remaps)
            spec === nothing && continue

            target_hi = UInt64((spec.target_build_id >> 64) & typemax(UInt64))
            target_lo = UInt64(spec.target_build_id & typemax(UInt64))

            seek(io, dep._file_offset_hi)
            write(io, target_hi)
            seek(io, dep._file_offset_lo)
            write(io, target_lo)
        end

        # Optionally patch worklist (Section 2: write_worklist_for_header)
        if remap_worklist
            for w in hdr.worklist
                spec = _find_matching_remap_worklist(w, remaps)
                spec === nothing && continue

                target_lo = UInt64(spec.target_build_id & typemax(UInt64))

                seek(io, w._file_offset)
                write(io, target_lo)
            end
        end
    end

    return output
end

"""
    remap!(path::String, remaps::Vector{RemapSpec}; remap_worklist::Bool=false)

In-place remap of build-IDs in a `.ji` file header. Equivalent to
`remap(path, path, remaps; remap_worklist)`.
"""
function remap!(path::String, remaps::Vector{RemapSpec}; remap_worklist::Bool=false)
    return remap(path, path, remaps; remap_worklist)
end

# ── Internal matching ───────────────────────────────────────

function _find_matching_remap(dep::DepModEntry, remaps::Vector{RemapSpec})
    for spec in remaps
        if spec.name == dep.name
            if spec.uuid === nothing || spec.uuid == dep.uuid
                return spec
            end
        end
    end
    return nothing
end

function _find_matching_remap_worklist(w::WorklistEntry, remaps::Vector{RemapSpec})
    for spec in remaps
        if spec.name == w.name
            if spec.uuid === nothing || spec.uuid == w.uuid
                return spec
            end
        end
    end
    return nothing
end
