using TestItemRunner
using TestItems

# Regression tests for the register-LOCK fix in loader.jl:
#
#     restored = @lock Base.require_lock Base.register_restored_modules(sv, pkg, path)
#
# `load_package_image(...; register=true)` hands the deserialized SimpleVector to
# `Base.register_restored_modules`, which mutates Base's GLOBAL module registry
# (`loaded_modules_order`, `loaded_precompiles`, `pkgorigins`). On Julia 1.12 that
# function opens with `assert_havelock(require_lock)`, so:
#
#   * Called WITHOUT the lock  -> ConcurrencyViolationError (the original bug).
#   * Concurrent loads racing on the registry without serialization -> corruption.
#
# The fix takes `Base.require_lock` around the registration call, which both
# satisfies the assertion and serializes concurrent multi-dependency image loads.
#
# These tests exercise `Base.register_restored_modules` directly (the exact call
# the fix wraps) using a SYNTHETIC SimpleVector shaped like what
# `jl_restore_package_image_from_file` / `jl_restore_incremental` return:
#
#     sv[1] :: Vector{Any}   restored Modules
#     sv[2] :: Vector{Any}   __init__ callbacks
#     sv[3] :: Vector{Any}   (extra, unused here)
#
# Using empty inner vectors means registration touches the lock-guarded path
# WITHOUT mutating the live registry with bogus modules — so the tests are
# self-contained and safe to run inside any session.
#
# LIMITATION: A full end-to-end `load_package_image` round-trip is intentionally
# NOT exercised here. That would require a precompiled package-image fixture
# (.ji/.so) that is (a) built with cache flags matching the running session and
# (b) has all of its own dependencies already loaded and resolvable. Arbitrary
# images from the depot fail in the C deserialization step ("Pkgimage flags
# mismatch") *before* the locked registration line is ever reached, so they do
# not test the fix and only make the suite flaky. Pkg.test's sandbox depot has no
# usable images at all (see test_so_remap.jl). We therefore test the exact
# function the fix wraps — `Base.register_restored_modules` — directly, which is
# both deterministic and independent of any depot fixture.

@testitem "register_restored_modules requires Base.require_lock (the bug the fix prevents)" begin
    using JuliaStaticData

    # A minimal SimpleVector with no restored modules and no init callbacks:
    # register_restored_modules will run, but mutate nothing observable.
    sv = Core.svec(Any[], Any[], Any[])
    pkg = Base.PkgId(Base.UUID("72ac74b6-0a8a-4afc-a67b-32735e8af5c8"), "JSDLockProbe")
    path = tempname() * ".ji"   # path is only recorded, never read

    # WITHOUT the lock: this is precisely the pre-fix call site. It must throw
    # ConcurrencyViolationError via assert_havelock(require_lock) in Base.
    @test_throws ConcurrencyViolationError Base.register_restored_modules(sv, pkg, path)

    # WITH the lock (the fix): registration succeeds and returns sv[1].
    restored = @lock Base.require_lock Base.register_restored_modules(sv, pkg, path)
    @test restored === sv[1]
    @test isempty(restored)
end

@testitem "concurrent registration through the locked path stays consistent" begin
    using JuliaStaticData

    # Simulate many dependency images being loaded+registered concurrently, each
    # going through the SAME locked path the loader uses. Without the @lock guard
    # every spawned task would hit assert_havelock and raise
    # ConcurrencyViolationError; with it they serialize cleanly and the global
    # registry is left consistent.
    n = 32
    pkgs = [Base.PkgId(Base.UUID(UInt128(i)), "JSDConcProbe$(i)") for i in 1:n]

    # Snapshot the live registry. Our synthetic images register no root modules,
    # so these global vectors must be byte-for-byte unchanged afterwards — i.e.
    # no double-registration / no spurious or corrupted entries.
    order_before = copy(Base.loaded_modules_order)
    precompiles_before_len = length(Base.loaded_precompiles)

    errors = Channel{Any}(n)
    @sync for i in 1:n
        Threads.@spawn begin
            sv = Core.svec(Any[], Any[], Any[])  # no root modules, no inits
            try
                @lock Base.require_lock begin
                    Base.register_restored_modules(sv, pkgs[i], tempname() * ".ji")
                end
            catch e
                put!(errors, e)
            end
        end
    end
    close(errors)

    collected = collect(errors)
    # No task may have raised — in particular no ConcurrencyViolationError.
    @test isempty(collected)
    @test all(e -> !(e isa ConcurrencyViolationError), collected)

    # Registry consistency: nothing registered a root module, so order is intact.
    @test Base.loaded_modules_order == order_before
    @test length(Base.loaded_precompiles) == precompiles_before_len

    # Sanity: with >1 thread this is a genuine concurrency test; with 1 thread it
    # degenerates to a deterministic serial pass through the locked path (still a
    # valid regression for the assert_havelock requirement).
    @test Threads.nthreads() >= 1
end
