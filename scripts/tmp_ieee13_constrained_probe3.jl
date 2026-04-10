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

    # Branch current and angle-difference constraints
    ang = deg2rad(40.0)
    for br in values(data["branch"])
        n = length(br["f_connections"])
        br["c_rating_a"] = fill(10.0, n)
        br["angmin"] = fill(-ang, n)
        br["angmax"] = fill(ang, n)
    end

    for gen in values(data["gen"])
        name = String(get(gen, "name", ""))

        if haskey(gen, "connections") && haskey(gen, "pg")
            n_pg = length(gen["pg"])
            if length(gen["connections"]) > n_pg
                gen["connections"] = gen["connections"][1:n_pg]
            end
        end
        if haskey(gen, "qg") && haskey(gen, "connections")
            n_qg = length(gen["qg"])
            if length(gen["connections"]) > n_qg
                gen["connections"] = gen["connections"][1:n_qg]
            end
        end

        if startswith(name, "pv_")
            gen["cost"] = [10.0, 0.0]
            gen["pmin"] = fill(0.0, length(gen["pg"]))
        else
            gen["cost"] = [100.0, 0.0]
            # Substation power constraints
            gen["pmin"] = fill(0.0, length(gen["pg"]))
            gen["pmax"] = fill(0.20, length(gen["pg"]))
            gen["qmin"] = fill(-0.20, length(gen["qg"]))
            gen["qmax"] = fill(0.20, length(gen["qg"]))
        end
        gen["model"] = 2
        gen["ncost"] = 2
    end

    return data
end

dss_path = joinpath("FeederFlow.jl", "examples", "grids", "13_bus", "IEEE13Nodeckt.dss")

data = prepare_data(dss_path)
result = PowerModelsDistribution.solve_mc_opf(data, PowerModelsDistribution.ACRUPowerModel, Ipopt.Optimizer)

println("termination_status=", get(result, "termination_status", "UNKNOWN"))
println("primal_status=", get(result, "primal_status", "UNKNOWN"))
println("objective=", get(result, "objective", missing))
