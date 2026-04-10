using Ipopt
using PowerModelsDistribution

dss_path = joinpath(@__DIR__, "..", "examples", "grids", "13_bus", "IEEE13Nodeckt.dss")

data = PowerModelsDistribution.parse_file(
    dss_path;
    data_model = PowerModelsDistribution.MATHEMATICAL,
    make_pu = true,
    kron_reduce = true,
    phase_project = true,
)

result = PowerModelsDistribution.solve_mc_opf(data, PowerModelsDistribution.ACRUPowerModel, Ipopt.Optimizer)
println("termination_status=", get(result, "termination_status", "UNKNOWN"))
println("primal_status=", get(result, "primal_status", "UNKNOWN"))
println("objective=", get(result, "objective", missing))
