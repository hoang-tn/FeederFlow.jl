using PowerModelsDistribution

dss_path = joinpath("FeederFlow.jl", "examples", "grids", "13_bus", "IEEE13Nodeckt.dss")
data = PowerModelsDistribution.parse_file(
    dss_path;
    data_model = PowerModelsDistribution.MATHEMATICAL,
    make_pu = true,
    kron_reduce = true,
    phase_project = true,
)

for (i, gen) in sort(collect(data["gen"]); by = x -> x[1])
    println("gen ", i, " name=", gen["name"])
    println("  bus=", gen["gen_bus"], " connections=", gen["connections"])
    println("  pmin=", gen["pmin"], " pmax=", gen["pmax"])
    println("  qmin=", gen["qmin"], " qmax=", gen["qmax"])
end
