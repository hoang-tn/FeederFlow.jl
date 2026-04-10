using Ipopt
using PowerModelsDistribution
using Printf

function prepare_data(path)
    data = PowerModelsDistribution.parse_file(
        path;
        data_model = PowerModelsDistribution.MATHEMATICAL,
        make_pu = true,
        kron_reduce = true,
        phase_project = true,
    )

    # Voltage limits
    for bus in values(data["bus"])
        if bus["bus_type"] != 3
            bus["vmin"] = [terminal == 4 ? 0.0 : 0.95 for terminal in bus["terminals"]]
            bus["vmax"] = [terminal == 4 ? Inf : 1.05 for terminal in bus["terminals"]]
        end
    end

    # Branch constraints
    ang = deg2rad(25.0)
    for br in values(data["branch"])
        n = length(br["f_connections"])
        br["c_rating_a"] = fill(1.0, n)
        br["angmin"] = fill(-ang, n)
        br["angmax"] = fill(ang, n)
    end

    # Generator costs and substation bounds
    for gen in values(data["gen"])
        name = String(get(gen, "name", ""))
        gen["model"] = 2
        gen["ncost"] = 2
        if startswith(name, "pv_")
            gen["cost"] = [1.0, 0.0]
            gen["pmin"] = fill(0.0, length(gen["pg"]))
            gen["qmin"] = fill(-0.002, length(gen["qg"]))
            gen["qmax"] = fill(0.002, length(gen["qg"]))
        elseif occursin("voltage_source", name)
            gen["cost"] = [50.0, 0.0]
            gen["pmin"] = fill(0.0, length(gen["pg"]))
            gen["pmax"] = fill(0.08, length(gen["pg"]))
            gen["qmin"] = fill(-0.08, length(gen["qg"]))
            gen["qmax"] = fill(0.08, length(gen["qg"]))
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

if haskey(result, "solution")
    sol = result["solution"]
    if haskey(sol, "branch") && !isempty(sol["branch"])
        fb = first(values(sol["branch"]))
        println("first branch sol keys=", sort!(collect(keys(fb))))
    end
    if haskey(sol, "bus") && !isempty(sol["bus"])
        b = first(values(sol["bus"]))
        println("first bus sol keys=", sort!(collect(keys(b))))
    end
end
