using FeederFlow
using OpenDSSDirect
using LinearAlgebra
using Printf

REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
IEEE13_DSS = joinpath(REPO_ROOT, "FeederFlow.jl", "examples", "grids", "13_bus", "IEEE13Nodeckt.dss")
IEEE37_DSS = joinpath(REPO_ROOT, "three-phase-modeling", "IEEE 37-bus feeder", "IEEE37openDSSdata", "ieee37opendss.dss")
IEEE123_DSS = joinpath(REPO_ROOT, "three-phase-modeling", "IEEE 123-bus feeder", "IEEE123openDSSdata", "IEEE123Master.dss")

function compile_opendss_circuit!(path::AbstractString)
    quoted = replace(normpath(path), "\\" => "/")
    dss("clear")
    dss("compile \"$quoted\"")
    return nothing
end

function feederflow_line_yprim(line::FeederFlow.LineDevice, ybase::Float64)
    yseries, yshunt = FeederFlow.line_admittance(line; include_shunt = true, ybase = ybase)
    self = yseries + 0.5 .* yshunt
    mutual = -yseries
    return [self mutual; mutual self]
end

function reorder_line_yprim(yprim::AbstractMatrix{ComplexF64}, phases::Vector{Int}, node_order::Vector{Int})
    nph = length(phases)
    phase_to_local = Dict(phase => idx for (idx, phase) in enumerate(phases))
    perm = Int[]
    for phase in node_order[1:nph]
        push!(perm, phase_to_local[phase])
    end
    for phase in node_order[nph + 1:end]
        push!(perm, nph + phase_to_local[phase])
    end
    return Matrix{ComplexF64}(yprim[perm, perm])
end

function compare_network(path::AbstractString, label::AbstractString)
    println("=" ^ 88)
    println("LINE YPRIM PARITY: $label")
    println(path)
    println("=" ^ 88)

    network = FeederFlow.parse_file(path)
    compile_opendss_circuit!(path)

    worst_line = ""
    worst_diff = 0.0

    @printf("%-18s %5s %14s %14s %14s\n", "Line", "Ph", "max|ΔY|", "|FF Y11|", "|ODSS Y11|")
    println("-" ^ 88)

    for line in network.lines
        dss("select line.$(line.name)")
        odss_yprim = Matrix{ComplexF64}(OpenDSSDirect.CktElement.YPrim()) / network.base.Ybase
        node_order = Int.(OpenDSSDirect.CktElement.NodeOrder())

        ff_yprim = feederflow_line_yprim(line, network.base.Ybase)
        ff_yprim = reorder_line_yprim(ff_yprim, line.phases, node_order)

        diff = maximum(abs.(ff_yprim .- odss_yprim))
        if diff > worst_diff
            worst_line = line.name
            worst_diff = diff
        end

        @printf(
            "%-18s %5d %14.6e %14.6e %14.6e\n",
            line.name,
            length(line.phases),
            diff,
            abs(ff_yprim[1, 1]),
            abs(odss_yprim[1, 1]),
        )
    end

    println("-" ^ 88)
    @printf("Worst line: %s  max|ΔY| = %.6e\n\n", worst_line, worst_diff)
end

for (label, path) in [
    ("IEEE 13", IEEE13_DSS),
    ("IEEE 37", IEEE37_DSS),
    ("IEEE 123", IEEE123_DSS),
]
    isfile(path) || continue
    compare_network(path, label)
end
