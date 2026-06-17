using Documenter
using JuliaStaticData

makedocs(;
    modules=[JuliaStaticData],
    sitename="JuliaStaticData.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://juliastaticdata.github.io/JuliaStaticData.jl",
    ),
    pages=[
        "Home" => "index.md",
        "User Guide" => "guide.md",
        "CLI Reference" => "cli.md",
        "API Reference" => "api.md",
        "Package Image Format" => "format.md",
        "Julia Internals" => "internals.md",
        "Source Code Protection" => "protection.md",
    ],
)
