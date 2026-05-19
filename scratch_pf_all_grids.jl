using Logging
global_logger(Logging.ConsoleLogger(stderr, Logging.Warn))

# If FeederFlow is not loaded directly, load via path
using Pkg
Pkg.activate(@__DIR__)
using FeederFlow

grids = [
    ("13_bus", joinpath("examples", "grids", "13_bus", "IEEE13Nodeckt.dss")),
    ("37_bus", joinpath("examples", "grids", "37_bus", "ieee37.dss")),
    ("123_bus", joinpath("examples", "grids", "123_bus", "IEEE123Master.dss")),
    ("240_bus", joinpath("examples", "grids", "240_bus", "Master.dss")),
    ("906_bus", joinpath("examples", "grids", "906_bus", "Master.dss")),
    ("IEEE8500 balanced", joinpath("examples", "grids", "IEEE8500", "Master.dss")),
    ("IEEE8500 unbalanced", joinpath("examples", "grids", "IEEE8500", "Master-unbal.dss"))
]

for (name, filepath) in grids
    full_path = joinpath(@__DIR__, filepath)
    if isfile(full_path)
        println("====================")
        println("Solving Power Flow for: ", name)
        try
            network = FeederFlow.parse_file(full_path)
            bundle = FeederFlow.solve_power_flow(network; max_iter=100, tol=1e-5)
            r = bundle.result
            mags = [abs(v) for v in values(r.phase_voltages)]
            println("  Converged: ", r.converged)
            println("  Iterations: ", r.iterations)
            println("  Residual: ", r.history[end])
            println("  |V| min: ", minimum(mags))
            println("  |V| max: ", maximum(mags))
        catch e
            println("  Error: ", e)
        end
    else
        println("File not found for $name: $full_path")
    end
end
