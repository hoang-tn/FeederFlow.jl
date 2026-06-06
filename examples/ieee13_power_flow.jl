#!/usr/bin/env julia
# Run from the package root:
#   julia --project=. examples/ieee13_power_flow.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using FeederFlow

dss = joinpath(@__DIR__, "grids", "13_bus", "IEEE13Nodeckt.dss")
bundle = solve_case(dss; regulator_model = :nonideal, max_iter = 20, tol = 1e-6)
result = get_normalized_result(bundle)

println("Converged: ", result.converged)
println("Iterations: ", result.iterations)
println("Bus-phase voltages (local pu): ", length(result.phase_voltages))
