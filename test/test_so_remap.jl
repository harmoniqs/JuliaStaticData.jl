using TestItemRunner
using TestItems

# Regression tests for parsing + remapping build-ids in split-image .so files.
# The .so embeds its own JI header (pkgimage=1) inside an ELF/MachO data section.
# parse_header() scans for it and records byte offsets; those offsets MUST be
# absolute file offsets (not relative to the embedded-header location), or remap()
# will patch the wrong bytes — historically clobbering the ELF program headers.

@testitem "parse_header(.so): recorded offsets are ABSOLUTE and point at the build-id bytes" begin
    using JuliaStaticData
    include(joinpath(@__DIR__, "fixtures.jl"))

    # Resolve a pkgimage .so with required_modules from the fixture depot
    # (JSD_FIXTURE_DEPOT) or, failing that, by scanning Base.DEPOT_PATH.
    so = jsd_find_so(parse_header)
    if so === nothing
        @info "SKIP parse_header(.so) offsets: $JSD_FIXTURE_SKIP_MSG"
        @test_skip JSD_FIXTURE_SKIP_MSG
    else
        hdr = parse_header(so)

        # The decisive invariant: seeking to a recorded offset and reading must
        # yield exactly the build-id parse_header reported. (The old idx-relative
        # bug made these offsets too small → they pointed into the ELF headers.)
        open(so, "r") do io
            for d in hdr.required_modules
                seek(io, d._file_offset_lo); @test read(io, UInt64) == d.build_id_lo
                seek(io, d._file_offset_hi); @test read(io, UInt64) == d.build_id_hi
            end
        end
        # Offsets must lie past the ELF program-header region (sanity vs the bug).
        @test minimum(d._file_offset_lo for d in hdr.required_modules) > 64
    end
end

@testitem "remap(.so): patches build-ids in place, keeps the file structurally intact" begin
    using JuliaStaticData
    include(joinpath(@__DIR__, "fixtures.jl"))

    so = jsd_find_so(parse_header)
    if so === nothing
        @info "SKIP remap(.so): $JSD_FIXTURE_SKIP_MSG"
        @test_skip JSD_FIXTURE_SKIP_MSG
    else
        tmp = tempname() * ".so"
        cp(so, tmp; force=true)
        try
            hdr = parse_header(tmp)
            dep = hdr.required_modules[1]
            target = UInt128(0xABCDEF0123456789) << 64 | UInt128(0x0011223344556677)
            remap(tmp, tmp, [RemapSpec(dep.name, dep.uuid, target)])

            hdr2 = parse_header(tmp)             # must still parse (ELF intact)
            d2 = hdr2.required_modules[1]
            @test d2.name == dep.name
            @test d2.build_id_hi == UInt64(0xABCDEF0123456789)
            @test d2.build_id_lo == UInt64(0x0011223344556677)
            open(tmp, "r") do io
                seek(io, d2._file_offset_lo); @test read(io, UInt64) == UInt64(0x0011223344556677)
            end
            for i in 2:length(hdr.required_modules)
                @test hdr2.required_modules[i].build_id_lo == hdr.required_modules[i].build_id_lo
            end
        finally
            isfile(tmp) && rm(tmp)
        end
    end
end
