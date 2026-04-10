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

    # Enforce practical voltage limits at all non-slack buses.
    for bus in values(data["bus"])
        if bus["bus_type"] != 3
            bus["vmin"] = [terminal == 4 ? 0.0 : 0.90 for terminal in bus["terminals"]]
            bus["vmax"] = [terminal == 4 ? Inf : 1.10 for terminal in bus["terminals"]]
        end
    end

    # Encourage PV usage by assigning lower marginal cost than the source.
    for gen in values(data["gen"])
        name = String(get(gen, "name", ""))

        # PMD parser can include neutral terminal in generator connections while
        # pg/qg arrays remain phase-only. Keep only phase terminals to avoid
        # inconsistent indexing inside OPF formulations.
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
            gen["pmin"] = fill(0.0, length(gen["pg"]))
            gen["qmin"] = fill(-5.0, length(gen["qg"]))
            gen["qmax"] = fill(5.0, length(gen["qg"]))
        end
        gen["model"] = 2
        gen["ncost"] = 2
    end

    return data
end

function summarize_result(label, result)
    status = get(result, "termination_status", "UNKNOWN")
    primal = get(result, "primal_status", "UNKNOWN")
    objective = get(result, "objective", missing)

    println("[$label] termination_status = ", status)
    println("[$label] primal_status      = ", primal)
    println("[$label] objective          = ", objective)

    if haskey(result, "solution") && haskey(result["solution"], "gen")
        gens = result["solution"]["gen"]
        source_pg_total = 0.0
        pv_pg_total = 0.0

        for gen in values(gens)
            name = String(get(gen, "name", ""))
            pg = sum(Float64.(get(gen, "pg", [0.0])))
            if occursin("voltage_source", name)
                source_pg_total += pg
            elseif startswith(name, "pv_")
                pv_pg_total += pg
            end
        end

        println("[$label] total source pg    = ", source_pg_total)
        println("[$label] total pv pg        = ", pv_pg_total)
    end
end

dss_path = joinpath(@__DIR__, "..", "examples", "grids", "13_bus", "IEEE13Nodeckt.dss")
println("Input exists: ", isfile(dss_path))

formulations = [
    ("ACRU", PowerModelsDistribution.ACRUPowerModel),
]

for (label, formulation) in formulations
    try
        data = prepare_data(dss_path)
        result = PowerModelsDistribution.solve_mc_opf(data, formulation, Ipopt.Optimizer)
        summarize_result(label, result)
    catch err
        println("[$label] FAILED: ", typeof(err), " -> ", err)
    end
    println("-"^72)
end
