using TestItemRunner
using TestItems

# Regression tests for the CLOSURE-LAW guardrail (`verify_closure`) and its
# `load_package_image(; check_closure=true)` wiring.
#
# LAW: when loading a set of images whose identities were stamped/remapped, the
# set must be CLOSED under `required_modules`. A *mixed universe* — some deps
# resolved from stamped/new-lineage images, others from old-lineage ones —
# segfaults in `jl_validate_binding_partition` inside the C restore path.
# `verify_closure` parses headers only (never loads) and turns that crash into a
# clean, actionable `ClosureReport` BEFORE any ccall.
#
# The item builds two trivial packages User -> Dep in an isolated temp depot and
# perturbs Dep to a second build-id (v2), exactly like test_flexible_load.jl —
# but with `--pkgimages=no`, so it needs NO C toolchain (only `.ji` files) and
# the closure checks run in-process (no child processes: nothing is loaded).
#
# It exercises the three verdicts on a controlled set:
#   * CLOSED        [User, Dep@v1]            -> ok, no missing
#   * ABSENT        [User]                    -> Dep offered nowhere
#   * MIXED LINEAGE [User(refs v1), Dep@v2]   -> Dep offered under a different
#                                                 build-id (the segfault class)

@testitem "verify_closure: closed / absent / mixed-lineage + check_closure guard" begin
    using JuliaStaticData

    const CLOSURE_SKIP_MSG =
        "could not precompile the User->Dep fixture (.ji-only build failed); " *
        "closure guardrail not exercised"

    jsd_src = abspath(joinpath(@__DIR__, "..", "src", "JuliaStaticData.jl"))
    julia_exe = Base.julia_cmd().exec[1]

    work = mktempdir()
    try
        depot = joinpath(work, "depot")
        scripts = joinpath(work, "scripts")
        stash = joinpath(work, "stash")
        for d in (depot, scripts, stash)
            mkpath(d)
        end

        setup_jl = joinpath(scripts, "setup.jl")
        write(setup_jl, raw"""
        # setup.jl WORKDIR   (run with --pkgimages=no: emits .ji-only, no C toolchain)
        # Build User -> Dep, precompile (Dep@v1) + User, stash the .ji files, then
        # perturb Dep -> v2 and recompile so we also have Dep@v2's .ji.
        const WORK = ARGS[1]
        import Pkg
        depot = joinpath(WORK, "depot"); env = joinpath(WORK, "env")
        src   = joinpath(WORK, "src");   stash = joinpath(WORK, "stash")
        for d in (depot, env, src, stash); mkpath(d); end

        const VDIR = "v$(VERSION.major).$(VERSION.minor)"
        Q = Char(34)
        dep_uuid  = "11111111-1111-1111-1111-111111111111"
        user_uuid = "22222222-2222-2222-2222-222222222222"

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

        cdir(name) = joinpath(depot, "compiled", VDIR, name)
        jipath(name) = joinpath(cdir(name),
                                first(sort!(filter(f -> endswith(f, ".ji"), readdir(cdir(name))))))
        stash_ji(tag, ji) = (d = joinpath(stash, tag); mkpath(d);
                             q = joinpath(d, basename(ji)); cp(ji, q; force = true); q)

        s_dep1 = stash_ji("dep_v1", jipath("Dep"))
        s_user = stash_ji("user",   jipath("User"))

        # Perturb Dep -> v2 and recompile Dep only (new build-id, stable filename).
        write(joinpath(depdir, "src", "Dep.jl"),
              "module Dep\nconst TAG = :v2\ngreet() = $(Q)Dep v2$(Q)\nend\n")
        Pkg.activate(env); Pkg.precompile("Dep")
        s_dep2 = stash_ji("dep_v2", jipath("Dep"))

        open(joinpath(stash, "manifest.txt"), "w") do io
            for (k, v) in ("DEP_V1" => s_dep1, "DEP_V2" => s_dep2, "USER" => s_user)
                println(io, "$k=$v")
            end
        end
        println("SETUP OK")
        """)

        childenv = copy(ENV)
        childenv["JULIA_DEPOT_PATH"] = depot * ":"
        childenv["JULIA_PKG_OFFLINE"] = "true"
        childenv["JULIA_LOAD_PATH"] = "@:@stdlib"
        delete!(childenv, "JULIA_PROJECT")

        # `--pkgimages=no` makes precompile emit `.ji`-only caches: no C toolchain
        # is needed to produce the fixture, so this test runs even on minimal images.
        cmd = `$julia_exe --startup-file=no --color=no --pkgimages=no $setup_jl $work`
        out = IOBuffer()
        proc = run(pipeline(setenv(cmd, childenv); stdout=out, stderr=out); wait=false)
        wait(proc)
        setup_ok = success(proc)
        setup_out = String(take!(out))
        @info "closure SETUP output:\n$setup_out"

        if !setup_ok || !occursin("SETUP OK", setup_out) ||
           !isfile(joinpath(stash, "manifest.txt"))
            @info "SKIP verify_closure: $CLOSURE_SKIP_MSG"
            @test_skip CLOSURE_SKIP_MSG
        else
            M = Dict{String,String}()
            for line in eachline(joinpath(stash, "manifest.txt"))
                isempty(line) && continue
                k, v = split(line, "=", limit = 2); M[k] = v
            end
            user, dep_v1, dep_v2 = M["USER"], M["DEP_V1"], M["DEP_V2"]

            # ── CLOSED: User's Dep dependency is provided by Dep@v1 in the set ──
            # check_loaded=false makes the verdict depend ONLY on the passed set,
            # not on whatever the test runner happens to have loaded.
            closed = verify_closure([user, dep_v1]; check_loaded = false)
            @test closed isa ClosureReport
            @test closed.ok
            @test isempty(closed.missing)
            @test closed.required == 1          # exactly one non-sysimage dep (Dep)
            @test closed.provided == 2          # User and Dep worklists

            # ── ABSENT: Dep offered by no image in the set (and not loaded here) ──
            absent = verify_closure([user]; check_loaded = false)
            @test !absent.ok
            @test length(absent.missing) == 1
            @test absent.missing[1].name == "Dep"
            @test absent.missing[1].reason == :absent
            @test any(m -> occursin("ABSENT", m) && occursin("Dep", m), absent.messages)

            # ── MIXED LINEAGE: User records Dep@v1, but the set offers only Dep@v2 ──
            # This is the segfault-class violation the law targets.
            mixed = verify_closure([user, dep_v2]; check_loaded = false)
            @test !mixed.ok
            @test length(mixed.missing) == 1
            @test mixed.missing[1].name == "Dep"
            @test mixed.missing[1].reason == :mixed_lineage
            @test !isempty(mixed.missing[1].other_lineages)   # the v2 build-id
            @test any(m -> occursin("MIXED LINEAGE", m), mixed.messages)

            # ── check_closure guard on load_package_image ──
            # Loading User alone (Dep neither in a set nor loaded here) must FAIL
            # FAST with a clean ArgumentError from the closure check, never reaching
            # the ccall. Default check_closure=false leaves single-image loads as-is.
            err = try
                load_package_image(user; check_closure = true)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("closure", sprint(showerror, err))
        end
    finally
        rm(work; force = true, recursive = true)
    end
end
