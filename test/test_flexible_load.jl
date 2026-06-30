using TestItemRunner
using TestItems

# End-to-end regression for FLEXIBLE source-free loading with build-id remapping.
#
# This locks in the full round-trip that `remap!` + `load_package_image` exist to
# enable: take a precompiled package image whose dependency has since been rebuilt
# under a NEW build-id, rewrite the recorded build-id in the image (BOTH the `.so`
# the C loader reads and the `.ji` header `resolve_dep` reads), and load it
# source-free so it RELINKS against the new dependency.
#
# Concretely it builds two trivial packages User -> Dep in an isolated temp depot:
#
#   1. SETUP   precompile Dep@v1 + User (User records Dep@build_id_1), stash both
#              images, then perturb Dep's source and recompile -> Dep@build_id_2.
#   2. A       positive control: load User against the Dep it was built with
#              -> User.hello() == "User sees: Dep v1".
#   3. B1      load STALE User against Dep@v2 with NO remap
#              -> clean failure in resolve_dep ("build_id ... not found").
#   4. B2      remap User's recorded Dep build-id -> build_id_2 in BOTH .so and .ji,
#              then load source-free -> loads AND relinks: User.hello()=="Dep v2".
#   5. B3      negative control: remap to a BOGUS build-id -> clean failure.
#
# WHY CHILD PROCESSES: two builds of the module name `Dep` cannot coexist in one
# Julia process (modules can't be unloaded), so each cross-build step runs in its
# own `julia` child, and we assert on captured stdout — mirroring the manual
# experiment's run.sh. The children `include` the JSD source directly (the package
# has zero deps), exactly as the experiment does.
#
# SKIP POLICY: building a split `.so` package image needs a working C toolchain.
# If none is available (or SETUP otherwise can't produce images), the test skips
# cleanly via @test_skip rather than failing.

@testitem "flexible source-free load with build-id remap (end-to-end)" begin
    using JuliaStaticData   # only used to confirm the package itself loads here
    include(joinpath(@__DIR__, "fixtures.jl"))

    const FLEX_SKIP_MSG =
        "cannot build split package images here (no C toolchain or build failed); " *
        "flexible-load round-trip not exercised"

    # ── Locate the bits the child processes need ────────────────────────────
    jsd_src = abspath(joinpath(@__DIR__, "..", "src", "JuliaStaticData.jl"))
    julia_exe = Base.julia_cmd().exec[1]

    # A C compiler/linker is required to emit the companion `.so`. If absent we
    # skip rather than fail (e.g. minimal CI images without a toolchain).
    have_cc = any(c -> Sys.which(c) !== nothing, ("cc", "gcc", "clang"))

    if !isfile(jsd_src) || !have_cc
        @info "SKIP flexible source-free load: $FLEX_SKIP_MSG"
        @test_skip FLEX_SKIP_MSG
    else
        # Everything (depot, env, sources, stash) lives under one temp dir that we
        # delete at the end. We NEVER touch the user's ~/.julia depot: the child
        # processes run with JULIA_DEPOT_PATH pointed at this isolated depot.
        work = mktempdir()
        try
            depot = joinpath(work, "depot")
            stash = joinpath(work, "stash")
            scripts = joinpath(work, "scripts")
            for d in (depot, stash, scripts)
                mkpath(d)
            end

            # ── Self-contained child scripts (written here, not external files) ──
            setup_jl = joinpath(scripts, "setup.jl")
            scenario_jl = joinpath(scripts, "scenario.jl")

            write(setup_jl, raw"""
            # setup.jl WORKDIR JSD_SRC
            # Build User -> Dep, precompile (Dep@v1) + User, stash images, then
            # perturb Dep -> v2 and recompile Dep only. Writes stash/manifest.txt.
            const WORK = ARGS[1]
            const JSD  = ARGS[2]

            import Pkg
            depot = joinpath(WORK, "depot"); env = joinpath(WORK, "env")
            src   = joinpath(WORK, "src");   stash = joinpath(WORK, "stash")
            for d in (depot, env, src, stash); mkpath(d); end

            const VDIR = "v$(VERSION.major).$(VERSION.minor)"
            dep_uuid  = "11111111-1111-1111-1111-111111111111"
            user_uuid = "22222222-2222-2222-2222-222222222222"

            # Q is a double-quote char built from its codepoint so this script can
            # live inside a raw"" heredoc without escaped-quote ambiguity.
            Q = Char(34)
            depdir = joinpath(src, "Dep"); mkpath(joinpath(depdir, "src"))
            write(joinpath(depdir, "Project.toml"),
                  "name = $(Q)Dep$(Q)\nuuid = $(Q)$dep_uuid$(Q)\nversion = $(Q)0.1.0$(Q)\n")
            write(joinpath(depdir, "src", "Dep.jl"),
                  "module Dep\nconst TAG = :v1\ngreet() = $(Q)Dep v1$(Q)\nend\n")

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
            pair(name, jifile) = (joinpath(cdir(name), jifile),
                                  joinpath(cdir(name), splitext(jifile)[1] * ".so"))

            dep_v1_ji, dep_v1_so = pair("Dep", first(jis("Dep")))
            user_ji,   user_so   = pair("User", first(jis("User")))

            # A split image MUST have produced a companion .so; if the toolchain
            # could not link it, bail so the parent SKIPs instead of asserting.
            if !isfile(user_so) || !isfile(dep_v1_so)
                println("SETUP NO_SO")
                exit(0)
            end

            stash_pair(tag, ji, so) = begin
                d = joinpath(stash, tag); mkpath(d)
                nji = joinpath(d, basename(ji)); nso = joinpath(d, basename(so))
                cp(ji, nji; force = true); cp(so, nso; force = true)
                (nji, nso)
            end
            s_dep1_ji, s_dep1_so = stash_pair("dep_v1", dep_v1_ji, dep_v1_so)
            s_user_ji, s_user_so = stash_pair("user",   user_ji,   user_so)

            # Perturb Dep -> v2 and recompile Dep only (cache filename is stable;
            # only the build-id bytes inside change), so current Dep image is v2.
            write(joinpath(depdir, "src", "Dep.jl"),
                  "module Dep\nconst TAG = :v2\ngreet() = $(Q)Dep v2$(Q)\nend\n")
            Pkg.activate(env)
            Pkg.precompile("Dep")

            dep_v2_ji, dep_v2_so = pair("Dep", first(jis("Dep")))
            s_dep2_ji, s_dep2_so = stash_pair("dep_v2", dep_v2_ji, dep_v2_so)

            open(joinpath(stash, "manifest.txt"), "w") do io
                for (k, v) in ("DEP_V1_JI" => s_dep1_ji, "DEP_V1_SO" => s_dep1_so,
                               "DEP_V2_JI" => s_dep2_ji, "DEP_V2_SO" => s_dep2_so,
                               "USER_JI" => s_user_ji,   "USER_SO" => s_user_so)
                    println(io, "$k=$v")
                end
            end
            println("SETUP OK")
            """)

            write(scenario_jl, raw"""
            # scenario.jl MODE STASH JSD_SRC      MODE in {A, B1, B2, B3}
            const MODE  = ARGS[1]
            const STASH = ARGS[2]
            const JSD   = ARGS[3]

            M = Dict{String,String}()
            for line in eachline(joinpath(STASH, "manifest.txt"))
                isempty(line) && continue
                k, v = split(line, "=", limit = 2); M[k] = v
            end

            include(JSD); using .JuliaStaticData

            bid(m) = repr(Base.module_build_id(m))
            # Freshly-loaded methods live in a newer world age than this running
            # script, so call them via invokelatest (normal for runtime code load).
            call_hello(u) = Base.invokelatest(getglobal(u, :hello))

            function scenarioA()
                println("=== A: positive control ===")
                load_package_image(M["DEP_V1_JI"])
                u = load_package_image(M["USER_JI"])
                println("RESULT_A: ", repr(call_hello(u)))
            end

            function scenarioB1()
                println("=== B1: stale User vs Dep v2, NO remap (expect clean fail) ===")
                load_package_image(M["DEP_V2_JI"])
                try
                    u = load_package_image(M["USER_JI"])
                    println("RESULT_B1: UNEXPECTED_LOAD ", repr(call_hello(u)))
                catch e
                    println("RESULT_B1: EXPECTED_FAIL ", sprint(showerror, e))
                end
            end

            function scenarioB2()
                println("=== B2: remap Dep build-id -> v2, then load ===")
                dep2 = load_package_image(M["DEP_V2_JI"])
                b2 = Base.module_build_id(dep2)

                tmp = mktempdir()
                uji = joinpath(tmp, basename(M["USER_JI"])); cp(M["USER_JI"], uji)
                uso = joinpath(tmp, basename(M["USER_SO"])); cp(M["USER_SO"], uso)

                spec = [RemapSpec("Dep", nothing, b2)]
                remap!(uso, spec)   # .so is what the C restore step reads
                remap!(uji, spec)   # .ji header is what resolve_dep reads
                try
                    u = load_package_image(uji)
                    println("RESULT_B2: LOADED ", repr(call_hello(u)))
                catch e
                    println("RESULT_B2: FAIL ", sprint(showerror, e))
                end
            end

            function scenarioB3()
                println("=== B3: negative control — remap to BOGUS build-id ===")
                load_package_image(M["DEP_V2_JI"])
                bogus = UInt128(0xDEADBEEFDEADBEEF) << 64 | UInt128(0x0BADC0DE0BADC0DE)

                tmp = mktempdir()
                uji = joinpath(tmp, basename(M["USER_JI"])); cp(M["USER_JI"], uji)
                uso = joinpath(tmp, basename(M["USER_SO"])); cp(M["USER_SO"], uso)

                spec = [RemapSpec("Dep", nothing, bogus)]
                remap!(uso, spec)
                remap!(uji, spec)
                try
                    u = load_package_image(uji)
                    println("RESULT_B3: UNEXPECTED_LOAD ", repr(call_hello(u)))
                catch e
                    println("RESULT_B3: EXPECTED_FAIL ", sprint(showerror, e))
                end
            end

            MODE == "A"  ? scenarioA()  :
            MODE == "B1" ? scenarioB1() :
            MODE == "B2" ? scenarioB2() :
            MODE == "B3" ? scenarioB3() : error("unknown mode $MODE")
            println("SCENARIO $MODE DONE")
            """)

            # ── Child-process orchestration (mirrors run.sh) ────────────────────
            # All children run in the isolated depot. The trailing ':' keeps Julia's
            # bundled stdlib depot on the path without writing to ~/.julia.
            #
            # We run under Pkg.test's sandbox, whose JULIA_PROJECT / JULIA_LOAD_PATH
            # point at a temp test env where Pkg/stdlibs aren't resolvable. Children
            # need a clean base load path (so `import Pkg` and stdlibs work) and each
            # child sets its OWN active project via Pkg.activate, so we strip the
            # inherited project and pin a stdlib-only load path.
            childenv = copy(ENV)
            childenv["JULIA_DEPOT_PATH"] = depot * ":"
            childenv["JULIA_PKG_OFFLINE"] = "true"
            childenv["JULIA_LOAD_PATH"] = "@:@stdlib"
            delete!(childenv, "JULIA_PROJECT")

            run_julia(script::String, args::Vector{String}) = begin
                cmd = `$julia_exe --startup-file=no --color=no $script $args`
                out = IOBuffer()
                proc = run(pipeline(setenv(cmd, childenv); stdout=out, stderr=out); wait=false)
                wait(proc)
                (success(proc), String(take!(out)))
            end

            # SETUP: build + precompile + perturb in the isolated depot.
            setup_ok, setup_out = run_julia(setup_jl, [work, jsd_src])
            @info "flexible-load SETUP output:\n$setup_out"

            if !setup_ok || occursin("SETUP NO_SO", setup_out) ||
               !isfile(joinpath(stash, "manifest.txt"))
                # Could not produce split images here — skip rather than fail.
                @info "SKIP flexible source-free load: $FLEX_SKIP_MSG"
                @test_skip FLEX_SKIP_MSG
            else
                @test occursin("SETUP OK", setup_out)

                okA, outA = run_julia(scenario_jl, ["A",  stash, jsd_src])
                okB1, outB1 = run_julia(scenario_jl, ["B1", stash, jsd_src])
                okB2, outB2 = run_julia(scenario_jl, ["B2", stash, jsd_src])
                okB3, outB3 = run_julia(scenario_jl, ["B3", stash, jsd_src])
                @info "A:\n$outA\nB1:\n$outB1\nB2:\n$outB2\nB3:\n$outB3"

                # A — positive control: User loads against the Dep it was built with.
                @test okA
                @test occursin("SCENARIO A DONE", outA)
                @test occursin("RESULT_A: \"User sees: Dep v1\"", outA)

                # B1 — stale User against Dep v2 with NO remap: clean resolve failure.
                @test okB1
                @test occursin("SCENARIO B1 DONE", outB1)
                @test occursin("RESULT_B1: EXPECTED_FAIL", outB1)
                @test occursin("Cannot resolve dependency", outB1)
                @test !occursin("UNEXPECTED_LOAD", outB1)

                # B2 — THE regression: remap recorded Dep build-id -> v2 in BOTH the
                # .so and .ji, then load source-free. It must load AND relink, so
                # hello() reflects the NEW dependency ("Dep v2").
                @test okB2
                @test occursin("SCENARIO B2 DONE", outB2)
                @test occursin("RESULT_B2: LOADED \"User sees: Dep v2\"", outB2)

                # B3 — negative control: remap to a bogus build-id must fail cleanly
                # (no crash, no spurious load).
                @test okB3
                @test occursin("SCENARIO B3 DONE", outB3)
                @test occursin("RESULT_B3: EXPECTED_FAIL", outB3)
                @test !occursin("UNEXPECTED_LOAD", outB3)
            end
        finally
            rm(work; force = true, recursive = true)
        end
    end
end
