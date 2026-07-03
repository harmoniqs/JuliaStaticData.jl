using TestItemRunner
using TestItems

# Regression tests for identity stamping (`stamp_identity!`), pre-load
# verification (`dry_verify`), and the split-`.so` pkgname/PkgId fallback.
#
# `stamp_identity!` rewrites a module's OWN build-id nonce (build_id.lo) — which
# lives in the serialized data blob, not the header — and recomputes the CRC32C
# so the image stays self-consistent and loadable. This is the operation the
# bundle-v2 minimal-bundle flow uses to re-identify a rebuilt dependency; a
# consumer image is then relinked to it via `remap!`. `dry_verify` lets callers
# sanity-check an image (worklist resolvable + CRC self-consistent) WITHOUT
# loading, so a bad image yields a clean report instead of a segfault or a
# cryptic C-level "Error reading package image file."
#
# The end-to-end item builds two trivial packages User -> Dep in an isolated
# temp depot (like test_flexible_load.jl) and drives the load-exercising steps
# in child processes (two builds/loads of a module name can't coexist in one
# process). It SKIPs cleanly if no C toolchain can emit the companion `.so`.

@testitem "dry_verify rejects a non-image file cleanly (no throw)" begin
    using JuliaStaticData

    for ext in (".so", ".ji")
        tmp = tempname() * ext
        try
            Base.write(tmp, rand(UInt8, 1500))   # random bytes: not a package image
            v = dry_verify(tmp)                   # must return, not throw
            @test v.ok == false
            @test v.parse_ok == false
            @test !isempty(v.messages)
        finally
            isfile(tmp) && rm(tmp)
        end
    end

    # A path that doesn't exist is reported, not thrown.
    v = dry_verify(tempname() * ".so")
    @test v.ok == false
    @test v.parse_ok == false
end

@testitem "stamp_identity! (nonce + self-CRC) + .so pkgname fallback + dry_verify (end-to-end)" begin
    using JuliaStaticData
    include(joinpath(@__DIR__, "fixtures.jl"))

    const STAMP_SKIP_MSG =
        "cannot build split package images here (no C toolchain or build failed); " *
        "identity-stamp round-trip not exercised"

    jsd_src = abspath(joinpath(@__DIR__, "..", "src", "JuliaStaticData.jl"))
    julia_exe = Base.julia_cmd().exec[1]
    have_cc = any(c -> Sys.which(c) !== nothing, ("cc", "gcc", "clang"))

    if !isfile(jsd_src) || !have_cc
        @info "SKIP identity-stamp end-to-end: $STAMP_SKIP_MSG"
        @test_skip STAMP_SKIP_MSG
    else
        work = mktempdir()
        try
            depot = joinpath(work, "depot")
            stash = joinpath(work, "stash")
            scripts = joinpath(work, "scripts")
            for d in (depot, stash, scripts)
                mkpath(d)
            end

            setup_jl = joinpath(scripts, "setup.jl")
            scenario_jl = joinpath(scripts, "scenario.jl")

            write(setup_jl, raw"""
            # setup.jl WORKDIR JSD_SRC
            # Build User -> Dep, precompile to split images, stash both pairs.
            const WORK = ARGS[1]
            const JSD  = ARGS[2]

            import Pkg
            depot = joinpath(WORK, "depot"); env = joinpath(WORK, "env")
            src   = joinpath(WORK, "src");   stash = joinpath(WORK, "stash")
            for d in (depot, env, src, stash); mkpath(d); end

            const VDIR = "v$(VERSION.major).$(VERSION.minor)"
            dep_uuid  = "11111111-1111-1111-1111-111111111111"
            user_uuid = "22222222-2222-2222-2222-222222222222"

            Q = Char(34)   # double-quote, so this can live in a raw"" heredoc
            depdir = joinpath(src, "Dep"); mkpath(joinpath(depdir, "src"))
            write(joinpath(depdir, "Project.toml"),
                  "name = $(Q)Dep$(Q)\nuuid = $(Q)$dep_uuid$(Q)\nversion = $(Q)0.1.0$(Q)\n")
            write(joinpath(depdir, "src", "Dep.jl"),
                  "module Dep\ngreet() = $(Q)Dep v1$(Q)\nend\n")

            userdir = joinpath(src, "User"); mkpath(joinpath(userdir, "src"))
            write(joinpath(userdir, "Project.toml"),
                  "name = $(Q)User$(Q)\nuuid = $(Q)$user_uuid$(Q)\nversion = $(Q)0.1.0$(Q)\n\n[deps]\nDep = $(Q)$dep_uuid$(Q)\n")
            write(joinpath(userdir, "src", "User.jl"),
                  "module User\nusing Dep\nhello() = $(Q)User sees: $(Q) * Dep.greet()\nend\n")

            ENV["JULIA_PKG_OFFLINE"] = "true"
            Pkg.activate(env)
            Pkg.develop(path = depdir)
            Pkg.develop(path = userdir)
            Pkg.precompile()

            include(JSD); using .JuliaStaticData

            cdir(name) = joinpath(depot, "compiled", VDIR, name)
            jis(name)  = sort!(filter(f -> endswith(f, ".ji"), readdir(cdir(name))))
            pair(name) = (jf = first(jis(name)); (joinpath(cdir(name), jf),
                          joinpath(cdir(name), splitext(jf)[1] * ".so")))

            dep_ji, dep_so  = pair("Dep")
            user_ji, user_so = pair("User")
            if !isfile(dep_so) || !isfile(user_so)
                println("SETUP NO_SO"); exit(0)
            end

            stash_pair(tag, ji, so) = begin
                d = joinpath(stash, tag); mkpath(d)
                nji = joinpath(d, basename(ji)); nso = joinpath(d, basename(so))
                cp(ji, nji; force=true); cp(so, nso; force=true)
                (nji, nso)
            end
            s_dep_ji, s_dep_so   = stash_pair("dep",  dep_ji,  dep_so)
            s_user_ji, s_user_so = stash_pair("user", user_ji, user_so)

            open(joinpath(stash, "manifest.txt"), "w") do io
                for (k, v) in ("DEP_JI"=>s_dep_ji, "DEP_SO"=>s_dep_so,
                               "USER_JI"=>s_user_ji, "USER_SO"=>s_user_so)
                    println(io, "$k=$v")
                end
            end
            println("SETUP OK")
            """)

            write(scenario_jl, raw"""
            # scenario.jl MODE STASH JSD_SRC     MODE in {STAMP, STALE}
            const MODE  = ARGS[1]
            const STASH = ARGS[2]
            const JSD   = ARGS[3]

            M = Dict{String,String}()
            for line in eachline(joinpath(STASH, "manifest.txt"))
                isempty(line) && continue
                k, v = split(line, "=", limit=2); M[k] = v
            end

            include(JSD); using .JuliaStaticData
            call_hello(u) = Base.invokelatest(getglobal(u, :hello))

            function stage(tmp, key)
                p = M[key]; q = joinpath(tmp, basename(p)); cp(p, q; force=true); q
            end

            # STAMP: re-identify Dep with a NEW nonce + self-consistent CRC, load
            # it via the .SO PATH DIRECTLY (exercises the pkgname/PkgId fallback
            # to the companion .ji), relink User to the new build-id, and load.
            function scenarioSTAMP()
                println("=== STAMP: stamp_identity! + .so direct load + relink ===")
                tmp = mktempdir()
                dso = stage(tmp, "DEP_SO"); stage(tmp, "DEP_JI")
                newlo = UInt64(0xABCDEF0123456789)
                res = stamp_identity!(dso; build_id_lo=newlo)
                v = dry_verify(dso)
                println("STAMP_VERIFY ok=", v.ok, " crc_ok=", v.crc_ok, " worklist_ok=", v.worklist_ok)
                dep = load_package_image(dso)   # .so directly -> pkgname from companion .ji
                b = Base.module_build_id(dep)
                println("STAMP_BID name=", nameof(dep), " nonce_ok=", (b & typemax(UInt64)) == newlo,
                        " ck_ok=", (b >> 64) == res.checksum)
                uso = stage(tmp, "USER_SO"); uji = stage(tmp, "USER_JI")
                spec = [RemapSpec("Dep", nothing, b)]
                remap!(uji, spec); remap!(uso, spec)
                u = load_package_image(uso)
                println("RESULT_STAMP: ", repr(call_hello(u)))
            end

            # STALE: stamp the nonce but SKIP the CRC recompute -> the CRC is now
            # inconsistent. dry_verify must flag it, and the C loader must reject
            # it cleanly ("Error reading package image file").
            function scenarioSTALE()
                println("=== STALE: nonce stamped, self_crc=false ===")
                tmp = mktempdir()
                dso = stage(tmp, "DEP_SO"); stage(tmp, "DEP_JI")
                stamp_identity!(dso; build_id_lo=UInt64(0x1111222233334444), self_crc=false)
                v = dry_verify(dso)
                println("STALE_VERIFY crc_ok=", v.crc_ok, " ok=", v.ok)
                try
                    load_package_image(dso)
                    println("RESULT_STALE: UNEXPECTED_LOAD")
                catch e
                    println("RESULT_STALE: EXPECTED_FAIL ", sprint(showerror, e))
                end
            end

            MODE == "STAMP" ? scenarioSTAMP() :
            MODE == "STALE" ? scenarioSTALE() : error("unknown mode $MODE")
            println("SCENARIO $MODE DONE")
            """)

            childenv = copy(ENV)
            childenv["JULIA_DEPOT_PATH"] = depot * ":"
            childenv["JULIA_PKG_OFFLINE"] = "true"
            childenv["JULIA_LOAD_PATH"] = "@:@stdlib"
            delete!(childenv, "JULIA_PROJECT")

            run_julia(script, args) = begin
                cmd = `$julia_exe --startup-file=no --color=no $script $args`
                out = IOBuffer()
                proc = run(pipeline(setenv(cmd, childenv); stdout=out, stderr=out); wait=false)
                wait(proc)
                (success(proc), String(take!(out)))
            end

            setup_ok, setup_out = run_julia(setup_jl, [work, jsd_src])
            @info "identity-stamp SETUP output:\n$setup_out"

            if !setup_ok || occursin("SETUP NO_SO", setup_out) ||
               !isfile(joinpath(stash, "manifest.txt"))
                @info "SKIP identity-stamp end-to-end: $STAMP_SKIP_MSG"
                @test_skip STAMP_SKIP_MSG
            else
                @test occursin("SETUP OK", setup_out)

                # Parent-side (no module loading): the freshly-built Dep.so must
                # verify, and a self_crc=false stamp must make dry_verify flag it.
                dep_so = joinpath(stash, "dep", basename(readdir(joinpath(stash, "dep")) |>
                          xs -> only(filter(x -> endswith(x, ".so"), xs))))
                @test dry_verify(dep_so).ok

                perturb = mktempdir()
                for f in readdir(joinpath(stash, "dep"); join=true)
                    cp(f, joinpath(perturb, basename(f)); force=true)
                end
                pso = only(filter(x -> endswith(x, ".so"), readdir(perturb; join=true)))
                stamp_identity!(pso; build_id_lo=UInt64(0xDEADBEEFDEADBEEF), self_crc=false)
                vstale = dry_verify(pso)
                @test vstale.crc_ok == false
                @test vstale.ok == false

                okS, outS = run_julia(scenario_jl, ["STAMP", stash, jsd_src])
                okT, outT = run_julia(scenario_jl, ["STALE", stash, jsd_src])
                @info "STAMP:\n$outS\nSTALE:\n$outT"

                # STAMP — stamped image verifies, loads via the .so directly with
                # the new identity, and User relinks against it.
                @test okS
                @test occursin("SCENARIO STAMP DONE", outS)
                @test occursin("STAMP_VERIFY ok=true", outS)
                @test occursin("STAMP_BID name=Dep nonce_ok=true ck_ok=true", outS)
                @test occursin("RESULT_STAMP: \"User sees: Dep v1\"", outS)

                # STALE — dry_verify flags the CRC, and the loader rejects cleanly.
                @test okT
                @test occursin("SCENARIO STALE DONE", outT)
                @test occursin("STALE_VERIFY crc_ok=false", outT)
                @test occursin("RESULT_STALE: EXPECTED_FAIL", outT)
                @test occursin("Error reading package image file", outT)
                @test !occursin("UNEXPECTED_LOAD", outT)
            end
        finally
            rm(work; force=true, recursive=true)
        end
    end
end
