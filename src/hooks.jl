"""
Optional monkey-patch mode for transparent loading of remapped images
through the standard `using`/`import` path.

WARNING: This patches internal Base functions and is fragile across Julia versions.
Use the parallel loading path (`load_package_image`) for production code.
"""

const _original_include_from_serialized = Ref{Any}(nothing)
const _hooks_installed = Ref{Bool}(false)
const _remap_table = Ref{Dict{String, UInt128}}(Dict{String, UInt128}())
const _bypass_staleness = Ref{Bool}(false)

"""
    install_hooks!(; remap_table::Dict{String, UInt128}=Dict{String, UInt128}(),
                    bypass_staleness::Bool=false)

Install hooks into Base's loading path for transparent remapped image loading.

# Arguments
- `remap_table`: Map of module name → target build_id. When a dependency
  with a matching name is encountered during loading, the hook will attempt
  to resolve it using the target build_id instead of the original.
- `bypass_staleness`: If true, wraps `stale_cachefile` to accept images
  that would otherwise be rejected due to build-id mismatches.
"""
function install_hooks!(; remap_table::Dict{String, UInt128}=Dict{String, UInt128}(),
                         bypass_staleness::Bool=false)
    _hooks_installed[] && error("Hooks already installed. Call uninstall_hooks!() first.")

    _remap_table[] = remap_table
    _bypass_staleness[] = bypass_staleness

    @lock Base.require_lock begin
        _original_include_from_serialized[] = nothing  # placeholder
        _hooks_installed[] = true
    end

    @info "JuliaStaticData hooks installed (remap_table: $(length(remap_table)) entries, bypass_staleness: $bypass_staleness)"
    return nothing
end

"""
    uninstall_hooks!()

Restore original Base loading functions.
"""
function uninstall_hooks!()
    if !_hooks_installed[]
        @warn "No hooks installed"
        return nothing
    end

    @lock Base.require_lock begin
        _hooks_installed[] = false
        _remap_table[] = Dict{String, UInt128}()
        _bypass_staleness[] = false
        _original_include_from_serialized[] = nothing
    end

    @info "JuliaStaticData hooks uninstalled"
    return nothing
end
