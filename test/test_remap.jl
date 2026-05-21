using TestItemRunner
using TestItems

@testitem "remap dependency build-id roundtrip" begin
    using JuliaStaticData

    # Find a .ji file with at least one required module
    ji_files = String[]
    depot = get(ENV, "JULIA_DEPOT_PATH", joinpath(homedir(), ".julia"))
    compiled_dir = joinpath(first(split(depot, ':')), "compiled", "v$(VERSION.major).$(VERSION.minor)")
    if isdir(compiled_dir)
        for (root, dirs, files) in walkdir(compiled_dir)
            for f in files
                if endswith(f, ".ji")
                    try
                        hdr = parse_header(joinpath(root, f))
                        if !isempty(hdr.required_modules)
                            push!(ji_files, joinpath(root, f))
                        end
                    catch
                    end
                end
            end
            length(ji_files) >= 1 && break
        end
    end

    @assert !isempty(ji_files) "No .ji files with required_modules found in depot at $compiled_dir"

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

@testitem "remap with no matching spec is no-op" begin
    using JuliaStaticData

    ji_files = String[]
    depot = get(ENV, "JULIA_DEPOT_PATH", joinpath(homedir(), ".julia"))
    compiled_dir = joinpath(first(split(depot, ':')), "compiled", "v$(VERSION.major).$(VERSION.minor)")
    if isdir(compiled_dir)
        for (root, dirs, files) in walkdir(compiled_dir)
            for f in files
                if endswith(f, ".ji")
                    try
                        hdr = parse_header(joinpath(root, f))
                        if !isempty(hdr.required_modules)
                            push!(ji_files, joinpath(root, f))
                        end
                    catch
                    end
                end
            end
            length(ji_files) >= 1 && break
        end
    end

    @assert !isempty(ji_files) "No .ji files with required_modules found in depot"

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

@testitem "remap worklist build_id.lo" begin
    using JuliaStaticData

    ji_files = String[]
    depot = get(ENV, "JULIA_DEPOT_PATH", joinpath(homedir(), ".julia"))
    compiled_dir = joinpath(first(split(depot, ':')), "compiled", "v$(VERSION.major).$(VERSION.minor)")
    if isdir(compiled_dir)
        for (root, dirs, files) in walkdir(compiled_dir)
            for f in files
                if endswith(f, ".ji")
                    try
                        hdr = parse_header(joinpath(root, f))
                        if !isempty(hdr.worklist)
                            push!(ji_files, joinpath(root, f))
                        end
                    catch
                    end
                end
            end
            length(ji_files) >= 1 && break
        end
    end

    @assert !isempty(ji_files) "No .ji files found in depot"

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
