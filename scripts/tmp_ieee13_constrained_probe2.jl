using Ipopt
using PowerModelsDistribution

function prepare_data(path)
    data = PowerModelsDistribution.parse_file(
        path;
        data_model = PowerModelsDistribution.MATHEMATICAL,
        make_pu = true,
        kron_reduce = true,
        phase_project = true,
    )

    for bus in values(data["bus"])
        if bus["bus_type"] != 3
            bus["vmin"] = [terminal == 4 ? 0.0 : 0.90 for terminal in bus["terminals"]]
            bus["vmax"] = [terminal == 4 ? Inf : 1.10 for terminal in bus["terminals"]]
        end
    end

    # Add explicit branch current and angle-difference constraints (loose but active).
    ang = deg2rad(40.0)
    for br in values(data["branch"])
        n = length(br["f_connections"])
        br["c_rating_a"] = fill(5.0, n)
        br["angmin"] = fill(-ang, n)
        br["angmax"] = fill(ang, n)
    end

    for gen in values(data["gen"])
        name = String(get(gen, "name", ""))
        gen["model"] = 2
        gen["ncost"] = 2
        if startswith(name, "pv_")
            gen["cost"] = [1.0, 0.0]
            gen["pmin"] = fill(0.0, length(gen["pg"]))
            gen["qmin"] = fill(-0.05, length(gen["qg"]))
            gen["qmax"] = fill(0.05, length(gen["qg"]))
        elseif occursin("voltage_source", name)
            # Substation power constraints
            gen["cost"] = [50.0, 0.0]
            gen["pmin"] = fill(0.0, length(gen["pg"]))
            gen["pmax"] = fill(0.15, length(gen["pg"]))
            gen["qmin"] = fill(-0.15, length(gen["qg"]))
            gen["qmax"] = fill(0.15, length(gen["qg"]))
        end
    end

    return data
end

dss_path = joinpath("FeederFlow.jl", "examples", "grids", "13_bus", "IEEE13Nodeckt.dss")
data = prepare_data(dss_path)
result = PowerModelsDistribution.solve_mc_opf(data, PowerModelsDistribution.ACRUPowerModel, Ipopt.Optimizer)

println("termination_status=", get(result, "termination_status", "UNKNOWN"))
println("primal_status=", get(result, "primal_status", "UNKNOWN"))
println("objective=", get(result, "objective", missing))
