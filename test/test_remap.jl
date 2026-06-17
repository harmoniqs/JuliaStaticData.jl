using TestItemRunner
using TestItems

@testitem "remap dependency build-id roundtrip" begin
    using JuliaStaticData
    include(joinpath(@__DIR__, "fixtures.jl"))

    # Find a .ji file with at least one required module (JSD_FIXTURE_DEPOT or DEPOT_PATH).
    ji_files = jsd_find_ji(; limit = 1, parse_header = parse_header,
                           predicate = hdr -> !isempty(hdr.required_modules))

    if isempty(ji_files)
        @info "SKIP remap dependency build-id roundtrip: $JSD_FIXTURE_SKIP_MSG"
        @test_skip JSD_FIXTURE_SKIP_MSG
    else
        src = ji_files[1]
        hdr_before = parse_header(src)

        @test !isempty(hdr_before.required_modules)
        dep = hdr_before.required_modules[1]

        # Remap with a known target value
        target_id = UInt128(0xDEADBEEFCAFE1234) << 64 | UInt128(0x0123456789ABCDEF)
        spec = RemapSpec(dep.name, dep.uuid, target_id)

        tmp = tempname() * ".ji"
        try
            remap(src, tmp, [spec])

            hdr_after = parse_header(tmp)
            dep_after = hdr_after.required_modules[1]

            @test dep_after.name == dep.name
            @test dep_after.uuid == dep.uuid
            @test dep_after.build_id_hi == UInt64(0xDEADBEEFCAFE1234)
            @test dep_after.build_id_lo == UInt64(0x0123456789ABCDEF)

            # Header metadata unchanged
            @test hdr_after.format_version == hdr_before.format_version
            @test hdr_after.julia_version == hdr_before.julia_version
            @test hdr_after.checksum == hdr_before.checksum  # data blob untouched
            @test length(hdr_after.worklist) == length(hdr_before.worklist)
            @test length(hdr_after.required_modules) == length(hdr_before.required_modules)

            # Non-remapped dependencies unchanged
            for i in 2:length(hdr_before.required_modules)
                @test hdr_after.required_modules[i].build_id_hi == hdr_before.required_modules[i].build_id_hi
                @test hdr_after.required_modules[i].build_id_lo == hdr_before.required_modules[i].build_id_lo
            end
        finally
            isfile(tmp) && rm(tmp)
        end
    end
end

@testitem "remap with no matching spec is no-op" begin
    using JuliaStaticData
    include(joinpath(@__DIR__, "fixtures.jl"))

    ji_files = jsd_find_ji(; limit = 1, parse_header = parse_header,
                           predicate = hdr -> !isempty(hdr.required_modules))

    if isempty(ji_files)
        @info "SKIP remap with no matching spec is no-op: $JSD_FIXTURE_SKIP_MSG"
        @test_skip JSD_FIXTURE_SKIP_MSG
    else
        src = ji_files[1]
        hdr_before = parse_header(src)
        tmp = tempname() * ".ji"
        try
            remap(src, tmp, [RemapSpec("NonexistentModule", nothing, UInt128(42))])
            hdr_after = parse_header(tmp)

            for i in eachindex(hdr_before.required_modules)
                @test hdr_after.required_modules[i].build_id_hi == hdr_before.required_modules[i].build_id_hi
                @test hdr_after.required_modules[i].build_id_lo == hdr_before.required_modules[i].build_id_lo
            end
        finally
            isfile(tmp) && rm(tmp)
        end
    end
end

@testitem "remap worklist build_id.lo" begin
    using JuliaStaticData
    include(joinpath(@__DIR__, "fixtures.jl"))

    ji_files = jsd_find_ji(; limit = 1, parse_header = parse_header,
                           predicate = hdr -> !isempty(hdr.worklist))

    if isempty(ji_files)
        @info "SKIP remap worklist build_id.lo: $JSD_FIXTURE_SKIP_MSG"
        @test_skip JSD_FIXTURE_SKIP_MSG
    else
        src = ji_files[1]
        hdr_before = parse_header(src)
        w = hdr_before.worklist[end]

        target_lo = UInt64(0xAAAABBBBCCCCDDDD)
        target_id = UInt128(target_lo)  # hi=0, lo=target
        spec = RemapSpec(w.name, w.uuid, target_id)

        tmp = tempname() * ".ji"
        try
            remap(src, tmp, [spec]; remap_worklist=true)
            hdr_after = parse_header(tmp)
            w_after = hdr_after.worklist[end]

            @test w_after.name == w.name
            @test w_after.build_id_lo == target_lo
        finally
            isfile(tmp) && rm(tmp)
        end
    end
end
