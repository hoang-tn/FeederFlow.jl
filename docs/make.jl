using Documenter
using FeederFlow

makedocs(
    sitename = "FeederFlow.jl",
    modules = [FeederFlow],
    format = Documenter.HTML(),
    remotes = nothing,
    pages = [
        "Home" => "index.md",
    ],
)
