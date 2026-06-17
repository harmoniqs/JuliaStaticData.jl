# Shared fixture-resolution helpers for the depot/pkgimage-dependent tests.
#
# Several tests need a *real* package-image fixture: a depot directory containing
#   compiled/v<major>.<minor>/**/<name>.{ji,so}
# Locally (dev) we can just scan Base.DEPOT_PATH and find them. On a clean CI
# runner there are no pkgimages, so we let CI provision an extracted bundle
# (exactly the Piccolissimo BuildImage `target/pkgimage/` depot) and point us at
# it via ENV["JSD_FIXTURE_DEPOT"].
#
# Resolution precedence (see jsd_fixture_depots):
#   1. ENV["JSD_FIXTURE_DEPOT"] (set & non-empty)  -> search ONLY that depot
#   2. otherwise                                   -> scan Base.DEPOT_PATH
#
# These helpers are `include`d into each @testitem (TestItemRunner runs every
# testitem in its own module, so the file is included per-item). They return
# `nothing` / an empty vector when no fixture is available; callers then SKIP
# rather than error. The exact skip message used across tests:
const JSD_FIXTURE_SKIP_MSG =
    "no .ji/.so fixture found; set JSD_FIXTURE_DEPOT to an extracted bundle depot, " *
    "or run in a depot with pkgimages"

# Ordered list of depot roots to search, honoring JSD_FIXTURE_DEPOT first.
function jsd_fixture_depots()
    fixture = get(ENV, "JSD_FIXTURE_DEPOT", "")
    if !isempty(fixture)
        return [fixture]
    end
    return collect(Base.DEPOT_PATH)
end

# The compiled/v<major>.<minor> subdir of a depot (may or may not exist).
function jsd_compiled_dir(depot::AbstractString)
    return joinpath(depot, "compiled", "v$(VERSION.major).$(VERSION.minor)")
end

# Find a pkgimage `.so` (across the resolved depots) whose embedded header is a
# pkgimage and has at least one required module. Returns the path or `nothing`.
function jsd_find_so(parse_header)
    for depot in jsd_fixture_depots()
        compiled = jsd_compiled_dir(depot)
        isdir(compiled) || continue
        for (root, _, files) in walkdir(compiled)
            for f in files
                endswith(f, ".so") || continue
                cand = joinpath(root, f)
                h = try
                    parse_header(cand)
                catch
                    continue
                end
                h.pkgimage && !isempty(h.required_modules) && return cand
            end
        end
    end
    return nothing
end

# Collect up to `limit` `.ji` files from the resolved depots. If `predicate` is
# given it is called with the parsed header and must return true to keep the
# file (parse failures are skipped). Returns a (possibly empty) Vector{String}.
function jsd_find_ji(; limit::Integer = 3, parse_header = nothing, predicate = nothing)
    ji_files = String[]
    for depot in jsd_fixture_depots()
        compiled = jsd_compiled_dir(depot)
        isdir(compiled) || continue
        for (root, _, files) in walkdir(compiled)
            for f in files
                endswith(f, ".ji") || continue
                cand = joinpath(root, f)
                if predicate === nothing
                    push!(ji_files, cand)
                else
                    hdr = try
                        parse_header(cand)
                    catch
                        continue
                    end
                    predicate(hdr) && push!(ji_files, cand)
                end
                length(ji_files) >= limit && return ji_files
            end
            length(ji_files) >= limit && return ji_files
        end
    end
    return ji_files
end
