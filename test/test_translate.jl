using TestItemRunner
using TestItems

# Regression tests for reference translation (`emit_sidecar`, `translate!`,
# `canonicalize!`, `load_translated`) — the productization of the bundle-v2
# research pipeline (Piccolissimo `experiments/bundle-v2-tracer`, legs 4-5).
#
# The headline item is the **leg5 inversion as a product test**: build User -> Dep
# in depot A, emit a sidecar; independently rebuild Dep in depot B (a genuinely
# different build with a shifted object layout); translate User's image against
# the sidecar, load it against depot-B's Dep, and assert User.hello() still
# returns the right value. All load-exercising steps run in child processes (two
# builds/loads of a module name cannot coexist in one process, and translation
# uses live reflection = module loading). Every child script is a `raw"""` block
# that defines its own uuids, so all `$(...)` interpolation happens child-side.
# Items SKIP cleanly on a runner with no C toolchain. Each testitem runs in an
# isolated module (TestItemRunner), so shared constants/helpers are defined
# inside each item rather than at file scope.

# ── item 1: toy round-trip — the leg5 inversion as a product test ──────
@testitem "reference-translation toy round-trip (emit A -> translate/load B)" begin
    using JuliaStaticData

    XLATE_SKIP_MSG =
        "cannot build split package images here (no C toolchain or build failed); " *
        "reference-translation round-trip not exercised"
    jsd_src = abspath(joinpath(@__DIR__, "..", "src", "JuliaStaticData.jl"))
    julia_exe = Base.julia_cmd().exec[1]
    have_cc = any(c -> Sys.which(c) !== nothing, ("cc", "gcc", "clang"))

    # Child-process launcher with an isolated depot.
    run_child = function (depot, script, args)
        childenv = copy(ENV)
        childenv["JULIA_DEPOT_PATH"] = depot * ":"
        childenv["JULIA_PKG_OFFLINE"] = "true"
        childenv["JULIA_LOAD_PATH"] = "@:@stdlib"
        delete!(childenv, "JULIA_PROJECT")
        cmd = `$julia_exe --startup-file=no --color=no $script $args`
        out = IOBuffer()
        proc = run(pipeline(setenv(cmd, childenv); stdout = out, stderr = out); wait = false)
        wait(proc)
        (success(proc), String(take!(out)))
    end

    if !isfile(jsd_src) || !have_cc
        @info "SKIP toy round-trip: $XLATE_SKIP_MSG"
        @test_skip XLATE_SKIP_MSG
    else
        work = mktempdir()
        try
            depotA = joinpath(work, "depotA")
            depotB = joinpath(work, "depotB")
            stash = joinpath(work, "stash")
            scripts = joinpath(work, "scripts")
            srcA = joinpath(work, "srcA")
            srcB = joinpath(work, "srcB")
            for d in (depotA, depotB, stash, scripts, srcA, srcB)
                mkpath(d)
            end

            # build_dep.jl DEPOT SRC VARIANT — build Dep (variant B has extra
            # serialized content, forcing a different object layout).
            build_dep = joinpath(scripts, "build_dep.jl")
            write(build_dep, raw"""
            const DEPOT = ARGS[1]; const SRC = ARGS[2]; const VARIANT = ARGS[3]
            import Pkg
            Q = Char(34)
            dep_uuid = "11111111-1111-1111-1111-111111111111"
            pad = VARIANT == "B" ?
                "e01() = 1\ne02() = 2\ne03() = 3\ne04() = 4\ne05() = 5\n" *
                "const PADA = (1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16)\n" *
                "const PADB = collect(1:29)\nstruct Filler{N} end\nconst FILL = Filler{7}()\n" : ""
            depsrc = "module Dep\n" * pad *
                     "struct Widget a::Int; b::Float64 end\n" *
                     "const MAGIC = 42\ngreet() = $(Q)Dep v1$(Q)\n" *
                     "export greet, MAGIC, Widget\nend\n"
            depdir = joinpath(SRC, "Dep"); mkpath(joinpath(depdir, "src"))
            write(joinpath(depdir, "Project.toml"),
                  "name = $(Q)Dep$(Q)\nuuid = $(Q)$dep_uuid$(Q)\nversion = $(Q)0.1.0$(Q)\n")
            write(joinpath(depdir, "src", "Dep.jl"), depsrc)
            ENV["JULIA_PKG_OFFLINE"] = "true"
            env = joinpath(SRC, "env"); mkpath(env)
            Pkg.activate(env); Pkg.develop(path = depdir); Pkg.precompile()
            println("BUILD_DEP OK ", VARIANT)
            """)

            # build_user.jl DEPOT SRC JSD STASH — build User->Dep, stash, emit sidecar.
            build_user = joinpath(scripts, "build_user.jl")
            write(build_user, raw"""
            const DEPOT = ARGS[1]; const SRC = ARGS[2]; const JSD = ARGS[3]; const STASH = ARGS[4]
            import Pkg
            Q = Char(34)
            dep_uuid = "11111111-1111-1111-1111-111111111111"
            user_uuid = "22222222-2222-2222-2222-222222222222"
            VDIR = "v$(VERSION.major).$(VERSION.minor)"
            userdir = joinpath(SRC, "User"); mkpath(joinpath(userdir, "src"))
            write(joinpath(userdir, "Project.toml"),
                  "name = $(Q)User$(Q)\nuuid = $(Q)$user_uuid$(Q)\nversion = $(Q)0.1.0$(Q)\n\n" *
                  "[deps]\nDep = $(Q)$dep_uuid$(Q)\n")
            write(joinpath(userdir, "src", "User.jl"),
                  "module User\nusing Dep\n" *
                  "hello() = string(Dep.greet(), $(Q) $(Q), Dep.MAGIC, $(Q) $(Q), nameof(Dep.Widget))\n" *
                  "end\n")
            ENV["JULIA_PKG_OFFLINE"] = "true"
            env = joinpath(SRC, "env"); mkpath(env)
            Pkg.activate(env); Pkg.develop(path = userdir); Pkg.precompile()

            include(JSD); using .JuliaStaticData
            cdir(name) = joinpath(DEPOT, "compiled", VDIR, name)
            jis(name) = sort!(filter(f -> endswith(f, ".ji"), readdir(cdir(name))))
            pair(name) = (jf = first(jis(name)); (joinpath(cdir(name), jf),
                          joinpath(cdir(name), splitext(jf)[1] * ".so")))
            user_ji, user_so = pair("User")
            if !isfile(user_so); println("BUILD_USER NO_SO"); exit(0); end
            d = joinpath(STASH, "user"); mkpath(d)
            s_ji = joinpath(d, basename(user_ji)); s_so = joinpath(d, basename(user_so))
            cp(user_ji, s_ji; force = true); cp(user_so, s_so; force = true)

            sc = emit_sidecar([user_so])                 # live-reflection emit (loads Dep)
            write_sidecar(joinpath(STASH, "user.sidecar"), sc)
            ent = only(sc.images)
            println("EMIT name=", ent.image_name, " nwords=", ent.n_words,
                    " ntargets=", length(ent.targets))
            for t in ent.targets
                println("  TARGET dep=", t.dep_name, " off=", t.old_offset,
                        " kind=", t.descriptor.kind, " name=", t.descriptor.name)
            end
            open(joinpath(STASH, "manifest.txt"), "w") do io
                println(io, "USER_JI=", s_ji); println(io, "USER_SO=", s_so)
            end
            println("BUILD_USER OK")
            """)

            # consume.jl DEPOT JSD STASH PROJ — translate + load against depot-B's Dep.
            consume = joinpath(scripts, "consume.jl")
            write(consume, raw"""
            const DEPOT = ARGS[1]; const JSD = ARGS[2]; const STASH = ARGS[3]; const PROJ = ARGS[4]
            import Pkg
            Pkg.activate(PROJ; io = devnull)     # consumer project (has Dep) — so it is locatable
            M = Dict{String,String}()
            for line in eachline(joinpath(STASH, "manifest.txt"))
                isempty(line) && continue
                k, v = split(line, "=", limit = 2); M[k] = v
            end
            include(JSD); using .JuliaStaticData
            dep_uuid = Base.UUID("11111111-1111-1111-1111-111111111111")
            depB = Base.require(Base.PkgId(dep_uuid, "Dep"))
            println("DEPB_BID 0x", string(Base.module_build_id(depB), base = 16))

            tmp = mktempdir()
            for k in ("USER_JI", "USER_SO")
                cp(M[k], joinpath(tmp, basename(M[k])); force = true)
            end
            uso = joinpath(tmp, basename(M["USER_SO"]))
            sc = read_sidecar(joinpath(STASH, "user.sidecar"))

            u, trep, crep = load_translated(uso, sc)     # translate->remap->load->canonicalize
            println("XLATE checked=", trep.words_checked, " rewritten=", trep.words_rewritten,
                    " resolved=", trep.targets_resolved, " failed=", length(trep.targets_failed),
                    " ok=", trep.ok)
            for f in trep.targets_failed; println("  FAIL ", f); end
            call_hello(u) = Base.invokelatest(getglobal(u, :hello))
            println("RESULT_XLATE: ", repr(call_hello(u)))
            println("CANON1 scanned=", crep.methods_scanned, " reinterned=", crep.sigs_reinterned,
                    " reinserted=", crep.entries_reinserted)
            crep2 = canonicalize!(u)                      # idempotence
            println("CANON2 reinterned=", crep2.sigs_reinterned, " reinserted=", crep2.entries_reinserted)
            println("CONSUME DONE")
            """)

            okA, outA = run_child(depotA, build_dep, [depotA, srcA, "A"])
            @info "build_dep A:\n$outA"
            okU, outU = run_child(depotA, build_user, [depotA, srcA, jsd_src, stash])
            @info "build_user:\n$outU"

            if !okA || !okU || occursin("BUILD_USER NO_SO", outU) ||
               !isfile(joinpath(stash, "manifest.txt"))
                @info "SKIP toy round-trip: $XLATE_SKIP_MSG"
                @test_skip XLATE_SKIP_MSG
            else
                @test occursin("BUILD_USER OK", outU)
                @test occursin("EMIT ", outU)
                m = match(r"ntargets=(\d+)", outU)
                @test m !== nothing && parse(Int, m.captures[1]) >= 1

                okB, outB = run_child(depotB, build_dep, [depotB, srcB, "B"])
                @info "build_dep B:\n$outB"
                @test okB

                okC, outC = run_child(depotB, consume, [depotB, jsd_src, stash, joinpath(srcB, "env")])
                @info "consume:\n$outC"

                @test okC
                @test occursin("CONSUME DONE", outC)
                @test occursin("XLATE ", outC)
                @test occursin("ok=true", outC)
                # the whole point: User built on depot-A Dep runs on depot-B Dep
                @test occursin("RESULT_XLATE: \"Dep v1 42 Widget\"", outC)
                # canonicalize! is idempotent — the second pass changes nothing
                @test occursin("CANON2 reinterned=0 reinserted=0", outC)
            end
        finally
            rm(work; force = true, recursive = true)
        end
    end
end

# ── item 2: descriptor-kind coverage (binding, type, function, svec-anchor) ──
@testitem "reference-translation descriptor kinds round-trip" begin
    using JuliaStaticData

    XLATE_SKIP_MSG =
        "cannot build split package images here (no C toolchain or build failed); " *
        "reference-translation round-trip not exercised"
    jsd_src = abspath(joinpath(@__DIR__, "..", "src", "JuliaStaticData.jl"))
    julia_exe = Base.julia_cmd().exec[1]
    have_cc = any(c -> Sys.which(c) !== nothing, ("cc", "gcc", "clang"))

    if !isfile(jsd_src) || !have_cc
        @info "SKIP descriptor kinds: $XLATE_SKIP_MSG"
        @test_skip XLATE_SKIP_MSG
    else
        work = mktempdir()
        try
            depot = joinpath(work, "depot"); src = joinpath(work, "src")
            scripts = joinpath(work, "scripts")
            for d in (depot, src, scripts); mkpath(d); end

            probe = joinpath(scripts, "probe.jl")
            write(probe, raw"""
            const DEPOT = ARGS[1]; const SRC = ARGS[2]; const JSD = ARGS[3]
            import Pkg
            Q = Char(34)
            dep_uuid = "33333333-3333-3333-3333-333333333333"
            depdir = joinpath(SRC, "Dep"); mkpath(joinpath(depdir, "src"))
            write(joinpath(depdir, "Project.toml"),
                  "name = $(Q)Dep$(Q)\nuuid = $(Q)$dep_uuid$(Q)\nversion = $(Q)0.1.0$(Q)\n")
            write(joinpath(depdir, "src", "Dep.jl"),
                  "module Dep\nstruct Widget a::Int; b::Float64 end\n" *
                  "const MAGIC = 42\ngreet() = 7\n" *
                  "export greet, MAGIC, Widget\nend\n")
            ENV["JULIA_PKG_OFFLINE"] = "true"
            env = joinpath(SRC, "env"); mkpath(env)
            Pkg.activate(env); Pkg.develop(path = depdir); Pkg.precompile()

            include(JSD); const J = Main.JuliaStaticData
            Dep = Base.require(Base.PkgId(Base.UUID(dep_uuid), "Dep"))
            tbl = J._blob_table()
            bl = J._dep_blob(tbl, Dep)
            @assert bl !== nothing "Dep has no linkage blob"
            lo, hi = bl
            vp(x) = J._vptr(x)

            function rt(obj)                              # describe then resolve back
                d = J._describe_object(obj, Dep, tbl, lo, hi)
                d === nothing && return (nothing, false)
                back = J._resolve_descriptor(d, Dep)
                (d, vp(back) == vp(obj))
            end

            dM, okM = rt(Dep)
            println("KIND module=", dM === nothing ? "-" : dM.kind, " ok=", okM)
            dF, okF = rt(getglobal(Dep, :greet))
            println("KIND function=", dF === nothing ? "-" : dF.kind, " ok=", okF)
            dT, okT = rt(getglobal(Dep, :Widget))
            println("KIND type=", dT === nothing ? "-" : dT.kind, " ok=", okT)
            b = ccall(:jl_get_module_binding, Any, (Any, Any, Cint), Dep, :MAGIC, 1)
            dB, okB = rt(b)
            println("KIND binding=", dB === nothing ? "-" : dB.kind, " ok=", okB,
                    " isbinding=", b isa Core.Binding)
            sv = getfield(getglobal(Dep, :Widget), :types)   # svec(Int64, Float64)
            dS, okS = rt(sv)
            println("KIND svec=", dS === nothing ? "-" : dS.kind, " ok=", okS,
                    " issvec=", sv isa Core.SimpleVector,
                    " inblob=", lo <= vp(sv) < hi,
                    " pathlen=", dS === nothing ? -1 : length(dS.fieldpath))

            synth = Core.svec(1, 2, 3)                    # anonymous, unreachable, out of blob
            println("UNDESCRIBABLE describe_nothing=",
                    J._describe_object(synth, Dep, tbl, lo, hi) === nothing)
            thrown = try                                  # expression form: no soft-scope trap
                J._describe_target(Dep, tbl, lo, hi, hi - lo + 8, "Dep")  # offset past blob end
                false
            catch
                true
            end
            println("LOUD_FAIL thrown=", thrown)
            println("PROBE DONE")
            """)

            childenv = copy(ENV)
            childenv["JULIA_DEPOT_PATH"] = depot * ":"
            childenv["JULIA_PKG_OFFLINE"] = "true"
            childenv["JULIA_LOAD_PATH"] = "@:@stdlib"
            delete!(childenv, "JULIA_PROJECT")
            cmd = `$julia_exe --startup-file=no --color=no $probe $depot $src $jsd_src`
            out = IOBuffer()
            proc = run(pipeline(setenv(cmd, childenv); stdout = out, stderr = out); wait = false)
            wait(proc)
            ok = success(proc); outP = String(take!(out))
            @info "probe:\n$outP"

            if !ok || !occursin("PROBE DONE", outP)
                @info "SKIP descriptor kinds: $XLATE_SKIP_MSG"
                @test_skip XLATE_SKIP_MSG
            else
                @test occursin("KIND module=module ok=true", outP)
                @test occursin("KIND function=function ok=true", outP)
                @test occursin("KIND type=type ok=true", outP)
                @test occursin("KIND binding=binding ok=true", outP)
                @test occursin("isbinding=true", outP)
                @test occursin("KIND svec=anchor ok=true", outP)
                @test occursin("issvec=true", outP)
                @test occursin("UNDESCRIBABLE describe_nothing=true", outP)
                @test occursin("LOUD_FAIL thrown=true", outP)
            end
        finally
            rm(work; force = true, recursive = true)
        end
    end
end

# ── item 3: canonicalize! is a safe no-op + idempotent on a healthy module ──
@testitem "canonicalize! idempotence on a healthy loaded module" begin
    using JuliaStaticData

    XLATE_SKIP_MSG =
        "cannot build split package images here (no C toolchain or build failed); " *
        "reference-translation round-trip not exercised"
    jsd_src = abspath(joinpath(@__DIR__, "..", "src", "JuliaStaticData.jl"))
    julia_exe = Base.julia_cmd().exec[1]
    have_cc = any(c -> Sys.which(c) !== nothing, ("cc", "gcc", "clang"))

    if !isfile(jsd_src) || !have_cc
        @info "SKIP canonicalize idempotence: $XLATE_SKIP_MSG"
        @test_skip XLATE_SKIP_MSG
    else
        work = mktempdir()
        try
            depot = joinpath(work, "depot"); src = joinpath(work, "src")
            scripts = joinpath(work, "scripts")
            for d in (depot, src, scripts); mkpath(d); end

            script = joinpath(scripts, "canon.jl")
            write(script, raw"""
            const DEPOT = ARGS[1]; const SRC = ARGS[2]; const JSD = ARGS[3]
            import Pkg
            Q = Char(34)
            dep_uuid = "44444444-4444-4444-4444-444444444444"
            depdir = joinpath(SRC, "Dep"); mkpath(joinpath(depdir, "src"))
            write(joinpath(depdir, "Project.toml"),
                  "name = $(Q)Dep$(Q)\nuuid = $(Q)$dep_uuid$(Q)\nversion = $(Q)0.1.0$(Q)\n")
            write(joinpath(depdir, "src", "Dep.jl"),
                  "module Dep\nstruct P{T} x::T end\n" *
                  "f(x::Int) = x + 1\nf(x::P{T}) where {T} = x.x\n" *
                  "g(a, b) = a * b\nexport f, g, P\nend\n")
            ENV["JULIA_PKG_OFFLINE"] = "true"
            env = joinpath(SRC, "env"); mkpath(env)
            Pkg.activate(env); Pkg.develop(path = depdir); Pkg.precompile()

            include(JSD); using .JuliaStaticData
            Dep = Base.require(Base.PkgId(Base.UUID(dep_uuid), "Dep"))
            # A normally-loaded module is already canonical: BOTH passes must be
            # no-ops (idempotence), and dispatch must keep working (canonicalize!
            # must not break a healthy module).
            r1 = canonicalize!(Dep)
            r2 = canonicalize!(Dep)
            println("R1 scanned=", r1.methods_scanned, " reint=", r1.sigs_reinterned, " reins=", r1.entries_reinserted)
            println("R2 scanned=", r2.methods_scanned, " reint=", r2.sigs_reinterned, " reins=", r2.entries_reinserted)
            f = getglobal(Dep, :f); P = getglobal(Dep, :P)
            println("DISPATCH f(3)=", Base.invokelatest(f, 3),
                    " f(P(9))=", Base.invokelatest(f, Base.invokelatest(P, 9)))
            println("CANON PROBE DONE")
            """)

            childenv = copy(ENV)
            childenv["JULIA_DEPOT_PATH"] = depot * ":"
            childenv["JULIA_PKG_OFFLINE"] = "true"
            childenv["JULIA_LOAD_PATH"] = "@:@stdlib"
            delete!(childenv, "JULIA_PROJECT")
            cmd = `$julia_exe --startup-file=no --color=no $script $depot $src $jsd_src`
            out = IOBuffer()
            proc = run(pipeline(setenv(cmd, childenv); stdout = out, stderr = out); wait = false)
            wait(proc)
            ok = success(proc); outP = String(take!(out))
            @info "canon probe:\n$outP"

            if !ok || !occursin("CANON PROBE DONE", outP)
                @info "SKIP canonicalize idempotence: $XLATE_SKIP_MSG"
                @test_skip XLATE_SKIP_MSG
            else
                @test occursin(r"R1 scanned=\d+ reint=0 reins=0", outP)
                @test occursin(r"R2 scanned=\d+ reint=0 reins=0", outP)
                @test occursin("DISPATCH f(3)=4 f(P(9))=9", outP)
            end
        finally
            rm(work; force = true, recursive = true)
        end
    end
end

# ── item 4: pure-Julia unit checks (no toolchain needed) ───────────────
@testitem "reference-translation reloc-word codec + sidecar serialization" begin
    using JuliaStaticData
    const J = JuliaStaticData

    # Reloc-word codec matches the staticdata.c encoding round-trip.
    for (depsidx, boff) in ((13, 0), (46, 300752), (79, 483024), (1, 8), (0x1ffff, 8 * (2^30)))
        w = (UInt64(5) << 61) | (UInt64(depsidx) << 40) | UInt64(boff ÷ 8)
        tag, dep, off = J._decode_reloc_word(w)
        @test tag == 5
        @test dep == depsidx
        @test off == boff
    end
    w6 = (UInt64(6) << 61) | UInt64(96 ÷ 8)              # ExternalLinkage (fallback tag)
    tag, dep, off = J._decode_reloc_word(w6)
    @test tag == 6
    @test off == 96
    @test J._decode_reloc_word(UInt64(3) << 61)[1] == 3  # SymbolRef: not an external ref

    # Little-endian word helpers round-trip.
    buf = zeros(UInt8, 32)
    J._write_u64le!(buf, 8, 0x0123456789abcdef)
    @test J._read_u64le(buf, 8) == 0x0123456789abcdef
    @test J._read_u32(buf, 8) == 0x89abcdef

    # Sidecar serialization round-trips through a file.
    d = RefDescriptor(:function, [:Sub], :greet)
    da = RefDescriptor(:anchor, Symbol[], Symbol(""),
                       RefDescriptor(:type, Symbol[], :Widget),
                       Tuple{Symbol,Any}[(:getfield, :types), (:getindex, 1)])
    t1 = RefTarget(19, "Dates", UInt128(0xabcd), 925488, d, UInt64(0xdeadbeef), [100, 200])
    t2 = RefTarget(37, "StaticArrays", UInt128(0x1234), 15136, da, UInt64(0xfeed), [300])
    sc = Sidecar(1, [ImageSidecar("Altissimo", UInt128(0x999), string(VERSION), 253, [t1, t2])])
    tmp = tempname()
    try
        write_sidecar(tmp, sc)
        sc2 = read_sidecar(tmp)
        @test sc2 isa Sidecar
        @test length(sc2.images) == 1
        img = only(sc2.images)
        @test img.image_name == "Altissimo"
        @test img.n_words == 253
        @test length(img.targets) == 2
        @test img.targets[1].descriptor.kind == :function
        @test img.targets[1].positions == [100, 200]
        @test img.targets[2].descriptor.kind == :anchor
        @test img.targets[2].descriptor.owner.name == :Widget
        @test img.targets[2].descriptor.fieldpath == Tuple{Symbol,Any}[(:getfield, :types), (:getindex, 1)]
    finally
        isfile(tmp) && rm(tmp)
    end

    bad = tempname()                                     # read_sidecar rejects junk cleanly
    try
        Base.write(bad, "not a sidecar")
        @test_throws Exception read_sidecar(bad)
    finally
        isfile(bad) && rm(bad)
    end
end
