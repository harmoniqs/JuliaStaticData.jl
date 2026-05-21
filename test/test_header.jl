using TestItemRunner
using TestItems

@testitem "parse real .ji files from depot" begin
    using JuliaStaticData

    ji_files = String[]
    depot = get(ENV, "JULIA_DEPOT_PATH", joinpath(homedir(), ".julia"))
    compiled_dir = joinpath(first(split(depot, ':')), "compiled", "v$(VERSION.major).$(VERSION.minor)")
    if isdir(compiled_dir)
        for (root, dirs, files) in walkdir(compiled_dir)
            for f in files
                endswith(f, ".ji") && push!(ji_files, joinpath(root, f))
            end
            length(ji_files) >= 3 && break
        end
    end

    @assert !isempty(ji_files) "No .ji files found in depot at $compiled_dir"

    for f in ji_files[1:min(3, length(ji_files))]
        hdr = parse_header(f)

        @test hdr.format_version >= 12
        @test hdr.pointer_size in (4, 8)
        @test !isempty(hdr.julia_version)
        is_split = isfile(splitext(f)[1] * ".so") || isfile(splitext(f)[1] * ".dylib")
        if is_split
            # Split images: .ji has pkgimage=false, data offsets are 0
            # (data blob and its offsets live in the companion .so)
            @test hdr.data_start == 0
            @test hdr.data_end == 0
            @test !hdr.pkgimage  # .ji half always has pkgimage=false

            # The companion .so should have pkgimage=true and valid data offsets
            so_path = splitext(f)[1] * ".so"
            if isfile(so_path)
                so_hdr = parse_header(so_path)
                @test so_hdr.pkgimage
                @test so_hdr.data_end > so_hdr.data_start
            end
        else
            # Non-split: data blob is in the .ji itself
            @test hdr.data_end > hdr.data_start
        end
        @test !isempty(hdr.worklist)

        for w in hdr.worklist
            @test !isempty(w.name)
            @test w.build_id_lo != 0
        end

        for d in hdr.required_modules
            @test !isempty(d.name)
        end

        buf = IOBuffer()
        inspect(hdr; io=buf)
        output = String(take!(buf))
        @test contains(output, "Julia Package Image Header")
        @test contains(output, hdr.worklist[end].name)
    end
end

@testitem "reject non-.ji file" begin
    using JuliaStaticData

    tmp = tempname() * ".ji"
    try
        Base.write(tmp, "not a julia file at all")
        @test_throws ArgumentError parse_header(tmp)
    finally
        isfile(tmp) && rm(tmp)
    end
end
